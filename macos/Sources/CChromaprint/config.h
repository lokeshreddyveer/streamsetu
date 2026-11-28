// Build configuration for the vendored Chromaprint 1.6.2 (https://github.com/acoustid/chromaprint, commit 3b38c100022bdfb49be7797c4828a476f1621d55).
// FFT: Apple's vDSP (Accelerate). Resampling: Chromaprint's own copy of FFmpeg's resampler (LGPL 2.1, see LICENSE.md).
#define HAVE_ROUND 1
#define HAVE_LRINTF 1
#define USE_INTERNAL_AVRESAMPLE 1
#define USE_VDSP 1
