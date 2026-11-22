using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using StreamSetu.Core;
using Windows.UI;

namespace StreamSetu.App;

/// <summary>"Tune In", drawn from the television's layers over the whole window. It cannot be skipped: it takes no clicks or keys, and it ends on elapsed time, with a hard fallback. The picture for each moment comes from
/// <see cref="Opening.Frame"/>; this class only places the layers. Simplified against the Mac drawing: no snow, no sweep band and no ribbon draw-on mask. The set lights up, the antennas twitch, the ribbons and
/// the play button come in, the name arrives and a teal screen expands into the app.</summary>
internal sealed class OpeningOverlay : Grid
{
    private static readonly Color Background0 = Color.FromArgb(255, 0x04, 0x09, 0x0D), Glow = Color.FromArgb(255, 0x0A, 0x2A, 0x33), Teal = Color.FromArgb(255, 0x1F, 0xA7, 0xB8);
    private readonly Dictionary<string, Image> _layers = new();
    private readonly Image _glint;
    private readonly CompositeTransform _push = new();
    private readonly CompositeTransform _play = new(), _left = new(), _right = new();
    private readonly Microsoft.UI.Xaml.Shapes.Ellipse _dot, _halo;
    private readonly Grid _stage = new() { Width = 1024, Height = 1024 };
    private readonly TextBlock _name, _line;
    private readonly Microsoft.UI.Xaml.Shapes.Rectangle _screenGlow, _cut;
    private readonly Border _fill = new() { Background = new SolidColorBrush(Background0) };

