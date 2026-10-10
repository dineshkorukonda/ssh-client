using System.IO;
using System.Security.Principal;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SSHClient.Windows;

public partial class App : Application
{
    private Mutex? instance;
    private EventWaitHandle? activate;
    private RegisteredWaitHandle? activationWait;
    private EventWaitHandle? shutdownSignal;
    private RegisteredWaitHandle? shutdownWait;
    private OwnedBackend? backend;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) => { ShowError(args.Exception); args.Handled = true; };
        if (e.Args.FirstOrDefault() == "--design-smoke")
        {
            try
            {
                var folder = e.Args[1]; Directory.CreateDirectory(folder);
                var window = new MainWindow(null, preview: true);
                Capture(window, 1280, 820, Path.Combine(folder, "hosts.png"));
                Capture(window, 960, 620, Path.Combine(folder, "hosts-compact.png"));
                window.Opacity = 0; window.ShowInTaskbar = false; window.Show();
                var dialog = new FormDialog(window, "Connect to Production EU", [new("user", "Username", "deploy"), new("password", "Password", Secret: true)], "Connect", "deploy@prod-eu.example.com:22\nCredentials are used for this session only.");
                if (dialog.Background is not SolidColorBrush background || background.Color != Color.FromRgb(24, 26, 32)) throw new IOException("Derived dialog lost its dark theme.");
                Capture(dialog, 480, 390, Path.Combine(folder, "connection.png"));
                var editor = new FormDialog(window, "SSH host", [new("name", "Name", "Production EU"), new("host", "Server address", "prod-eu.example.com"), new("auth", "Authentication", "key", Options: ["key", "password"]), new("identity", "Private key", "C:\\Users\\deploy\\.ssh\\production", File: true), new("notes", "Notes", "Primary application server", Multiline: true)]);
                Capture(editor, 480, 630, Path.Combine(folder, "host-editor.png"));
                window.Close();
                Shutdown(0);
            }
            catch (Exception error) { File.WriteAllText("native-smoke-error.txt", error.ToString()); Shutdown(1); }
            return;
        }
        if (e.Args.FirstOrDefault() == "--terminal-smoke")
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var report = e.Args[1];
            try
            {
                using var owned = new OwnedBackend(AppContext.BaseDirectory);
                using var api = await owned.StartAsync();
                var session = await api.PostAsync("sessions", new { id = "native-smoke", host = "127.0.0.1", port = int.Parse(e.Args[2]), user = "fixture", identity_file = e.Args[3] });
                var id = session.GetProperty("session_id").GetString()!;
                var window = new Window { Width = 800, Height = 500, ShowInTaskbar = false, Opacity = 0, WindowStyle = WindowStyle.None };
                using var terminal = new TerminalView(api, id, window, _ => { });
                window.Content = terminal; window.Show();
                await terminal.Ready.WaitAsync(TimeSpan.FromSeconds(30));
                await terminal.SendSmokeInputAsync("native-smoke\r");
                string screen = "";
                for (var i = 0; i < 100; i++)
                {
                    screen = await terminal.ReadScreenAsync();
                    if (screen.Contains("echo:native-smoke")) break;
                    await Task.Delay(100);
                }
                if (!screen.Contains("echo:native-smoke")) throw new IOException("Native terminal failed to render remote output: " + screen);
                var local = Path.Combine(Path.GetDirectoryName(report)!, "native-upload.txt");
                var downloaded = Path.Combine(Path.GetDirectoryName(report)!, "native-download.txt");
                File.WriteAllText(local, "native-transfer-content");
                await api.PostAsync($"files/{id}/upload", new { path = "native-roundtrip.txt", local_path = local });
                await api.PostAsync($"files/{id}/download", new { path = "native-roundtrip.txt", local_path = downloaded });
                if (File.ReadAllText(downloaded) != "native-transfer-content") throw new IOException("Native SFTP content mismatch");
                await api.PostAsync($"files/{id}/delete", new { path = "native-roundtrip.txt" });
                File.WriteAllText(report, System.Text.Json.JsonSerializer.Serialize(new { ready = true, terminal = true, sftp = true, screen }));
                window.Close(); Shutdown(0);
            }
            catch (Exception error) { File.WriteAllText(report, error.ToString()); Shutdown(1); }
            return;
        }
        if (e.Args.FirstOrDefault() == "--backend-smoke")
        {
            var report = e.Args.ElementAtOrDefault(1) ?? "backend-smoke.json";
            try
            {
                using var owned = new OwnedBackend(AppContext.BaseDirectory);
                using var api = await owned.StartAsync();
                var health = await api.GetAsync("health");
                File.WriteAllText(report, health.GetRawText());
                Shutdown(0);
            }
            catch (Exception error) { File.WriteAllText(report, error.ToString()); Shutdown(1); }
            return;
        }
        if (e.Args.FirstOrDefault() == "--smoke-test")
        {
            try
            {
                var window = new MainWindow(null, preview: true);
                var surface = (FrameworkElement)window.Content;
                surface.Measure(new Size(1120, 740));
                surface.Arrange(new Rect(0, 0, 1120, 740));
                surface.UpdateLayout();
                var bitmap = new RenderTargetBitmap(1120, 740, 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(surface);
                var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
                using var output = File.Create(e.Args.ElementAtOrDefault(1) ?? "native-smoke.png");
                png.Save(output);
                Shutdown(0);
            }
            catch (Exception error) { File.WriteAllText("native-smoke-error.txt", error.ToString()); Shutdown(1); }
            return;
        }

        var identity = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        var name = "Local\\ssh-client-" + identity;
        if (e.Args.FirstOrDefault() == "--shutdown")
        {
            try { using var signal = EventWaitHandle.OpenExisting(name + "-shutdown"); signal.Set(); }
            catch (WaitHandleCannotBeOpenedException) { }
            Shutdown(); return;
        }
        instance = new Mutex(true, name, out var firstInstance);
        if (!firstInstance)
        {
            try { using var signal = EventWaitHandle.OpenExisting(name + "-activate"); signal.Set(); }
            catch (WaitHandleCannotBeOpenedException) { }
            Shutdown(); return;
        }
        activate = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-activate");
        shutdownSignal = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-shutdown");
        shutdownWait = ThreadPool.RegisterWaitForSingleObject(shutdownSignal, (_, _) => Dispatcher.BeginInvoke(() => Shutdown()), null, Timeout.Infinite, false);
        var starting = new MainWindow(null);
        MainWindow = starting;
        starting.Show();
        activationWait = ThreadPool.RegisterWaitForSingleObject(activate, (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (MainWindow == null) return;
            MainWindow.WindowState = WindowState.Normal;
            MainWindow.Show(); MainWindow.Activate();
        }), null, Timeout.Infinite, false);

        try
        {
            backend = new OwnedBackend(AppContext.BaseDirectory);
            var api = await backend.StartAsync();
            if (MainWindow == null || !MainWindow.IsVisible) { api.Dispose(); backend.Dispose(); return; }
            var window = new MainWindow(api);
            MainWindow = window; window.Show(); starting.Close();
            _ = MonitorBackendAsync(backend);
        }
        catch (Exception error) { ShowError(error); Shutdown(1); }
    }

    private static void Capture(Window window, int width, int height, string path)
    {
        var surface = (FrameworkElement)window.Content;
        surface.Measure(new Size(width, height)); surface.Arrange(new Rect(0, 0, width, height)); surface.UpdateLayout();
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); bitmap.Render(surface);
        var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(path); png.Save(output);
    }

    private async Task MonitorBackendAsync(OwnedBackend owned)
    {
        while (MainWindow?.IsVisible == true)
        {
            await Task.Delay(1000);
            if (!owned.IsRunning)
            {
                ShowError(new IOException("The SSH backend stopped unexpectedly. Restart ssh-client. Existing remote sessions were disconnected."));
                Shutdown(1); return;
            }
        }
    }

    private static void ShowError(Exception error)
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ssh-client", "logs");
        Directory.CreateDirectory(path);
        File.AppendAllText(Path.Combine(path, "desktop.log"), $"{DateTimeOffset.Now:O} {error}\n");
        MessageBox.Show(error.Message + "\n\nLogs: " + path, "ssh-client", MessageBoxButton.OK, MessageBoxImage.Error);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        activationWait?.Unregister(null);
        shutdownWait?.Unregister(null);
        backend?.Dispose();
        activate?.Dispose();
        shutdownSignal?.Dispose();
        if (instance != null) { try { instance.ReleaseMutex(); } catch (ApplicationException) { } instance.Dispose(); }
        base.OnExit(e);
    }
}
