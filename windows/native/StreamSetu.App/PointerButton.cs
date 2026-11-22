using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace StreamSetu.App;

/// <summary>A button that shows the pointing hand and gets a little smaller while it is held down. Everything else, including the focus rectangle, is the normal button.</summary>
public class PointerButton : Button
{
    private readonly ScaleTransform _scale = new() { ScaleX = 1, ScaleY = 1 };

    public PointerButton()
    {
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
        RenderTransform = _scale;
        RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
    }

    private void Press(bool down) => _scale.ScaleX = _scale.ScaleY = down ? 0.98 : 1;

    protected override void OnPointerPressed(PointerRoutedEventArgs e) { base.OnPointerPressed(e); Press(true); }
    protected override void OnPointerReleased(PointerRoutedEventArgs e) { base.OnPointerReleased(e); Press(false); }
    protected override void OnPointerExited(PointerRoutedEventArgs e) { base.OnPointerExited(e); Press(false); }
    protected override void OnPointerCanceled(PointerRoutedEventArgs e) { base.OnPointerCanceled(e); Press(false); }
    protected override void OnPointerCaptureLost(PointerRoutedEventArgs e) { base.OnPointerCaptureLost(e); Press(false); }
}