    public OpeningOverlay()
    {
        IsHitTestVisible = true;                                              // it swallows every click: nothing behind it can be reached
        Children.Add(_fill);
        _screenGlow = new Microsoft.UI.Xaml.Shapes.Rectangle { Fill = new RadialGradientBrush { GradientStops = { new GradientStop { Color = Glow, Offset = 0 }, new GradientStop { Color = Color.FromArgb(0, 0x04, 0x09, 0x0D), Offset = 1 } } }, Opacity = 0 };
        Children.Add(_screenGlow);

        var column = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Spacing = 6 };
        foreach (var name in new[] { "ribbon-rear", "screen", "antenna-left", "antenna-right", "tv-body", "play-button", "ribbon-front", "glint-mask" })
        {
            var image = new Image { Width = 1024, Height = 1024, Opacity = 0, Source = Load(name) };
            _layers[name] = image; _stage.Children.Add(image);
        }
        _glint = _layers["glint-mask"];
        _layers["play-button"].RenderTransform = _play; _layers["antenna-left"].RenderTransform = _left; _layers["antenna-right"].RenderTransform = _right;
        _halo = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 260, Height = 260, Opacity = 0, Fill = new RadialGradientBrush { GradientStops = { new GradientStop { Color = Teal, Offset = 0 }, new GradientStop { Color = Color.FromArgb(0, 0x1F, 0xA7, 0xB8), Offset = 1 } } } };
        _dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 22, Height = 22, Opacity = 0, Fill = new SolidColorBrush(Color.FromArgb(255, 0x8F, 0xD8, 0xE3)) };
        foreach (var e in new FrameworkElement[] { _halo, _dot }) { e.HorizontalAlignment = HorizontalAlignment.Left; e.VerticalAlignment = VerticalAlignment.Top; }
        _halo.Margin = new Thickness(501.6 - 130, 501.3 - 130, 0, 0); _dot.Margin = new Thickness(501.6 - 11, 501.3 - 11, 0, 0);
        _stage.Children.Add(_halo); _stage.Children.Add(_dot);
        _stage.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5); _stage.RenderTransform = _push;

        var mark = new Viewbox { Stretch = Stretch.Uniform, Height = 520, Child = _stage };
        column.Children.Add(mark);
        _name = new TextBlock { Text = "StreamSetu", FontSize = 52, FontWeight = Microsoft.UI.Text.FontWeights.Bold, Foreground = new SolidColorBrush(Color.FromArgb(255, 0xF5, 0xF7, 0xFC)), HorizontalAlignment = HorizontalAlignment.Center, Opacity = 0 };
        _line = new TextBlock { Text = "Your streams. One home.", FontSize = 20, Foreground = new SolidColorBrush(Color.FromArgb(255, 0x9A, 0xA4, 0xAE)), HorizontalAlignment = HorizontalAlignment.Center, Opacity = 0 };
        column.Children.Add(_name); column.Children.Add(_line);
        Children.Add(column);

        _cut = new Microsoft.UI.Xaml.Shapes.Rectangle { Fill = new SolidColorBrush(Teal), Opacity = 0, RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5) };
        Children.Add(_cut);
    }

    private static BitmapImage? Load(string name)
    {
        try { return new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "TuneIn", name + ".png"))); }
        catch (Exception) { return null; }           // a missing picture leaves that layer out; the opening still ends on time
    }

    /// <summary>Plays the variant and returns when it has ended (never earlier than its duration, never later than the duration plus the fallback).</summary>
    public async Task PlayAsync(OpeningVariant variant)
    {
        var done = new TaskCompletionSource();
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var duration = Opening.DurationMs(variant);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        timer.Tick += (_, _) =>
        {
            var ms = clock.Elapsed.TotalMilliseconds;
            try { Apply(variant, ms); } catch (Exception) { /* a frame that cannot be drawn is skipped; time still ends it */ }
            if (ms >= duration || ms >= duration + Opening.FallbackMarginMs) { timer.Stop(); done.TrySetResult(); }
        };
        timer.Start();
        await Task.WhenAny(done.Task, Task.Delay(duration + Opening.FallbackMarginMs));
        timer.Stop();
    }

    private void Apply(OpeningVariant variant, double ms)
    {
        var f = Opening.Frame(variant, ms);
        var away = 1 - f.MatchCut;
        var body = Math.Min(1, 0.12 + 0.88 * f.SetLight + (f.Sweep >= 0 ? 0.3 * Math.Sin(Math.PI * f.Sweep) : 0));
        _screenGlow.Opacity = Math.Min(1, f.SetLight * 0.9 + f.Warm * 0.1) * away;
        _layers["tv-body"].Opacity = body * away; _layers["antenna-left"].Opacity = body * away; _layers["antenna-right"].Opacity = body * away;
        _layers["screen"].Opacity = f.Warm * away;
        _layers["ribbon-rear"].Opacity = f.RibbonRear * away; _layers["ribbon-front"].Opacity = f.RibbonFront * away;
        _layers["play-button"].Opacity = f.Play * away;
        _glint.Opacity = f.Glint * 0.8 * away;
        var scale = (0.4 + 0.6 * f.Play) * (1 - 0.03 * f.Press);
        _play.CenterX = 501.6; _play.CenterY = 501.3; _play.ScaleX = _play.ScaleY = scale;
        _left.CenterX = 454.5; _left.CenterY = 222; _left.Rotation = f.TwitchLeft;
        _right.CenterX = 529.4; _right.CenterY = 226; _right.Rotation = f.TwitchRight;
        _dot.Opacity = f.Dot * away; _halo.Opacity = f.Dot * 0.5 * away;
        var push = 1 + 0.04 * f.Push - 0.02 * f.EaseBack;
        _push.ScaleX = _push.ScaleY = push;
        _name.Opacity = f.Wordmark * away; _line.Opacity = f.Tagline * away;
        _cut.Opacity = f.MatchCut;
        // The still of Reduce Motion fades out at the end; the others end by the teal screen opening onto the app.
        var fade = variant == OpeningVariant.ReducedMotion ? 1 - Opening.Clamp((ms - 1000) / 400) : 1 - Opening.Clamp((f.MatchCut - 0.6) / 0.4);
        Opacity = fade;
    }
}
