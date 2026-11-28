#!/bin/bash
# Builds the karaoke model that ships inside the app: Deezer's Spleeter two-stem separator (vocals and accompaniment),
# published under the MIT licence (see third_party/spleeter/NOTICE.txt). Opt-in: run once, then Scripts/build-release.sh
# copies Resources/Models/SpleeterVocals2.mlmodelc into the app. Needs network, Xcode's command line tools and Python 3.9 to 3.12.
#
#   Scripts/fetch-karaoke-model.sh            build it if it is not there yet
#   Scripts/fetch-karaoke-model.sh --force    build it again
#
# Steps: download the original weights from the official release, check their size and SHA-256, convert the network to Core ML
# (half precision, fixed 512 x 1024 input), check the result against the original network, compile it.
# The converter tools live in a throw-away virtual environment outside the repository (STREAMSETU_KARAOKE_WORK, default ~/.cache/streamsetu-karaoke).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Resources/Models/SpleeterVocals2.mlmodelc
if [ -d "$OUT" ] && [ "${1:-}" != "--force" ]; then echo "✔ $OUT already present"; exit 0; fi

URL="https://github.com/deezer/spleeter/releases/download/v1.4.0/2stems.tar.gz"
SIZE=73109797
SHA256="f3a90b39dd2874269e8b05a48a86745df897b848c61f3958efc80a39152bd692"
WORK="${STREAMSETU_KARAOKE_WORK:-$HOME/.cache/streamsetu-karaoke}"
mkdir -p "$WORK/weights"

if [ ! -f "$WORK/2stems.tar.gz" ]; then
  echo "▸ Downloading $URL"
  curl -L --fail -o "$WORK/2stems.tar.gz.part" "$URL"
  mv "$WORK/2stems.tar.gz.part" "$WORK/2stems.tar.gz"
fi
[ "$(stat -f %z "$WORK/2stems.tar.gz")" = "$SIZE" ] || { rm -f "$WORK/2stems.tar.gz"; echo "✘ the download is not the expected size"; exit 1; }
[ "$(shasum -a 256 "$WORK/2stems.tar.gz" | cut -d' ' -f1)" = "$SHA256" ] || { rm -f "$WORK/2stems.tar.gz"; echo "✘ the download does not match its pinned SHA-256"; exit 1; }
rm -rf "$WORK/weights"; mkdir -p "$WORK/weights"
tar -xzf "$WORK/2stems.tar.gz" -C "$WORK/weights"

if [ ! -x "$WORK/venv/bin/python" ]; then
  echo "▸ Setting up the converter environment (about 1 GB, kept outside the repository)"
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet --upgrade pip
  "$WORK/venv/bin/pip" install --quiet tensorflow==2.20.0 torch==2.8.0 coremltools==9.0 numpy==2.0.2
fi

cat > "$WORK/spleeter_to_coreml.py" <<'PY'
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F
import tensorflow as tf

def _ckpt(prefix):
    r = tf.train.load_checkpoint(prefix)
    return lambda k: r.get_tensor(k)

