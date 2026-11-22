using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace StreamSetu.App;

/// <summary>Channel logos and posters for the lists. The picture is fetched through the safe downloader and kept on disk (LogoCache); a title with no picture, or one that cannot be fetched, simply shows none.</summary>
public static class Logos
{
    /// <summary>Pictures kept in memory for the tiles on screen: never more than 48 MB, the least recently used go first. (The disk cache has its own limit.)</summary>
    private static readonly StreamSetu.Core.ByteLru Memory = new(48L * 1024 * 1024);

    /// <summary>Called from the list templates. Returns at once; the picture fills in when it arrives.</summary>
    public static ImageSource? Load(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return null;
        var image = new BitmapImage { DecodePixelWidth = 80 };
        _ = FillAsync(image, url);
        return image;
    }

    /// <summary>A poster at the size a tile shows it (the list rows use the small one above).</summary>
    public static ImageSource? LoadSized(string? url, int width)
    {
        if (string.IsNullOrWhiteSpace(url)) return null;
        var image = new BitmapImage { DecodePixelWidth = width };
        _ = FillAsync(image, url);
        return image;
    }

    private static async Task FillAsync(BitmapImage image, string url)
    {
        try
        {
            if (!Memory.TryGet(url, out var bytes))
            {
                bytes = await AppServices.Logos.GetWithRetryAsync(url)!;       // tried again a few times; back on the screen's thread after this await
                if (bytes is null) return;
                Memory.Put(url, bytes);
            }
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            await image.SetSourceAsync(stream);
        }
        catch (Exception) { /* a picture that will not decode is just not shown */ }
    }
}
