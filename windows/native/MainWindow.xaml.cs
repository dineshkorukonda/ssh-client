using System.Windows;
using System.Windows.Controls;
using System.Net.Http;
using System.Text.Json;
namespace SSHClient.Windows;
public partial class MainWindow : Window
{
    private readonly DesktopClient? api;
    private List<Host> hosts = new();
    private readonly List<TerminalView> terminals = new();
    private readonly Dictionary<string, string> hostBySession = new();
    public MainWindow(DesktopClient? api, bool preview = false)
    {
        this.api = api; InitializeComponent();
        if (api != null) Loaded += async (_, _) => await GuardAsync(InitializeAsync);
        else if (preview)
        {
            hosts = [new Host { Name = "Production", Address = "server.example.com", User = "deploy" }, new Host { Name = "Development", Address = "192.168.1.20", User = "ubuntu" }];
            FilterHosts(); Status.Text = "Ready. Select a host to connect.";
        }
        Closed += (_, _) => { foreach (var view in terminals) view.Dispose(); api?.Dispose(); };
    }

    private async Task InitializeAsync()
    {
        await RefreshAsync();
        var saved = await api!.GetAsync("workspace");
        if (saved.TryGetProperty("host_ids", out var ids) && ids.GetArrayLength() > 0 &&
            MessageBox.Show(this, "Restore saved terminal tabs? Each connection will request credentials as needed.", "Restore workspace", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes)
        {
            foreach (var id in ids.EnumerateArray())
            {
                var host = hosts.FirstOrDefault(h => h.Id == id.GetString());
                if (host != null) await ConnectHostAsync(host);
            }
        }
    }
    private async Task SaveWorkspaceAsync() => await api!.PostAsync("workspace", new { host_ids = terminals.Select(view => hostBySession[view.SessionId]).ToArray() });

    private async Task GuardAsync(Func<Task> operation)
    {
        if (api == null) return;
        try { await operation(); }
        catch (Exception error) { Status.Text = error.Message; MessageBox.Show(this, error.Message, "ssh-client", MessageBoxButton.OK, MessageBoxImage.Error); }
    }
    private async Task RefreshAsync()
    {
        var response = await api!.GetAsync("hosts");
        hosts = response.Deserialize<List<Host>>(DesktopClient.Json) ?? new();
        FilterHosts(); Status.Text = "Ready. Select a host to connect.";
    }
    private void FilterHosts()
    {
        if (Hosts == null || Search == null) return;
        var query = Search.Text;
        Hosts.ItemsSource = hosts.Where(host => (host.Name + " " + host.Description).Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
    }
    private void Search_Changed(object sender, TextChangedEventArgs args) => FilterHosts();
    private async void Add_Click(object sender, RoutedEventArgs args) => await GuardAsync(() => EditHostAsync(new Host()));
    private async void Edit_Click(object sender, RoutedEventArgs args)
    {
        if (Hosts.SelectedItem is Host host) await GuardAsync(() => EditHostAsync(host.Copy()));
    }
    private async Task EditHostAsync(Host host)
    {
        var dialog = new FormDialog(this, "SSH host", [new("name", "Name", host.Name), new("host", "Server address", host.Address), new("port", "SSH port", host.Port.ToString()), new("user", "Username", host.User), new("auth", "Authentication: key or password", host.DefaultAuthMethod), new("identity", "Private key", host.IdentityFile ?? "", File: true), new("jump", "Jump host (optional)", host.ProxyJump ?? "")]);
        if (dialog.ShowDialog() != true) return;
        var values = dialog.Values;
        if (!int.TryParse(values["port"], out var port) || port is < 1 or > 65535) throw new ArgumentException("SSH port must be between 1 and 65535.");
        if (string.IsNullOrWhiteSpace(values["host"]) || string.IsNullOrWhiteSpace(values["user"])) throw new ArgumentException("Server address and username are required.");
        if (values["auth"] is not ("key" or "password")) throw new ArgumentException("Authentication must be key or password.");
        host.Name = string.IsNullOrWhiteSpace(values["name"]) ? values["host"].Trim() : values["name"].Trim();
        host.Address = values["host"].Trim(); host.Port = port; host.User = values["user"].Trim(); host.DefaultAuthMethod = values["auth"];
        host.IdentityFile = string.IsNullOrWhiteSpace(values["identity"]) ? null : values["identity"];
        host.ProxyJump = string.IsNullOrWhiteSpace(values["jump"]) ? null : values["jump"].Trim();
        await api!.PostAsync("hosts", host); await RefreshAsync();
    }
    private async void Remove_Click(object sender, RoutedEventArgs args)
    {
        if (Hosts.SelectedItem is not Host host) return;
        if (MessageBox.Show(this, $"Remove saved host {host.Name}?", "Remove host", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        await GuardAsync(async () => { await api!.RequestAsync(HttpMethod.Delete, "hosts/" + Uri.EscapeDataString(host.Id)); await RefreshAsync(); });
    }
    private async void Connect_Click(object sender, RoutedEventArgs args)
    {
        if (Hosts.SelectedItem is not Host host) return;
        await GuardAsync(() => ConnectHostAsync(host));
    }
    private async Task ConnectHostAsync(Host host)
    {
            var fields = new List<Field> { new("user", "Username", host.User), new("password", "Password (optional)", Secret: true), new("passphrase", "Private-key passphrase (optional)", Secret: true) };
            if (!string.IsNullOrWhiteSpace(host.ProxyJump)) fields.AddRange([new("jump_user", "Jump-host username (optional)"), new("jump_password", "Jump-host password (optional)", Secret: true), new("jump_identity", "Jump-host private key (optional)", File: true), new("jump_passphrase", "Jump-host key passphrase (optional)", Secret: true)]);
            var dialog = new FormDialog(this, "Connect to " + host.Name, fields, "Connect", "Passwords and passphrases are used for this session. Existing saved credentials can be used when left blank.");
            if (dialog.ShowDialog() != true) return;
            var values = dialog.Values;
            var attrs = JsonSerializer.SerializeToElement(host, DesktopClient.Json).Deserialize<Dictionary<string, object?>>()!;
            attrs["user"] = values["user"];
            if (values["password"] != "") attrs["password"] = values["password"];
            if (values["passphrase"] != "") attrs["passphrase"] = values["passphrase"];
            if (!string.IsNullOrWhiteSpace(host.ProxyJump))
            {
                var jump = new Dictionary<string, string>();
                foreach (var key in new[] { "user", "password", "passphrase" }) if (values["jump_" + key] != "") jump[key] = values["jump_" + key];
                if (values["jump_identity"] != "") jump["identity_file"] = values["jump_identity"];
                attrs["jump_credentials"] = jump;
            }
            var result = await api!.PostAsync("sessions", attrs);
            AddTerminal(host.Name, result.GetProperty("session_id").GetString()!);
            hostBySession[result.GetProperty("session_id").GetString()!] = host.Id;
            await SaveWorkspaceAsync();
    }
    private void AddTerminal(string title, string id)
    {
        var tab = new TabItem();
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        var close = new Button { Content = "Close", Padding = new Thickness(6, 2, 6, 2), Margin = new Thickness(12, 0, 0, 0), FontSize = 10 };
        header.Children.Add(close); tab.Header = header;
        var content = new DockPanel();
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8) };
        foreach (var action in new[] { "Disconnect", "Reconnect" })
        {
            var button = new Button { Content = action };
            button.Click += async (_, _) => await GuardAsync(async () => { await api!.PostAsync($"sessions/{id}/{action.ToLowerInvariant()}", new { }); });
            actions.Children.Add(button);
        }
        DockPanel.SetDock(actions, Dock.Top); content.Children.Add(actions);
        var view = new TerminalView(api!, id, this, text => { if (Sessions.SelectedItem == tab) Status.Text = title + ": " + text; });
        content.Children.Add(view); tab.Content = content; tab.Tag = view; terminals.Add(view);
        close.Click += async (_, _) => await GuardAsync(async () =>
        {
            await api!.RequestAsync(HttpMethod.Delete, "sessions/" + id);
            view.Dispose(); terminals.Remove(view); Sessions.Items.Remove(tab);
            hostBySession.Remove(id); await SaveWorkspaceAsync();
            Empty.Visibility = Sessions.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        });
        Sessions.Items.Add(tab); Sessions.SelectedItem = tab; Empty.Visibility = Visibility.Collapsed;
    }
    private void Files_Click(object sender, RoutedEventArgs args)
    {
        if (api != null && Sessions.SelectedItem is TabItem { Tag: TerminalView view }) new FilesWindow(api, view.SessionId) { Owner = this }.Show();
        else Status.Text = "Open a terminal connection before browsing files.";
    }
    private async void Workspaces_Click(object sender, RoutedEventArgs args) => await GuardAsync(async () =>
    {
        var saved = await api!.GetAsync("workspaces");
        var list = new ListBox { Margin = new Thickness(24) };
        foreach (var workspace in saved.EnumerateArray())
        {
            if (!workspace.TryGetProperty("host_ids", out _)) continue;
            var name = workspace.TryGetProperty("name", out var n) ? n.GetString() : "Previous session";
            list.Items.Add(new ListBoxItem { Content = name, Tag = workspace });
        }
        var chooser = new Window { Owner = this, Title = "Open workspace", Width = 420, Height = 320, Content = list, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        list.MouseDoubleClick += (_, _) => { if (list.SelectedItem != null) chooser.DialogResult = true; };
        if (chooser.ShowDialog() != true || list.SelectedItem is not ListBoxItem { Tag: JsonElement selected }) return;
        foreach (var id in selected.GetProperty("host_ids").EnumerateArray())
        {
            var host = hosts.FirstOrDefault(h => h.Id == id.GetString());
            if (host != null) await ConnectHostAsync(host);
        }
    });
    private async void Settings_Click(object sender, RoutedEventArgs args) => await GuardAsync(async () =>
    {
        var settings = await api!.GetAsync("settings");
        var font = settings.TryGetProperty("font_size", out var f) ? f.GetInt32() : 13;
        var scrollback = settings.TryGetProperty("scrollback", out var s) ? s.GetInt32() : 1000;
        var dialog = new FormDialog(this, "Terminal settings", [new("font", "Font size (8 to 32)", font.ToString()), new("scrollback", "Scrollback lines (100 to 100000)", scrollback.ToString())]);
        if (dialog.ShowDialog() != true) return;
        if (!int.TryParse(dialog.Values["font"], out font) || !int.TryParse(dialog.Values["scrollback"], out scrollback)) throw new ArgumentException("Settings must be whole numbers.");
        await api.PostAsync("settings", new { font_size = font, scrollback });
        foreach (var terminal in terminals) await terminal.ApplySettingsAsync();
        Status.Text = "Terminal settings saved.";
    });
    private async void Backup_Click(object sender, RoutedEventArgs args) => await GuardAsync(async () =>
    {
        var result = await api!.PostAsync("backup", new { });
        MessageBox.Show(this, "Saved a backup of hosts, preferences and workspaces to:\n" + result.GetProperty("path").GetString(), "Backup created");
    });
}