class UNet(nn.Module):
    """One Spleeter U-Net (input magnitude [B,2,T,F], output mask in 0..1 of the same shape)."""
    def __init__(self, get, conv0, bn0, tr0, convlast):
        super().__init__()
        ch = [16, 32, 64, 128, 256, 512]
        T = lambda a: torch.from_numpy(np.ascontiguousarray(a))
        self.enc = nn.ModuleList(); self.encbn = nn.ModuleList()
        cin = 2
        for i, c in enumerate(ch):
            m = nn.Conv2d(cin, c, 5, stride=2)
            m.weight.data = T(get(f'conv2d{"" if conv0+i==0 else "_%d" % (conv0+i)}/kernel').transpose(3, 2, 0, 1))
            m.bias.data = T(get(f'conv2d{"" if conv0+i==0 else "_%d" % (conv0+i)}/bias'))
            self.enc.append(m); cin = c
        def bn(idx, n):
            b = nn.BatchNorm2d(n, eps=1e-3)
            name = 'batch_normalization' + ('' if idx == 0 else '_%d' % idx)
            b.weight.data = T(get(name + '/gamma')); b.bias.data = T(get(name + '/beta'))
            b.running_mean.data = T(get(name + '/moving_mean')); b.running_var.data = T(get(name + '/moving_variance'))
            return b
        for i in range(5): self.encbn.append(bn(bn0 + i, ch[i]))
        dec = [(512, 256), (512, 128), (256, 64), (128, 32), (64, 16), (32, 1)]
        self.dec = nn.ModuleList(); self.decbn = nn.ModuleList()
        for i, (a, b_) in enumerate(dec):
            nm = 'conv2d_transpose' + ('' if tr0 + i == 0 else '_%d' % (tr0 + i))
            m = nn.ConvTranspose2d(a if i else 512, b_, 5, stride=2)
            m.weight.data = T(get(nm + '/kernel').transpose(3, 2, 0, 1)); m.bias.data = T(get(nm + '/bias'))
            self.dec.append(m); self.decbn.append(bn(bn0 + 6 + i, b_))
        self.last = nn.Conv2d(1, 2, 4, dilation=2, padding=3)
        nm = 'conv2d_%d' % convlast
        self.last.weight.data = T(get(nm + '/kernel').transpose(3, 2, 0, 1)); self.last.bias.data = T(get(nm + '/bias'))

    @staticmethod
    def _same(x):  # TF SAME for k=5, s=2 on even sizes: 1 before, 2 after
        return F.pad(x, (1, 2, 1, 2))

    def forward(self, x):
        skips = []
        h = x
        for i in range(6):
            h = self.enc[i](self._same(h))
            skips.append(h)
            if i < 5: h = F.leaky_relu(self.encbn[i](h), 0.2)
        h = skips[5]
        for i in range(6):
            h = self.dec[i](h)
            n = h.shape[2] - 3
            h = h[:, :, 1:1 + n, 1:1 + h.shape[3] - 3]
            h = self.decbn[i](F.relu(h))
            if i < 5: h = torch.cat([skips[4 - i], h], dim=1)
        return torch.sigmoid(self.last(h))

class SpleeterMasks(nn.Module):
    """Both U-Nets. Output [B,4,T,F]: vocals mask (2 channels) then accompaniment mask (2 channels)."""
    def __init__(self, prefix):
        super().__init__()
        get = _ckpt(prefix)
        self.voc = UNet(get, 0, 0, 0, 6)
        self.acc = UNet(get, 7, 12, 6, 13)
    def forward(self, x):
        return torch.cat([self.voc(x), self.acc(x)], dim=1)


import sys
import coremltools as ct
weights, package = sys.argv[1], sys.argv[2]
model = SpleeterMasks(weights).eval()
traced = torch.jit.trace(model, torch.zeros(1, 2, 512, 1024))
ml = ct.convert(traced, inputs=[ct.TensorType(name="magnitude", shape=(1, 2, 512, 1024), dtype=np.float32)],
                outputs=[ct.TensorType(name="masks", dtype=np.float32)], convert_to="mlprogram",
                compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
ml.short_description = "Spleeter two-stem separator: vocal and accompaniment masks for a 512-frame magnitude spectrogram window"
ml.license = "MIT licence, Copyright (c) 2019-present, Deezer SA"
ml.save(package)
# The half-precision model must agree with the original network on a spectrogram-like input.
rng = np.random.RandomState(0)
x = (np.abs(rng.randn(1, 2, 512, 1024)) * np.linspace(40, 0.05, 1024)[None, None, None, :]).astype(np.float32)
with torch.no_grad():
    want = model(torch.from_numpy(x)).numpy()
got = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_ONLY).predict({"magnitude": x})["masks"]
err = float(np.abs(got - want).mean())
print("mean absolute mask difference, half precision against full: %.5f" % err)
if not err < 0.01:
    sys.exit("the converted model does not match the original network")
PY
echo "▸ Converting to Core ML"
rm -rf "$WORK/SpleeterVocals2.mlpackage" "$WORK/compiled"
"$WORK/venv/bin/python" "$WORK/spleeter_to_coreml.py" "$WORK/weights/model" "$WORK/SpleeterVocals2.mlpackage" > "$WORK/convert.log" 2>&1 \
  || { tail -20 "$WORK/convert.log"; echo "✘ the conversion failed"; exit 1; }
grep "mean absolute mask difference" "$WORK/convert.log" || true
xcrun coremlcompiler compile "$WORK/SpleeterVocals2.mlpackage" "$WORK/compiled" >/dev/null
mkdir -p Resources/Models
rm -rf "$OUT"; cp -R "$WORK/compiled/SpleeterVocals2.mlmodelc" "$OUT"
echo "✔ $OUT ($(du -sh "$OUT" | cut -f1)); Scripts/build-release.sh copies it into the app"
