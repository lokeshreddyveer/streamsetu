using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using StreamSetu.Core;
using Windows.UI;

namespace StreamSetu.App;

/// <summary>The pieces Home and the folder rows are made of, built in code: a poster tile, a shelf (a name and a row of tiles), a folder header. Nothing here repeats the folder's name under a tile.</summary>
internal static class Tiles
{
    private static readonly Brush Placeholder = new SolidColorBrush(Color.FromArgb(40, 128, 128, 128));

    private static Style? SubtitleStyle()
    {
        try { return (Style)Application.Current.Resources["SubtitleTextBlockStyle"]; }
        catch (Exception) { return null; }
    }

    public static FrameworkElement Tile(Copy copy, Action<Copy> open, double width = 128)
    {
        var item = copy.Item;
        var poster = new Border
        {
            Width = width, Height = item.Kind == Kind.Live ? width * 0.75 : width * 1.5, CornerRadius = new CornerRadius(6), Background = Placeholder,
            Child = new Image { Stretch = Stretch.UniformToFill, Source = Logos.LoadSized(item.Logo, (int)(width * 2)) },
        };
        var panel = new StackPanel { Width = width, Spacing = 2 };
        panel.Children.Add(poster);
        panel.Children.Add(new TextBlock { Text = item.Title, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1, Margin = new Thickness(0, 4, 0, 0) });
        var line = FolderNaming.TileLine(item.Year, null);
        if (line.Length > 0) panel.Children.Add(new TextBlock { Text = line, Opacity = 0.6, FontSize = 11 });
        var button = new Button { Content = panel, Padding = new Thickness(0), Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)), BorderThickness = new Thickness(0) };
        ToolTipService.SetToolTip(button, item.Title);
        button.Click += (_, _) => open(copy);
        return button;
    }

    /// <summary>Tiles with a picture. When any title in the row has one, the ones without are left out rather than shown as empty tiles.</summary>
    public static List<Copy> WithPictures(IEnumerable<Copy> copies)
    {
        var all = copies.ToList();
        var pictured = all.Where(c => !string.IsNullOrEmpty(c.Item.Logo)).ToList();
        return pictured.Count > 0 ? pictured : all;
    }

    public static FrameworkElement Strip(IEnumerable<Copy> copies, Action<Copy> open, double width = 128)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        foreach (var c in WithPictures(copies)) row.Children.Add(Tile(c, open, width));
        return new ScrollViewer { HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = row };
    }

    /// <summary>A shelf: its name, then the row. No caption under the name.</summary>
    public static FrameworkElement Shelf(string title, IEnumerable<Copy> copies, Action<Copy> open)
    {
        var shelf = new StackPanel { Spacing = 8 };
        shelf.Children.Add(new TextBlock { Text = title, Style = SubtitleStyle() });
        shelf.Children.Add(Strip(copies, open));
        return shelf;
    }

    /// <summary>The name of a folder with its count after it, smaller and dimmed, in brackets: "English · 4K (1,058)". A locked folder shows its name and a lock and no count.</summary>
    public static FrameworkElement FolderHeader(string display, int? count, bool locked, Action click)
    {
        var text = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        text.Children.Add(new TextBlock { Text = FolderNaming.Pretty(display), Style = SubtitleStyle(), VerticalAlignment = VerticalAlignment.Center });
        if (locked) text.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
        else if (count is not null) text.Children.Add(new TextBlock { Text = FolderNaming.CountText(count), FontSize = 12, Opacity = 0.55, VerticalAlignment = VerticalAlignment.Center });
        var button = new Button { Content = text, Padding = new Thickness(0), Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)), BorderThickness = new Thickness(0) };
        button.Click += (_, _) => click();
        return button;
    }
}
