using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using StreamSetu.Core;

namespace StreamSetu.App;

public sealed record RecRow(Recording Recording, string Title, string Detail);

public sealed partial class RecordingsPage : Page
{
    private readonly Action _refresh;

    public RecordingsPage()
    {
        InitializeComponent();
        _refresh = () => DispatcherQueue.TryEnqueue(Reload);
        RecordingService.Changed += _refresh;
        Unloaded += (_, _) => RecordingService.Changed -= _refresh;
        Reload();
    }

    private static string Size(long bytes) => bytes switch { >= 1L << 30 => $"{bytes / (double)(1L << 30):0.0} GB", >= 1L << 20 => $"{bytes / (double)(1L << 20):0} MB", > 0 => $"{bytes / 1024} KB", _ => "" };

    private void Reload()
    {
        var selected = (RecList.SelectedItem as RecRow)?.Recording.Id;
        var rows = new List<RecRow>();
        foreach (var r in AppServices.Recordings.All())
        {
            var state = r.Status switch { RecordingStatus.Scheduled => "Scheduled", RecordingStatus.Recording => "Recording now", RecordingStatus.Done => "Done", RecordingStatus.Cancelled => "Stopped", _ => "Did not work" };
            rows.Add(new RecRow(r, r.Name, $"{r.Start.ToLocalTime():ddd d MMM HH:mm}–{r.Stop.ToLocalTime():HH:mm}  ·  {state}" + (r.Bytes > 0 ? $"  ·  {Size(r.Bytes)}" : "") + (r.Message is null ? "" : $"  ·  {r.Message}")));
        }
        foreach (var rem in AppServices.Reminders.All().Where(x => x.Start > DateTimeOffset.UtcNow.AddMinutes(-5)))
            rows.Add(new RecRow(new Recording("reminder:" + rem.Id, rem.Title, "", rem.Start, rem.Start), $"Reminder: {rem.Title}", $"{rem.Channel}  ·  {rem.Start.ToLocalTime():ddd d MMM HH:mm}  ·  {rem.LeadMinutes} minutes before"));
        RecList.ItemsSource = rows;
        if (selected is not null) RecList.SelectedItem = rows.FirstOrDefault(x => x.Recording.Id == selected);
    }

    private Recording? Selected => (RecList.SelectedItem as RecRow)?.Recording;

    private void OnStop(object sender, RoutedEventArgs e) { if (Selected is { } r) RecordingService.Stop(r.Id); }

    private void OnRemove(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } r) return;
        if (r.Id.StartsWith("reminder:")) AppServices.Reminders.Remove(r.Id["reminder:".Length..]);
        else { RecordingService.Stop(r.Id); AppServices.Recordings.Remove(r.Id); }       // the file, if any, is not deleted
        Reload();
    }

    private void OnOpenFile(object sender, RoutedEventArgs e)
    {
        if (Selected is { Path: { } path } && File.Exists(path)) Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private void OnOpenFolder(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(RecordingService.Folder);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{RecordingService.Folder}\"") { UseShellExecute = true });
    }
}
