using Microsoft.UI.Xaml;

namespace StreamSetu.App;

public partial class App : Application
{
    private MainWindow? _window;

    public App() { InitializeComponent(); }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        AppServices.AllowSavedHosts();
        _window = new MainWindow();
        _window.Activate();
    }
}
