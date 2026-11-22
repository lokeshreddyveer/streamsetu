using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using StreamSetu.Core;

namespace StreamSetu.App;

public sealed partial class SettingsPage
{
    private void LoadHomeSettings()
    {
        var s = AppServices.Settings;
        PreferredLanguageBox.Text = s.PreferredLanguage ?? "";
        TmdbSwitch.IsOn = s.TmdbEnabled;
        TmdbKeyBox.Password = AppServices.Secrets.Get("tmdb:key") ?? "";
        TmdbNotice.Text = Tmdb.Attribution;
        try { TmdbLogo.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "TMDBLogo.png"))); }
        catch (Exception) { /* the notice is shown without the picture */ }
        ShowTmdbStatus();
    }

    private void ShowTmdbStatus()
    {
        var hasKey = !string.IsNullOrWhiteSpace(TmdbKeyBox.Password);
        TmdbStatus.Text = !TmdbSwitch.IsOn ? "Off. Top This Week uses what is popular in your own library."
            : hasKey ? "On, with your key. The weekly list is fetched at most once a day and matched on this computer."
            : "On, but waiting for your own TMDB key. Until then Top This Week uses what is popular in your own library.";
    }

    private void OnHomeSettingChanged(object sender, RoutedEventArgs e)
    {
        if (_quiet) return;
        var name = PreferredLanguageBox.Text.Trim();
        var known = CanonicalPick.LanguageName(name);
        AppServices.SaveSettings(AppServices.Settings with { PreferredLanguage = name.Length == 0 ? null : known ?? name });
        if (name.Length > 0 && known is null) Say("That language is saved as typed; Home matches it against the languages in titles and folder names.", InfoBarSeverity.Informational);
    }

    private void OnTmdbToggled(object sender, RoutedEventArgs e)
    {
        if (_quiet) return;
        AppServices.SaveSettings(AppServices.Settings with { TmdbEnabled = TmdbSwitch.IsOn });
        if (!TmdbSwitch.IsOn) Tmdb.Clear(AppServices.Store);               // switched off: the list is forgotten
        ShowTmdbStatus();
    }

    private void OnTmdbKeyChanged(object sender, RoutedEventArgs e)
    {
        if (_quiet) return;
        var key = TmdbKeyBox.Password.Trim();
        if (key.Length > 0) AppServices.Secrets.Set("tmdb:key", key);
        else { AppServices.Secrets.Delete("tmdb:key"); Tmdb.Clear(AppServices.Store); }              // the key removed: nothing from TMDB is kept
        ShowTmdbStatus();
    }
}
