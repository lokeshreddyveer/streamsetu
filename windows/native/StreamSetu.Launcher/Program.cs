using System.Diagnostics;
using System.Windows.Forms;
using StreamSetu.Core;

namespace StreamSetu.Launcher;

/// <summary>The one-file download. It unpacks the app once into %LOCALAPPDATA%\StreamSetu\app-&lt;version&gt;\, checks every file against the list inside it on every start (putting back what is missing or changed),
/// and starts the real StreamSetu.exe from there with the same command line. It writes nowhere else, never touches the person's library or settings (they live in %LOCALAPPDATA%\StreamSetu itself),
/// and removes the folders of older versions only once the new one is running.
/// For testing: STREAMSETU_LAUNCHER_ROOT (another folder), STREAMSETU_LAUNCHER_QUIET=1 (no window), STREAMSETU_LAUNCHER_NOSTART=1 (unpack and check, do not start).</summary>
internal static class Program
{
    private static string? Env(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : null;

    [STAThread]
    private static int Main(string[] args)
    {
        var quiet = Env("STREAMSETU_LAUNCHER_QUIET") == "1";
        var exe = Environment.ProcessPath ?? "";
        try
        {
            var located = Payload.Locate(exe);
            if (located is null) return Fail(quiet, "This copy of StreamSetu is incomplete (its package is missing). Download it again.", 2);
            var manifest = located.Manifest;
            var dataRoot = Env("STREAMSETU_LAUNCHER_ROOT") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StreamSetu");
            var folder = Payload.AppFolder(dataRoot, manifest.Version);

            // Two launches at once: one unpacks, the other waits and then finds it done.
            using var gate = new Mutex(false, "Local\\StreamSetu.Launcher." + manifest.Version);
            var held = false;
            try { held = gate.WaitOne(TimeSpan.FromMinutes(3)); } catch (AbandonedMutexException) { held = true; }
            try
            {
                var problems = Payload.Problems(folder, manifest);
                if (problems.Count > 0) Unpack(exe, located, folder, problems, quiet);
            }
            finally { if (held) gate.ReleaseMutex(); }

            if (Env("STREAMSETU_LAUNCHER_NOSTART") == "1") return 0;
            var start = new ProcessStartInfo(Path.Combine(folder, manifest.Exe)) { WorkingDirectory = folder, UseShellExecute = false };
            foreach (var a in args) start.ArgumentList.Add(a);
            using var app = Process.Start(start);
            if (app is null) return Fail(quiet, "StreamSetu could not be started.", 4);
            // Older versions go only after this one has stayed up for a while.
            if (!app.WaitForExit(15_000)) Payload.RemoveOlder(dataRoot, manifest.Version);
            return 0;
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return Fail(quiet, "StreamSetu could not be prepared: " + ex.Message, 3);
        }
    }

    private static void Unpack(string exe, Payload.Located located, string folder, List<string> problems, bool quiet)
    {
        if (quiet) { Payload.Restore(exe, located, folder, problems); return; }
        ApplicationConfiguration.Initialize();
        var label = new Label { Text = "Preparing StreamSetu. This only happens the first time.", AutoSize = false, Dock = DockStyle.Top, Height = 44, Padding = new Padding(0, 4, 0, 0) };
        var bar = new ProgressBar { Dock = DockStyle.Top, Minimum = 0, Maximum = 1000, Height = 22 };
        var form = new Form
        {
            Text = "StreamSetu", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, ControlBox = false, StartPosition = FormStartPosition.CenterScreen,
            ClientSize = new Size(420, 96), Padding = new Padding(16), ShowInTaskbar = true,
        };
        form.Controls.Add(bar); form.Controls.Add(label);
        Exception? failure = null;
        form.Shown += async (_, _) =>
        {
            try { await Task.Run(() => Payload.Restore(exe, located, folder, problems, p => form.BeginInvoke(new Action(() => bar.Value = (int)Math.Clamp(p * 1000, 0, 1000))))); }
            catch (Exception e) { failure = e; }
            form.Close();
        };
        Application.Run(form);
        if (failure is not null) throw new IOException(failure.Message, failure);
    }

    private static int Fail(bool quiet, string message, int code)
    {
        if (quiet) Console.Error.WriteLine(message); else MessageBox.Show(message, "StreamSetu", MessageBoxButtons.OK, MessageBoxIcon.Error);
        return code;
    }
}
