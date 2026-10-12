using System.IO;
using System.Security.Principal;
using System.Text.Json;
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
        ThemeManager.ApplyTheme(AppTheme.Dark);
        DispatcherUnhandledException += (_, args) => { ShowError(args.Exception); args.Handled = true; };
        if (e.Args.FirstOrDefault() == "--design-smoke")
        {
            try
            {
                var folder = e.Args[1]; Directory.CreateDirectory(folder);
                var window = new MainWindow(null, preview: true);

                // 1. Dashboard (Command Center) Dark
                window.ShowDashboardForPreview();
                Capture(window, 1280, 820, Path.Combine(folder, "hosts.png"));
                Capture(window, 1280, 820, Path.Combine(folder, "dashboard_dark.png"));
                Capture(window, 960, 620, Path.Combine(folder, "hosts-compact.png"));

                // 2. Hosts Inventory Page Dark
                window.ShowHostsForPreview();
                Capture(window, 1280, 820, Path.Combine(folder, "hosts_dark.png"));
                Capture(window, 720, 540, Path.Combine(folder, "hosts-minimum.png"));
                Capture(window, 720, 540, Path.Combine(folder, "hosts-150dpi.png"), 1.5);

                // 3. Add Host Full Page Editor
                window.ShowAddHostForPreview();
                Capture(window, 1280, 820, Path.Combine(folder, "add-host-page.png"));

                // 4. SFTP File Center Dark
                window.ShowSftpForPreview();
                Capture(window, 1280, 820, Path.Combine(folder, "sftp_dark.png"));

                // 5. Key Vault Dark
                window.ShowKeysForPreview();
                Capture(window, 1280, 820, Path.Combine(folder, "keys_dark.png"));

                // 6. Auth / Login (Master Keyring Unlock)
                window.ShowAuthForPreview();
                Capture(window, 1280, 820, Path.Combine(folder, "auth_login.png"));

                // 7. Light Bauhaus Edition Previews
                window.SwitchThemeForPreview(AppTheme.Light);
                window.ShowDashboardForPreview();
                Capture(window, 1280, 820, Path.Combine(folder, "dashboard_light.png"));
                window.ShowHostsForPreview();
                Capture(window, 1280, 820, Path.Combine(folder, "hosts_light.png"));

                // Revert to Dark for dialog check
                window.SwitchThemeForPreview(AppTheme.Dark);
                window.Opacity = 0; window.ShowInTaskbar = false; window.Show();
                var dialog = new FormDialog(window, "Connect to Production EU", [new("user", "Username", "deploy"), new("password", "Password", Secret: true)], "Connect", "deploy@prod-eu.example.com:22\nCredentials are used for this session only.");
                if (dialog.Background is not SolidColorBrush background || (background.Color != Color.FromRgb(9, 9, 11) && background.Color != Color.FromRgb(0, 0, 0) && background.Color != Color.FromRgb(17, 20, 24) && background.Color != Color.FromRgb(22, 26, 32) && background.Color != Color.FromRgb(24, 26, 32))) throw new IOException("Derived dialog lost its dark theme.");
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
                var host = new Host { Id = "native-smoke", Name = "Native host contract regression", Address = "localhost", Port = int.Parse(e.Args[2]), User = "fixture", IdentityFile = e.Args[3] };
                await api.PostAsync("hosts", host);
                var savedHosts = (await api.GetAsync("hosts")).Deserialize<List<Host>>(DesktopClient.Json)!;
                var savedHost = savedHosts.Single(h => h.Id == host.Id);
                if (savedHost.Address != "localhost") throw new IOException("Saved host address was not loaded into the Windows host model.");
                var editedHost = savedHost.Copy();
                editedHost.Address = "127.0.0.1";
                await api.PostAsync("hosts", editedHost);
                var reloadedHosts = (await api.GetAsync("hosts")).Deserialize<List<Host>>(DesktopClient.Json)!;
                var connectionHost = reloadedHosts.Single(h => h.Id == host.Id);
                if (connectionHost.Address != "127.0.0.1") throw new IOException("Edited host address was not persisted.");
                var session = await api.PostAsync("sessions", connectionHost);
                var id = session.GetProperty("session_id").GetString()!;
                var window = new MainWindow(api) { ShowInTaskbar = false, Opacity = 0 };
                window.Show();
                var terminal = window.OpenSessionForSmoke(connectionHost, id);
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
                var local = Path.Combine(Path.GetDirectoryName(report)!, "client-files", "native-upload.txt");
                Directory.CreateDirectory(Path.GetDirectoryName(local)!);
                var downloaded = Path.Combine(Path.GetDirectoryName(report)!, "native-download.txt");
                File.WriteAllText(local, "native-transfer-content");
                await api.PostAsync($"files/{id}/upload", new { path = "native-roundtrip.txt", local_path = local });
                await api.PostAsync($"files/{id}/download", new { path = "native-roundtrip.txt", local_path = downloaded });
                if (File.ReadAllText(downloaded) != "native-transfer-content") throw new IOException("Native SFTP content mismatch");
                await api.PostAsync($"files/{id}/delete", new { path = "native-roundtrip.txt" });
                File.WriteAllText(report + ".progress", "files journey");
                await window.VerifyFilesForSmokeAsync(id, local);
                File.WriteAllText(report + ".progress", "session journey");
                await window.VerifySessionLifecycleForSmokeAsync(connectionHost, id);
                File.WriteAllText(report + ".progress", "productivity journey");
                await window.VerifyProductivityForSmokeAsync(connectionHost);
                File.WriteAllText(report + ".progress", "connection dialog");
                await window.VerifyConnectionFormForSmokeAsync(connectionHost);
                File.WriteAllText(report + ".progress", "completed");
                await api.RequestAsync(System.Net.Http.HttpMethod.Delete, "hosts/" + host.Id);
                File.WriteAllText(report, System.Text.Json.JsonSerializer.Serialize(new { ready = true, terminal = true, sftp = true, files_page = true, session_lifecycle = true, host_editor = true, preferences = true, palette = true, accessible_names = true, connection_dialog = true, screen }));
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
        var starting = new StartupWindow();
        MainWindow = starting;
        starting.Show();
        activationWait = ThreadPool.RegisterWaitForSingleObject(activate, (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (MainWindow == null) return;
            MainWindow.WindowState = WindowState.Normal;
            MainWindow.Show(); MainWindow.Activate();
        }), null, Timeout.Infinite, false);

        starting.Retry = () => LaunchBackendAsync(starting);
        await LaunchBackendAsync(starting);
    }

    private async Task LaunchBackendAsync(StartupWindow starting)
    {
        try
        {
            backend?.Dispose();
            backend = new OwnedBackend(AppContext.BaseDirectory);
            var api = await backend.StartAsync();
            if (MainWindow == null || !MainWindow.IsVisible) { api.Dispose(); backend.Dispose(); return; }
            var window = new MainWindow(api);
            window.RestartBackend = async () => {
                var retry = new StartupWindow(); MainWindow = retry; retry.Show(); window.Close();
                retry.Retry = () => LaunchBackendAsync(retry); await LaunchBackendAsync(retry);
            };
            MainWindow = window; window.Show(); starting.Close();
            _ = MonitorBackendAsync(backend);
        }
        catch (Exception error) { backend?.Dispose(); starting.Fail(error.Message); }
    }

    private static void Capture(Window window, int width, int height, string path, double dpiScale = 1)
    {
        (window as MainWindow)?.SetPreviewWidth(width);
        var surface = (FrameworkElement)window.Content;
        surface.Measure(new Size(width, height)); surface.Arrange(new Rect(0, 0, width, height)); surface.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)(width * dpiScale), (int)(height * dpiScale), 96 * dpiScale, 96 * dpiScale, PixelFormats.Pbgra32); bitmap.Render(surface);
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
                if (MainWindow is MainWindow window) window.SetBackendUnavailable();
                return;
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
