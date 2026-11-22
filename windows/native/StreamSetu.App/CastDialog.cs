using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using StreamSetu.Core;
using Windows.UI;

namespace StreamSetu.App;

/// <summary>The cast of a title as a row of people (photo from TMDB, or their initials), and, from a person, their other titles that are in the library, each once. Needs the person's own TMDB key.
/// Nothing is looked up for a title in a locked, hidden or adult-blocked folder, or with a copy there. Sizes follow the Windows text size.</summary>
internal static class CastDialog
{
    public static async Task ShowAsync(XamlRoot root, Copy copy, List<Copy> all, Action<Copy> open)
    {
        var key = AppServices.Secrets.Get("tmdb:key");
        if (!AppServices.Settings.TmdbEnabled || string.IsNullOrWhiteSpace(key))
        {
            await Dialogs.MessageAsync(root, copy.Item.Title, "The cast comes from TMDB. Add your own free TMDB key in Settings, under Home, to see it.");
            return;
        }
        AppServices.Allow.Add("api.themoviedb.org"); AppServices.Allow.Add(CastMember.PhotoHost);
        var fetcher = new SafeTextFetcher(AppServices.Http);
        var snapshot = Privacy.Snapshot(AppServices.PrivacyNow(), Surface.Recommend, all);                  // always the strict view, even after a PIN
        var scale = TextScale();

        var host = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, MinWidth = 420 };
        var dialog = new ContentDialog { Title = copy.Item.Title, Content = host, CloseButtonText = "Close", XamlRoot = root };
        host.Content = new ProgressRing { IsActive = true, Width = 32, Height = 32 };
        var shown = dialog.ShowAsync();
        List<CastMember>? cast = null;
        try { cast = await TmdbCast.CastOfAsync(fetcher, key!, snapshot, copy); } catch (Exception) { /* shown as "no cast" */ }

        void ShowCast()
        {
            if (cast is null || cast.Count == 0) { host.Content = new TextBlock { Text = "No cast was found for this title.", TextWrapping = TextWrapping.Wrap }; return; }
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            foreach (var person in cast) row.Children.Add(PersonTile(person, scale, () => _ = ShowPersonAsync(person)));
            host.Content = new ScrollViewer { HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = row };
            dialog.Title = copy.Item.Title;
        }

        async Task ShowPersonAsync(CastMember person)
        {
            dialog.Title = person.Name;
            host.Content = new ProgressRing { IsActive = true, Width = 32, Height = 32 };
            List<PersonTitle> titles;
            try
            {
                var credits = await TmdbCast.FilmographyAsync(fetcher, key!, person);
                var ctx = new CanonicalPick.Context(AppServices.Settings.PreferredLanguage, AppServices.SourceRank());
                titles = TmdbCast.InLibrary(credits, all, snapshot, ctx);
            }
            catch (Exception) { titles = new List<PersonTitle>(); }
            var panel = new StackPanel { Spacing = 10 };
            var back = new Button { Content = "‹ Cast" }; back.Click += (_, _) => ShowCast();
            AutomationProperties.SetName(back, "Back to the cast");
            panel.Children.Add(back);
            panel.Children.Add(new TextBlock { Text = titles.Count == 0 ? $"None of {person.Name}'s other titles are in your library." : titles.Count == 1 ? "1 title in your library" : $"{titles.Count} titles in your library", Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
            if (titles.Count > 0) panel.Children.Add(Tiles.Strip(titles.Select(t => t.Pick), c => { dialog.Hide(); open(c); }));
            host.Content = panel;
        }

        ShowCast();
        await shown;
    }

    /// <summary>1.0 at the normal Windows text size, larger when the person made text bigger.</summary>
    private static double TextScale()
    {
        try { return Math.Clamp(new Windows.UI.ViewManagement.UISettings().TextScaleFactor, 1.0, 2.25); }
        catch (Exception) { return 1.0; }
    }

    private static FrameworkElement PersonTile(CastMember person, double scale, Action open)
    {
        var size = 76 * scale;
        var (r, g, b) = Placeholders.Rgb(Placeholders.Hue(person.Name));
        var photo = new Grid { Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center };
        photo.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Fill = new SolidColorBrush(Color.FromArgb(255, r, g, b)) });
        photo.Children.Add(new TextBlock { Text = Placeholders.Monogram(person.Name), FontSize = 24 * scale, Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        if (person.PhotoUrl is { } url)
            photo.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Fill = new ImageBrush { Stretch = Stretch.UniformToFill, ImageSource = Logos.LoadSized(url, (int)(size * 2)) } });
        var panel = new StackPanel { Width = 104 * scale, Spacing = 4 };
        panel.Children.Add(photo);
        panel.Children.Add(new TextBlock { Text = person.Name, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis });
        if (person.Character is { } ch) panel.Children.Add(new TextBlock { Text = ch, Opacity = 0.65, FontSize = 12, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis });
        var button = new Button { Content = panel, Padding = new Thickness(4), Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)), BorderThickness = new Thickness(0) };
        AutomationProperties.SetName(button, person.Character is { } c ? $"{person.Name}, as {c}. Show their other titles" : $"{person.Name}. Show their other titles");
        button.Click += (_, _) => open();
        return button;
    }
}
