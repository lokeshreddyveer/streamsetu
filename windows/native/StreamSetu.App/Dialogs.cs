using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace StreamSetu.App;

/// <summary>Small questions: a line of text, a PIN, a yes or no, a message. Shown over the page; the video window (a real window above the page) is hidden while one is open.</summary>
internal static class Dialogs
{
    private static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        // The player screen puts the window back on its next one-second tick.
        if (VideoWindow.Shown && AppServices.VideoHandle != IntPtr.Zero) VideoWindow.Hide(AppServices.VideoHandle);
        return await dialog.ShowAsync();
    }

    public static async Task<string?> AskAsync(XamlRoot root, string title, string label, bool secret = false, string initial = "", string ok = "OK")
    {
        FrameworkElement box = secret ? new PasswordBox { Header = label, Password = initial } : new TextBox { Header = label, Text = initial };
        var dialog = new ContentDialog { Title = title, Content = box, PrimaryButtonText = ok, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = root };
        if (await ShowAsync(dialog) != ContentDialogResult.Primary) return null;
        return box is PasswordBox p ? p.Password : ((TextBox)box).Text;
    }

    public static async Task<bool> ConfirmAsync(XamlRoot root, string title, string text, string yes = "Yes")
        => await ShowAsync(new ContentDialog { Title = title, Content = text, PrimaryButtonText = yes, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = root }) == ContentDialogResult.Primary;

    public static Task ShowCustomAsync(XamlRoot root, string title, object content, string close)
        => ShowAsync(new ContentDialog { Title = title, Content = content, CloseButtonText = close, XamlRoot = root });

    public static Task MessageAsync(XamlRoot root, string title, string text)
        => ShowAsync(new ContentDialog { Title = title, Content = text, CloseButtonText = "OK", XamlRoot = root });

    /// <summary>Asks for a PIN until it is right or the person cancels. Returns true when it was right.</summary>
    public static async Task<bool> PinAsync(XamlRoot root, string title, Func<string, StreamSetu.Core.PinResult> check)
    {
        string? note = null;
        while (true)
        {
            var pin = await AskAsync(root, title, note ?? "PIN", secret: true);
            if (pin is null) return false;
            switch (check(pin))
            {
                case StreamSetu.Core.PinResult.Ok: return true;
                case StreamSetu.Core.PinResult.Locked: await MessageAsync(root, "Too many wrong PINs", "Wait a minute and try again."); return false;
                case StreamSetu.Core.PinResult.NoPin: return true;
                default: note = "That PIN is not right. PIN"; break;
            }
        }
    }
}
