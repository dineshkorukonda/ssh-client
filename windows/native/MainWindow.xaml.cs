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
    private bool favoritesOnly;
    public MainWindow(DesktopClient? api, bool preview = false)
    {
        this.api = api; InitializeComponent();
        if (api != null) Loaded += async (_, _) => await GuardAsync(InitializeAsync);
        else if (preview)
        {
            hosts = [new Host { Name = "Production EU", Address = "prod-eu.example.com", User = "deploy", Favorite = true, Notes = "Primary application server", Tags = ["production"] }, new Host { Name = "Staging", Address = "staging.example.com", User = "deploy" }, new Host { Name = "Development", Address = "192.168.1.20", User = "ubuntu" }, new Host { Name = "Database", Address = "db.internal", User = "admin", Favorite = true }, new Host { Name = "Build runner", Address = "ci.internal", User = "runner" }, new Host { Name = "Gateway", Address = "gateway.example.com", User = "ops" }];
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
        var selected = (Hosts.SelectedItem as Host)?.Id;
        var query = Search.Text;
        var filtered = hosts.Where(host => (!favoritesOnly || host.Favorite) && (host.Name + " " + host.Description + " " + string.Join(" ", host.Tags)).Contains(query, StringComparison.OrdinalIgnoreCase)).OrderBy(host => host.Name).ToArray();
        Hosts.ItemsSource = filtered;
        Hosts.SelectedItem = filtered.FirstOrDefault(host => host.Id == selected) ?? filtered.FirstOrDefault();
        if (Empty != null) Empty.Visibility = filtered.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (SearchHint != null) SearchHint.Visibility = query.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (HostCount != null) HostCount.Text = filtered.Length == 1 ? "1 saved host" : $"{filtered.Length} saved hosts";
        if (EmptyTitle != null) EmptyTitle.Text = hosts.Count == 0 ? "Add your first host" : "No matching hosts";
        if (EmptyDescription != null) EmptyDescription.Text = hosts.Count == 0 ? "Open a terminal and transfer files." : favoritesOnly && query.Length == 0 ? "Add a saved host to favorites." : "Try another name, address or tag.";
        UpdateDetails();
    }
    private void UpdateDetails()
    {
        if (DetailName == null) return;
        var host = Hosts.SelectedItem as Host;
        DetailName.Text = host?.Name ?? "Select a host"; DetailAddress.Text = host?.Address ?? "Add a host to get started.";
        DetailConnection.Text = host == null ? "SSH" : $"{host.User} / port {host.Port}";
        DetailAuth.Text = host?.DefaultAuthMethod == "password" ? "Password" : "Private key";
        DetailNotes.Text = string.IsNullOrWhiteSpace(host?.Notes) ? "No notes" : host.Notes;
        FavoriteButton.Content = host?.Favorite == true ? "Remove from favorites" : "Add to favorites";
        FavoriteButton.IsEnabled = host != null;
        DetailConnect.IsEnabled = DetailEdit.IsEnabled = DetailRemove.IsEnabled = host != null;
    }
    private void Host_Changed(object sender, SelectionChangedEventArgs args) => UpdateDetails();
    private void Library_Click(object sender, RoutedEventArgs args) { favoritesOnly = false; LibraryTitle.Text = "Hosts"; Sessions.SelectedItem = LibraryTab; FilterHosts(); UpdateNavigation(); }
    private void Favorites_Click(object sender, RoutedEventArgs args) { favoritesOnly = true; LibraryTitle.Text = "Favorites"; Sessions.SelectedItem = LibraryTab; FilterHosts(); UpdateNavigation(); }
    private void SessionTab_Changed(object sender, SelectionChangedEventArgs args) { if (args.Source == Sessions) UpdateNavigation(); }
    private void UpdateNavigation()
    {
        if (HostsNav == null || FavoritesNav == null || SessionLinks == null) return;
        var library = Sessions.SelectedItem == LibraryTab;
        var selected = (System.Windows.Media.Brush)Application.Current.Resources["Card"];
        HostsNav.Background = library && !favoritesOnly ? selected : System.Windows.Media.Brushes.Transparent;
        FavoritesNav.Background = library && favoritesOnly ? selected : System.Windows.Media.Brushes.Transparent;
        SessionLinks.SelectedItem = SessionLinks.Items.Cast<ListBoxItem>().FirstOrDefault(link => link.Tag == Sessions.SelectedItem);
    }
    private async void ToggleFavorite_Click(object sender, RoutedEventArgs args)
    {
        if (Hosts.SelectedItem is Host host) await GuardAsync(async () => { var updated = host.Copy(); updated.Favorite = !updated.Favorite; await api!.PostAsync("hosts", updated); await RefreshAsync(); });
    }
    private void SessionLink_Changed(object sender, SelectionChangedEventArgs args) { if (SessionLinks.SelectedItem is ListBoxItem { Tag: TabItem tab }) Sessions.SelectedItem = tab; }
    private void Minimize_Click(object sender, RoutedEventArgs args) => WindowState = WindowState.Minimized;
    private void Maximize_Click(object sender, RoutedEventArgs args) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void CloseWindow_Click(object sender, RoutedEventArgs args) => Close();
    private void Search_Changed(object sender, TextChangedEventArgs args) => FilterHosts();
    private async void Add_Click(object sender, RoutedEventArgs args) => await GuardAsync(() => EditHostAsync(new Host()));
    private async void Edit_Click(object sender, RoutedEventArgs args)
    {
        if (Hosts.SelectedItem is Host host) await GuardAsync(() => EditHostAsync(host.Copy()));
    }
    private async Task EditHostAsync(Host host)
    {
        var dialog = new FormDialog(this, "SSH host", [new("name", "Name", host.Name), new("host", "Server address", host.Address), new("port", "SSH port", host.Port.ToString()), new("user", "Username", host.User), new("auth", "Authentication", host.DefaultAuthMethod, Options: ["key", "password"]), new("identity", "Private key", host.IdentityFile ?? "", File: true), new("jump", "Jump host (optional)", host.ProxyJump ?? ""), new("tags", "Tags (comma-separated)", string.Join(", ", host.Tags)), new("notes", "Notes", host.Notes, Multiline: true)]);
        if (dialog.ShowDialog() != true) return;
        var values = dialog.Values;
        if (!int.TryParse(values["port"], out var port) || port is < 1 or > 65535) throw new ArgumentException("SSH port must be between 1 and 65535.");
        if (string.IsNullOrWhiteSpace(values["host"]) || string.IsNullOrWhiteSpace(values["user"])) throw new ArgumentException("Server address and username are required.");
        if (values["auth"] is not ("key" or "password")) throw new ArgumentException("Authentication must be key or password.");
        host.Name = string.IsNullOrWhiteSpace(values["name"]) ? values["host"].Trim() : values["name"].Trim();
        host.Address = values["host"].Trim(); host.Port = port; host.User = values["user"].Trim(); host.DefaultAuthMethod = values["auth"];
        host.IdentityFile = string.IsNullOrWhiteSpace(values["identity"]) ? null : values["identity"];
        host.ProxyJump = string.IsNullOrWhiteSpace(values["jump"]) ? null : values["jump"].Trim();
        host.Tags = values["tags"].Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries); host.Notes = values["notes"];
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
            var fields = new List<Field> { new("user", "Username", host.User) };
            fields.Add(host.DefaultAuthMethod == "password" ? new("password", "Password", Secret: true) : new("passphrase", "Key passphrase (if encrypted)", Secret: true));
            if (!string.IsNullOrWhiteSpace(host.ProxyJump)) fields.AddRange([new("jump_user", "Jump-host username (optional)"), new("jump_password", "Jump-host password (optional)", Secret: true), new("jump_identity", "Jump-host private key (optional)", File: true), new("jump_passphrase", "Jump-host key passphrase (optional)", Secret: true)]);
            var dialog = new FormDialog(this, "Connect to " + host.Name, fields, "Connect", host.Description + "\nCredentials are used for this session only.");
            if (dialog.ShowDialog() != true) return;
            var values = dialog.Values;
            var attrs = JsonSerializer.SerializeToElement(host, DesktopClient.Json).Deserialize<Dictionary<string, object?>>()!;
            attrs["user"] = values["user"];
            if (values.TryGetValue("password", out var password) && password != "") attrs["password"] = password;
            if (values.TryGetValue("passphrase", out var passphrase) && passphrase != "") attrs["passphrase"] = passphrase;
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
        var link = new ListBoxItem { Content = title, Tag = tab, Padding = new Thickness(10, 9, 10, 9), Margin = new Thickness(0, 0, 0, 6) }; SessionLinks.Items.Add(link);
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        var close = new Button { Content = "x", ToolTip = "Close session", Padding = new Thickness(6, 0, 6, 0), Margin = new Thickness(12, 0, 0, 0), FontSize = 12, Style = (Style)Application.Current.Resources["NavButton"] };
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
            SessionLinks.Items.Remove(link);
            hostBySession.Remove(id); await SaveWorkspaceAsync();
            if (Sessions.SelectedItem == null) Sessions.SelectedItem = LibraryTab;
        });
        Sessions.Items.Add(tab); Sessions.SelectedItem = tab;
    }
    private void Files_Click(object sender, RoutedEventArgs args)
    {
        var view = (Sessions.SelectedItem as TabItem)?.Tag as TerminalView ?? terminals.LastOrDefault();
        if (api != null && view != null) new FilesWindow(api, view.SessionId) { Owner = this }.Show();
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
