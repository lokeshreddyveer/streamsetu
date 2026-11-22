using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using StreamSetu.Core;
using StreamSetu.Core.SmartMix;

namespace StreamSetu.App;

/// <summary>Home: the hero, then Top This Week, Trending, Because You Watched, Rediscover and the preferred language. Everything comes from the library already loaded: Shuffle only changes the arrangement and never refreshes a connection.
/// Locked, hidden and (in a Kids profile) adult folders, and any title with a copy there, never appear, even while a folder is unlocked.</summary>
public sealed partial class HomePage : Page
{
    private HomeContent? _home;
    private int _hero;
    private int _build;

    public HomePage() { InitializeComponent(); }

    protected override async void OnNavigatedTo(NavigationEventArgs e) => await BuildAsync();

    private void Say(string text, InfoBarSeverity severity) { Message.Message = text; Message.Severity = severity; Message.IsOpen = true; }

    private async void OnShuffle(object sender, RoutedEventArgs e)
    {
        AppServices.Mix.Reshuffle();             // a different draw of the same library: no connection is touched
        _hero = 0;
        await BuildAsync();
    }

    private async Task BuildAsync()
    {
        var mine = ++_build;
        Busy.IsActive = true; Message.IsOpen = false;
        try
        {
            if (AppServices.Playlists().Count == 0) { ShelfHost.Children.Clear(); Say("Add a connection first (Connections, at the bottom of the menu).", InfoBarSeverity.Informational); return; }
            var copies = await AppServices.AllCopiesAsync();
            var tmdb = await AppServices.TrendingAsync();
            if (mine != _build) return;
            var mix = AppServices.Mix.Open(AppServices.DayKey());
            var inputs = AppServices.BuildHomeInputs(copies, tmdb);
            var home = await Task.Run(() => HomeBuilder.Build(inputs, mix.State, SmartMixStore.ProfileKey, mix.Refresh, commit: true));
            if (mine != _build) return;
            mix.Save();
            _home = home;
            Render();
            if (home.Hero.Count == 0 && home.Shelves.Count == 0) Say("Nothing to show yet. Open Movies or Series once the connection has loaded.", InfoBarSeverity.Informational);
        }
        catch (Exception ex) { if (mine == _build) Say(ex.Message, InfoBarSeverity.Error); }
        finally { if (mine == _build) Busy.IsActive = false; }
    }

    private void Render()
    {
        ShelfHost.Children.Clear();
        if (_home is null) return;
        var hero = Tiles.WithPictures(_home.Hero);
        if (hero.Count > 0) ShelfHost.Children.Add(HeroCard(hero));
        foreach (var shelf in _home.Shelves) ShelfHost.Children.Add(Tiles.Shelf(shelf.Title, shelf.Items, Open));
    }

    /// <summary>The first title large. The pictures are posters (a playlist gives no wide image), shown as they are rather than stretched; the arrows move through the others.</summary>
    private FrameworkElement HeroCard(List<Copy> hero)
    {
        var copy = hero[Math.Min(_hero, hero.Count - 1)];
        var grid = new Grid { ColumnSpacing = 20, Padding = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var image = new Image { Width = 170, Height = 255, Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill, Source = Logos.LoadSized(copy.Item.Logo, 340) };
        grid.Children.Add(new Border { Width = 170, Height = 255, CornerRadius = new CornerRadius(8), Child = image });

        var text = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = copy.Item.Title, FontSize = 28, TextWrapping = TextWrapping.Wrap, MaxLines = 3 });
        var line = FolderNaming.TileLine(copy.Item.Year, null);
        if (line.Length > 0) text.Children.Add(new TextBlock { Text = line, Opacity = 0.65 });
        if (!string.IsNullOrWhiteSpace(copy.Item.Plot)) text.Children.Add(new TextBlock { Text = copy.Item.Plot, Opacity = 0.8, TextWrapping = TextWrapping.Wrap, MaxLines = 4 });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
        var play = new Button { Content = copy.Item.Kind == Kind.Series ? "Choose an episode" : "Play", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        play.Click += (_, _) => Open(copy);
        buttons.Children.Add(play);
        if (hero.Count > 1)
        {
            var prev = new Button { Content = "‹" }; prev.Click += (_, _) => { _hero = (_hero + hero.Count - 1) % hero.Count; Render(); };
            var next = new Button { Content = "›" }; next.Click += (_, _) => { _hero = (_hero + 1) % hero.Count; Render(); };
            buttons.Children.Add(prev); buttons.Children.Add(next);
        }
        text.Children.Add(buttons);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    private async void Open(Copy copy)
    {
        var playlist = AppServices.Playlists().FirstOrDefault(p => p.Id == copy.PlaylistId);
        if (playlist is null) return;
        try
        {
            var loaded = await AppServices.LoadAsync(playlist);
            await ItemOpener.OpenAsync(Frame, XamlRoot, playlist, loaded, copy.Item, b => Busy.IsActive = b, Say);
        }
        catch (Exception ex) { Say(ex.Message, InfoBarSeverity.Error); }
    }
}
