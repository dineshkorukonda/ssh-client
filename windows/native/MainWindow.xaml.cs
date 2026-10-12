using System.Windows.Media.Animation;
using System.Collections.ObjectModel;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace SSHClient.Windows;

public partial class MainWindow : Window
{
    private readonly DesktopClient? api;
    private List<Host> hosts = new();
    private readonly ObservableCollection<KeyEntry> keys = new();
    private readonly List<TerminalView> terminals = new();
    private SftpPane? filePane;
    private readonly Dictionary<string, string> hostBySession = new();
    private readonly ObservableCollection<TerminalTabItem> openSessions = new();
    private bool favoritesOnly;
    private Host? editingHost;
    private string currentPage = "hosts";
    private string editorBaseline = "";
    private Func<Task>? retryOperation;
    private string diagnostics = "";
    private bool reducedMotion;
    private readonly bool isPreview;


    public MainWindow(DesktopClient? api, bool preview = false)
    {
        this.api = api;
        this.isPreview = preview;
        InitializeComponent();

        StateChanged += (_, _) =>
        {
            var icon = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
            if (MaximizeBtn != null) MaximizeBtn.Content = icon;

        };

        if (KeysList != null) KeysList.ItemsSource = keys;
        EditorIdentity.ItemsSource = keys;
        SftpSessionCombo.ItemsSource = openSessions;
        if (SidebarSessionsList != null) SidebarSessionsList.ItemsSource = openSessions;

        if (api != null)
        {
            Loaded += async (_, _) => await GuardAsync(InitializeAsync);
        }
        else if (preview)
        {
            hosts =
            [
                new Host { Name = "Production K8s Gateway", Address = "prod-k8s.internal", User = "ops", Favorite = true, Notes = "Primary Kubernetes edge cluster", Tags = ["production", "ubuntu", "k8s"] },
                new Host { Name = "Staging DB Primary", Address = "staging-db.internal", User = "postgres", Port = 5432, Favorite = true, Notes = "PostgreSQL 16 failover replica", Tags = ["staging", "debian", "database"] },
                new Host { Name = "Worker Node 04", Address = "10.0.12.44", User = "deploy", Tags = ["worker", "alpine"] },
                new Host { Name = "Legacy Telemetry Ingest", Address = "telemetry.infra", User = "admin", Tags = ["redhat", "metrics"] },
                new Host { Name = "Build & Release CI", Address = "ci-runner.internal", User = "runner", Tags = ["ci", "arch"] },
                new Host { Name = "Backup Storage Vault", Address = "vault-backup.internal", User = "root", Tags = ["backup", "debian"] }
            ];
            FilterHosts();
            UpdateDashboardMetrics();
            if (StatusText != null) StatusText.Text = "Ready. Select a host to connect.";
        }

        ShowPage("hosts");
        Closing += (_, e) => { if (EditorDirty() && MessageBox.Show(this, "Discard unsaved host changes and close?", "Unsaved changes", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) e.Cancel = true; };
        Closed += (_, _) =>
        {
            foreach (var view in terminals) view.Dispose();
            filePane?.Dispose();
            api?.Dispose();
        };
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        OmniBar.TextChanged += (_, _) =>
        {
            OmniHint.Visibility = string.IsNullOrWhiteSpace(OmniBar.Text) ? Visibility.Visible : Visibility.Collapsed;
            if (OmniBar.IsKeyboardFocusWithin) UpdatePalette();
        };
    }

    // -------------------------------------------------------------
    // Automated Preview Helpers for Smoke Tests
    // -------------------------------------------------------------
    internal void ShowAuthForPreview()
    {
        ShowPage("settings");
    }

    internal void ShowDashboardForPreview()
    {
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("dashboard");
    }

    internal void ShowHostsForPreview()
    {
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("hosts");
        HostListGrid.Visibility = Visibility.Visible;
        HostEditorGrid.Visibility = Visibility.Collapsed;
    }

    internal void ShowAddHostForPreview()
    {
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("hosts");
        OpenHostEditor(new Host { Port = 22, User = "root", DefaultAuthMethod = "key" });
    }

    internal void ShowSftpForPreview()
    {
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("sftp");
    }

    internal void ShowKeysForPreview()
    {
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("keys");
    }

    internal void SwitchThemeForPreview(AppTheme theme)
    {
        ThemeManager.ApplyTheme(theme);
        if (ThemeToggleBtn != null)
            ThemeToggleBtn.Content = "Theme";
        HighlightNavButton(currentPage);
    }

    // -------------------------------------------------------------
    // Page Navigation
    // -------------------------------------------------------------
    private void AnimatePageIn(UIElement page)
    {
        if (isPreview || reducedMotion || !SystemParameters.ClientAreaAnimation)
        {
            page.Opacity = 1;
            page.RenderTransform = null;
            return;
        }

        page.Opacity = 0;
        var translate = new TranslateTransform(0, 8);
        page.RenderTransform = translate;

        var fadeAnim = new DoubleAnimation
        {
            From = 0,
            To = 1,
            Duration = TimeSpan.FromMilliseconds(160),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };

        var slideAnim = new DoubleAnimation
        {
            From = 8,
            To = 0,
            Duration = TimeSpan.FromMilliseconds(160),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };

        page.BeginAnimation(UIElement.OpacityProperty, fadeAnim);
        translate.BeginAnimation(TranslateTransform.YProperty, slideAnim);
    }

    private void ShowPage(string page)
    {
        if (page != "hosts" && EditorDirty() && !ConfirmDiscard()) return;
        PalettePopup.IsOpen = false;
        currentPage = page;
        DashboardPage.Visibility = page == "dashboard" ? Visibility.Visible : Visibility.Collapsed;
        HostsPage.Visibility = page == "hosts" ? Visibility.Visible : Visibility.Collapsed;
        SftpPage.Visibility = page == "sftp" ? Visibility.Visible : Visibility.Collapsed;
        KeysPage.Visibility = page == "keys" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPage.Visibility = page == "settings" ? Visibility.Visible : Visibility.Collapsed;
        SessionTerminalWorkspace.Visibility = page == "session" ? Visibility.Visible : Visibility.Collapsed;

        UIElement? target = page switch
        {
            "dashboard" => DashboardPage,
            "hosts" => HostsPage,
            "sftp" => SftpPage,
            "keys" => KeysPage,
            "settings" => SettingsPage,
            "session" => SessionTerminalWorkspace,
            _ => null
        };
        if (target != null)
        {
            AnimatePageIn(target);
        }

        // Visual feedback on nav buttons
        HighlightNavButton(page);
    }

    private void HighlightNavButton(string active)
    {
        ApplyNavState(NavDashboard, active == "dashboard");
        ApplyNavState(NavHosts, active == "hosts");
        ApplyNavState(NavSftp, active == "sftp");
        ApplyNavState(NavKeys, active == "keys");
        ApplyNavState(NavSettings, active == "settings");
    }

    private void ApplyNavState(Button? btn, bool isActive)
    {
        if (btn == null) return;
        if (isActive)
        {
            btn.Background = (Brush)Application.Current.Resources["NavActiveBg"];
            btn.BorderBrush = (Brush)Application.Current.Resources["NavActiveBorder"];
            btn.Foreground = (Brush)Application.Current.Resources["NavActiveFg"];
        }
        else
        {
            btn.Background = Brushes.Transparent;
            btn.BorderBrush = Brushes.Transparent;
            btn.Foreground = (Brush)Application.Current.Resources["Muted"];
        }
    }

    private void NavDashboard_Click(object sender, RoutedEventArgs e) => ShowPage("dashboard");
    private void NavHosts_Click(object sender, RoutedEventArgs e) => ShowPage("hosts");
    private void NavSftp_Click(object sender, RoutedEventArgs e) => ShowPage("sftp");
    private void NavKeys_Click(object sender, RoutedEventArgs e) => ShowPage("keys");
    private void NavSettings_Click(object sender, RoutedEventArgs e) => ShowPage("settings");

    // -------------------------------------------------------------
    // Authentication / Master Keyring Unlock
    // -------------------------------------------------------------
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool LockWorkStation();

    private void LockVault_Click(object sender, RoutedEventArgs e)
    {
        if (!LockWorkStation()) StatusText.Text = "Windows could not lock this desktop. Use Windows+L.";
    }

    private void EditorAuth_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (EditorKeyPath == null) return;
        var key = (EditorAuth.SelectedItem as ComboBoxItem)?.Tag?.ToString() == "key";
        EditorKeyPath.IsEnabled = key;
        if (EditorIdentity != null) EditorIdentity.IsEnabled = key;
    }

    private void EditorIdentity_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (EditorIdentity.SelectedItem is KeyEntry key && key.PrivateKeyPath != null)
            EditorKeyPath.Text = key.PrivateKeyPath;
    }

    // -------------------------------------------------------------
    // Theme Management (Dark Terminal Edition / Light Bauhaus)
    // -------------------------------------------------------------
    private async void ThemeToggle_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => SetThemeAsync(ThemeManager.CurrentTheme == AppTheme.Dark ? AppTheme.Light : AppTheme.Dark));
    private async void SetDarkTheme_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => SetThemeAsync(AppTheme.Dark));
    private async void SetLightTheme_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => SetThemeAsync(AppTheme.Light));

    // -------------------------------------------------------------
    // Dashboard Logic & Metrics
    // -------------------------------------------------------------
    private void UpdateDashboardMetrics()
    {
        if (MetricHostsCount != null) MetricHostsCount.Text = hosts.Count.ToString();
        if (SidebarHostBadge != null) SidebarHostBadge.Text = hosts.Count.ToString();
        if (MetricKeysCount != null) MetricKeysCount.Text = keys.Count.ToString();
        if (SidebarKeysBadge != null) SidebarKeysBadge.Text = keys.Count.ToString();
        if (MetricActiveSessions != null) MetricActiveSessions.Text = openSessions.Count(s => s.State == "Connected").ToString();
        if (ActiveTerminalsSection != null) ActiveTerminalsSection.Visibility = openSessions.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        if (MetricHostsBreakdown != null) MetricHostsBreakdown.Text = "Host labels and tags";
        if (isPreview) { AppVersionLabel.Text = "preview"; BackendReadyText.Text = "Preview"; }

        if (DashboardHostsList != null)
            DashboardHostsList.ItemsSource = hosts.OrderByDescending(h => h.LastConnectedAt).ThenByDescending(h => h.Favorite).Take(6).ToArray();
    }

    private async void RefreshDashboard_Click(object sender, RoutedEventArgs e)
    {
        await RefreshAsync();
        UpdateDashboardMetrics();
    }

    private void DashboardNewHost_Click(object sender, RoutedEventArgs e)
    {
        ShowPage("hosts");
        NewHost_Click(sender, e);
    }

    private async void QuickConnect_Click(object sender, RoutedEventArgs e)
    {
        var input = QuickConnectInput.Text.Trim();
        if (!string.IsNullOrEmpty(input))
            await GuardAsync(() => HandleConnectQueryAsync(input));
    }

    private void DashboardHosts_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Optional quick selection
    }

    private async void DashboardConnect_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: Host host })
            await GuardAsync(() => ConnectHostAsync(host));
    }

    // -------------------------------------------------------------
    // Hosts Inventory & Filter
    // -------------------------------------------------------------
    private void FilterAll_Click(object sender, RoutedEventArgs e)
    {
        favoritesOnly = false;
        FilterHosts();
    }

    private void FilterFav_Click(object sender, RoutedEventArgs e)
    {
        favoritesOnly = true;
        FilterHosts();
    }

    private void Search_Changed(object sender, TextChangedEventArgs e) => FilterHosts();

    private void FilterHosts()
    {
        if (Hosts == null || Search == null) return;
        var selectedId = (Hosts.SelectedItem as Host)?.Id;
        var query = Search.Text.Trim();

        var filtered = hosts.Where(h =>
            (!favoritesOnly || h.Favorite) &&
            (string.IsNullOrEmpty(query) ||
             h.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             h.Address.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             string.Join(" ", h.Tags).Contains(query, StringComparison.OrdinalIgnoreCase))
        );
        var sort = (HostSort?.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        var ordered = sort == "recent" ? filtered.OrderByDescending(h => h.LastConnectedAt).ThenBy(h => h.Name) : sort == "favorite" ? filtered.OrderByDescending(h => h.Favorite).ThenBy(h => h.Name) : filtered.OrderBy(h => h.Name);
        var displayed = ordered.ToArray();

        Hosts.ItemsSource = displayed;
        Hosts.SelectedItem = displayed.FirstOrDefault(h => h.Id == selectedId) ?? displayed.FirstOrDefault();

        if (HostsEmpty != null) {
            HostsEmpty.Visibility = displayed.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            HostsEmpty.Text = hosts.Count == 0 ? "No saved hosts yet. Add a host or import your SSH config to get started." : "No hosts match these filters. Clear search or choose All.";
        }
        if (HostCount != null) HostCount.Text = $"{displayed.Length} configured hosts";
        if (SearchHint != null) SearchHint.Visibility = string.IsNullOrEmpty(query) ? Visibility.Visible : Visibility.Collapsed;

        UpdateInspectorDetails();
        UpdateDashboardMetrics();
    }

    private void Hosts_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateInspectorDetails();

    private void UpdateInspectorDetails()
    {
        if (DetailTitle == null) return;
        var host = Hosts.SelectedItem as Host;
        if (host == null)
        {
            DetailTitle.Text = "Select a host";
            DetailSubtitle.Text = "Choose a server to inspect configuration";
            DetailAddress.Text = "-";
            DetailPort.Text = "22";
            DetailUser.Text = "-";
            DetailAuth.Text = "Keypair";
            DetailConnectBtn.IsEnabled = DetailEditBtn.IsEnabled = DetailFavBtn.IsEnabled = DetailRemoveBtn.IsEnabled = false;
            return;
        }

        DetailTitle.Text = host.Name;
        DetailSubtitle.Text = string.IsNullOrWhiteSpace(host.Notes) ? "Saved host configuration" : host.Notes;
        DetailAddress.Text = host.Address;
        DetailPort.Text = host.Port.ToString();
        DetailUser.Text = string.IsNullOrWhiteSpace(host.User) ? "root" : host.User;
        DetailAuth.Text = host.DefaultAuthMethod == "password" ? "Password" : "SSH Keypair";
        DetailFavBtn.Content = host.Favorite ? "Remove favorite" : "Add favorite";
        DetailConnectBtn.IsEnabled = DetailEditBtn.IsEnabled = DetailFavBtn.IsEnabled = DetailRemoveBtn.IsEnabled = true;
    }

    private async void HostItemConnect_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: Host host })
            await GuardAsync(() => ConnectHostAsync(host));
    }

    private async void DetailConnect_Click(object sender, RoutedEventArgs e)
    {
        if (Hosts.SelectedItem is Host host)
            await GuardAsync(() => ConnectHostAsync(host));
    }

    private void DetailEdit_Click(object sender, RoutedEventArgs e)
    {
        if (Hosts.SelectedItem is Host host)
            OpenHostEditor(host.Copy());
    }

    private async void DetailFavorite_Click(object sender, RoutedEventArgs e)
    {
        if (Hosts.SelectedItem is Host host)
        {
            await GuardAsync(async () =>
            {
                var copy = host.Copy();
                copy.Favorite = !copy.Favorite;
                if (api != null) await api.PostAsync("hosts", copy);
                else host.Favorite = copy.Favorite;
                await RefreshAsync();
            });
        }
    }

    private async void DetailRemove_Click(object sender, RoutedEventArgs e)
    {
        if (Hosts.SelectedItem is not Host host) return;
        if (MessageBox.Show(this, $"Remove endpoint {host.Name}?", "Confirm Deletion", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            return;

        await GuardAsync(async () =>
        {
            if (api != null) await api.RequestAsync(HttpMethod.Delete, "hosts/" + Uri.EscapeDataString(host.Id));
            else hosts.Remove(host);
            await RefreshAsync();
        });
    }

    // -------------------------------------------------------------
    // Full-Page Add / Edit Host
    // -------------------------------------------------------------
    private void NewHost_Click(object sender, RoutedEventArgs e) =>
        OpenHostEditor(new Host { Port = 22, User = "root", DefaultAuthMethod = "key" });

    private void OpenHostEditor(Host host)
    {
        if (EditorDirty() && !ConfirmDiscard()) return;
        editingHost = host;
        EditorName.Text = host.Name;
        EditorHost.Text = host.Address;
        EditorPort.Text = host.Port.ToString();
        EditorUser.Text = string.IsNullOrWhiteSpace(host.User) ? "root" : host.User;
        EditorKeyPath.Text = host.IdentityFile ?? "";
        EditorAuth.SelectedItem = EditorAuth.Items.Cast<ComboBoxItem>().FirstOrDefault(item => item.Tag.ToString() == host.DefaultAuthMethod) ?? EditorAuth.Items[0];
        EditorIdentity.SelectedItem = keys.FirstOrDefault(key => key.PrivateKeyPath == host.IdentityFile);
        EditorJump.Text = host.ProxyJump ?? "";
        EditorTags.Text = string.Join(", ", host.Tags);
        EditorNotes.Text = host.Notes;
        EditorHeader.Text = string.IsNullOrWhiteSpace(host.Name) ? "Register New Host" : $"Edit Host: {host.Name}";

        HostListGrid.Visibility = Visibility.Collapsed;
        HostEditorGrid.Visibility = Visibility.Visible;
        EditorError.Text = "";
        editorBaseline = EditorSnapshot();
        EditorHost.Focus();
    }

    private void EditorCancel_Click(object sender, RoutedEventArgs e)
    {
        if (!ConfirmDiscard()) return;
        HostEditorGrid.Visibility = Visibility.Collapsed;
        HostListGrid.Visibility = Visibility.Visible;
        editingHost = null;
    }

    private void EditorBrowseKey_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Select SSH Private Key",
            Filter = "SSH Key Files (*.pem;id_*;*.key)|*.pem;id_*;*.key|All Files (*.*)|*.*"
        };
        if (picker.ShowDialog(this) == true)
            EditorKeyPath.Text = picker.FileName;
    }

    private async void EditorSave_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => SaveEditorAsync(false));
    private async void EditorSaveAndConnect_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => SaveEditorAsync(true));
    private async Task SaveEditorAsync(bool connect)
    {
        if (editingHost == null) return;
        var address = EditorHost.Text.Trim();
        var user = EditorUser.Text.Trim();
        if (string.IsNullOrWhiteSpace(address) || string.IsNullOrWhiteSpace(user))
        {
            EditorError.Text = "Server address and username are required.";
            if (string.IsNullOrWhiteSpace(address)) EditorHost.Focus(); else EditorUser.Focus();
            return;
        }

        if (!int.TryParse(EditorPort.Text.Trim(), out var port) || port is < 1 or > 65535)
        {
            EditorError.Text = "SSH port must be between 1 and 65535.";
            EditorPort.Focus();
            return;
        }

        editingHost.Name = string.IsNullOrWhiteSpace(EditorName.Text) ? address : EditorName.Text.Trim();
        editingHost.Address = address;
        editingHost.Port = port;
        editingHost.User = user;
        editingHost.DefaultAuthMethod = ((ComboBoxItem)EditorAuth.SelectedItem).Tag.ToString()!;
        editingHost.Extra ??= [];
        editingHost.Extra["auth_order"] = JsonSerializer.SerializeToElement(editingHost.DefaultAuthMethod == "keyboard_interactive" ? new[] { "keyboard_interactive" } : new[] { editingHost.DefaultAuthMethod, "keyboard_interactive" });
        editingHost.IdentityFile = string.IsNullOrWhiteSpace(EditorKeyPath.Text) ? null : EditorKeyPath.Text.Trim();
        editingHost.ProxyJump = string.IsNullOrWhiteSpace(EditorJump.Text) ? null : EditorJump.Text.Trim();
        editingHost.Tags = EditorTags.Text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        editingHost.Notes = EditorNotes.Text;

        {
            if (api != null)
            {
                await api.PostAsync("hosts", editingHost);
                await RefreshAsync();
            }
            else
            {
                var idx = hosts.FindIndex(h => h.Id == editingHost.Id);
                if (idx >= 0) hosts[idx] = editingHost;
                else hosts.Add(editingHost);
                FilterHosts();
            }

            HostEditorGrid.Visibility = Visibility.Collapsed;
            HostListGrid.Visibility = Visibility.Visible;
            if (StatusText != null) StatusText.Text = $"Host {editingHost.Name} saved successfully.";
            var saved = editingHost; editingHost = null; editorBaseline = "";
            if (connect) await ConnectHostAsync(saved);
        }
    }

    // -------------------------------------------------------------
    // SFTP Page Logic
    // -------------------------------------------------------------
    private void SftpSessionCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        filePane?.Dispose(); filePane = null;
        if (api != null && SftpSessionCombo.SelectedItem is TerminalTabItem item && item.State == "Connected")
            SftpContent.Content = filePane = new SftpPane(api, item.SessionId, this);
        else SftpContent.Content = new TextBlock { Text = "Connect this session before browsing remote files.", Margin = new Thickness(16) };
    }

    // -------------------------------------------------------------
    // Key Vault Page Logic
    // -------------------------------------------------------------
    private async void RegisterKey_Click(object sender, RoutedEventArgs e)
    {
        if (api == null) return;
        var picker = new Microsoft.Win32.OpenFileDialog { Title = "Import SSH identity", Filter = "All SSH key files|*.*" };
        if (picker.ShowDialog(this) != true) return;
        var dialog = new FormDialog(this, "Import SSH identity", [new("name", "Name", Path.GetFileName(picker.FileName)), new("passphrase", "Passphrase (only for an encrypted private key)", Secret: true)], "Import", "The file is inspected locally. Private key contents and passphrases are never saved in the app database.");
        if (dialog.ShowDialog() != true) return;
        await GuardAsync(async () => {
            await api.PostAsync("keys", new { path = picker.FileName, name = dialog.Values["name"], passphrase = dialog.Values["passphrase"] });
            await RefreshKeysAsync();
            StatusText.Text = "SSH identity imported.";
        });
    }

    private async void GenerateKeypair_Click(object sender, RoutedEventArgs e)
    {
        if (api == null) return;
        var dialog = new FormDialog(this, "Generate SSH keypair", [new("algorithm", "Algorithm", "ED25519", Options: ["ED25519", "RSA-4096"]), new("name", "Name", "Personal identity")], "Choose destination", "Creates an unencrypted private-key file and its .pub companion. Protect these files with Windows file permissions. Existing keys are never overwritten.");
        if (dialog.ShowDialog() != true) return;
        var picker = new Microsoft.Win32.SaveFileDialog { Title = "New private-key destination", FileName = "id_ed25519", OverwritePrompt = true };
        if (picker.ShowDialog(this) != true) return;
        await GuardAsync(async () => {
            await api.PostAsync("keys/generate", new { path = picker.FileName, algorithm = dialog.Values["algorithm"], name = dialog.Values["name"] });
            await RefreshKeysAsync();
            StatusText.Text = "Keypair generated. Private key stays in the selected file.";
        });
    }

    private void CopyPubKey_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: KeyEntry key } && !string.IsNullOrEmpty(key.PublicKey))
        { Clipboard.SetText(key.PublicKey); StatusText.Text = "Public key copied."; }
    }

    private async void RemoveKey_Click(object sender, RoutedEventArgs e)
    {
        if (api == null || sender is not Button { Tag: KeyEntry key }) return;
        if (MessageBox.Show(this, "Remove this identity from the app? The key files remain on disk.", "Remove identity", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        await GuardAsync(async () => { await api.RequestAsync(HttpMethod.Delete, "keys/" + key.Id); await RefreshKeysAsync(); });
    }

    private async Task RefreshKeysAsync()
    {
        if (api == null) return;
        var loaded = (await api.GetAsync("keys")).Deserialize<List<KeyEntry>>(DesktopClient.Json) ?? [];
        keys.Clear();
        foreach (var key in loaded) keys.Add(key);
        EditorIdentity.ItemsSource = keys.Where(key => key.PrivateKeyPath != null).ToArray();
        UpdateDashboardMetrics();
    }

    // -------------------------------------------------------------
    // Omnibar Quick Connect
    // -------------------------------------------------------------
    private async void OmniBar_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Down || e.Key == Key.Up) { PaletteList.SelectedIndex = Math.Clamp(PaletteList.SelectedIndex + (e.Key == Key.Down ? 1 : -1), 0, Math.Max(0, PaletteList.Items.Count - 1)); e.Handled = true; return; }
        if (e.Key == Key.Escape) { PalettePopup.IsOpen = false; e.Handled = true; return; }
        if (e.Key != Key.Enter) return;
        if (PalettePopup.IsOpen && PaletteList.SelectedItem is PaletteEntry) { await RunPaletteAsync(); e.Handled = true; return; }
        var query = OmniBar.Text.Trim();
        if (string.IsNullOrEmpty(query)) return;
        await GuardAsync(() => HandleConnectQueryAsync(query));
    }

    private async Task HandleConnectQueryAsync(string query)
    {
        var existing = hosts.FirstOrDefault(h =>
            string.Equals(h.Name, query, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(h.Address, query, StringComparison.OrdinalIgnoreCase));

        if (existing != null)
        {
            await GuardAsync(() => ConnectHostAsync(existing));
            return;
        }

        var adHoc = QuickConnect.Parse(query);
        await GuardAsync(() => ConnectHostAsync(adHoc));
    }

    // -------------------------------------------------------------
    // SSH Session Connections & Tab Management
    // -------------------------------------------------------------
    private async Task ConnectHostAsync(Host host, TerminalTabItem? parent = null, Grid? splitGrid = null)
    {
        var fields = new List<Field> { new("user", "Username", host.User) };
        if (host.DefaultAuthMethod == "password") fields.Add(new("password", "Password", Secret: true));
        else if (host.DefaultAuthMethod == "key" && !string.IsNullOrWhiteSpace(host.IdentityFile))
        {
            if (File.Exists(host.IdentityFile) && File.ReadAllText(host.IdentityFile).Contains("ENCRYPTED", StringComparison.OrdinalIgnoreCase))
                fields.Add(new("passphrase", "Private-key passphrase", Secret: true));
            else if (File.Exists(host.IdentityFile) && File.ReadAllText(host.IdentityFile).Contains("OPENSSH PRIVATE KEY", StringComparison.Ordinal))
                fields.Add(new("passphrase", "Key passphrase (leave empty for an unencrypted key)", Secret: true));
        }

        if (!string.IsNullOrWhiteSpace(host.ProxyJump))
        {
            fields.AddRange([
                new("jump_user", "Jump-host Username (optional)"),
                new("jump_password", "Jump-host Password (optional)", Secret: true),
                new("jump_identity_file", "Jump-host Private Key (optional)", File: true),
                new("jump_passphrase", "Jump-host Key Passphrase (optional)", Secret: true)
            ]);
        }

        var dialog = new FormDialog(this, "Authenticate Connection: " + host.Name, fields, "Connect", "Zero-persistence security: credentials stored in volatile memory only.");
        if (dialog.ShowDialog() != true) return;

        var values = dialog.Values;
        var attrs = ConnectionRequest.Build(host, values);

        if (api != null)
        {
            var result = await api.PostAsync("sessions", attrs);
            var sessionId = result.GetProperty("session_id").GetString()!;
            if (parent != null && splitGrid != null) AddSplitPane(parent, splitGrid, sessionId);
            else AddTerminalTab(host.Name, sessionId, host);
            hostBySession[sessionId] = host.Id;
        }
        else
        {
            var dummySessionId = "sess_" + Guid.NewGuid().ToString("n")[..8];
            AddTerminalTab(host.Name, dummySessionId, host);
        }
    }

    private void AddTerminalTab(string title, string id, Host? host = null)
    {
        var sessionItem = new TerminalTabItem { Title = title, SessionId = id, Host = host, State = api == null ? "Preview" : "Connecting" };
        sessionItem.PaneIds.Add(id);
        openSessions.Add(sessionItem);

        var tab = new TabItem { Tag = sessionItem };
        var headerPanel = new StackPanel { Orientation = Orientation.Horizontal };
        var liveDot = new Border
        {
            Width = 6,
            Height = 6,
            CornerRadius = new CornerRadius(3),
            Background = (Brush)Application.Current.Resources["Accent"],
            Margin = new Thickness(0, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        headerPanel.Children.Add(liveDot);
        headerPanel.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });

        var closeBtn = new Button
        {
            Content = "Close",
            ToolTip = "Close this terminal and disconnect its SSH sessions",
            Style = (Style)Application.Current.Resources["GhostButton"],
            Padding = new Thickness(6, 0, 6, 0),
            Margin = new Thickness(10, 0, 0, 0),
            FontSize = 10
        };
        headerPanel.Children.Add(closeBtn);
        tab.Header = headerPanel;

        // Session Toolbar + Terminal Grid
        var rootGrid = new Grid();
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var toolBar = new Border
        {
            Background = (Brush)Application.Current.Resources["Card"],
            BorderBrush = (Brush)Application.Current.Resources["Border"],
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(12, 6, 12, 6)
        };
        var toolDock = new DockPanel();

        var rightInfo = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(rightInfo, Dock.Right);
        rightInfo.Children.Add(new TextBlock
        {
            Text = host?.Description ?? title,
            FontFamily = (FontFamily)Application.Current.Resources["MonoFont"],
            Foreground = (Brush)Application.Current.Resources["MutedSubtle"],
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center
        });
        toolDock.Children.Add(rightInfo);
        ((TextBlock)rightInfo.Children[0]).SetResourceReference(TextBlock.ForegroundProperty, "Muted");

        var leftButtons = new StackPanel { Orientation = Orientation.Horizontal };
        var disconnBtn = new Button { Content = "Disconnect", Style = (Style)Application.Current.Resources["GhostButton"], Margin = new Thickness(0, 0, 6, 0) };
        var reconnBtn = new Button { Content = "Reconnect", Style = (Style)Application.Current.Resources["GhostButton"], Margin = new Thickness(0, 0, 6, 0) };
        var sftpBtn = new Button { Content = "Files (SFTP)", Style = (Style)Application.Current.Resources["GhostButton"], Margin = new Thickness(0, 0, 6, 0) };
        var splitBtn = new Button { Content = "Split right", Style = (Style)Application.Current.Resources["GhostButton"] };

        disconnBtn.Click += async (_, _) => await GuardAsync(() => SessionActionAsync(sessionItem, "disconnect"));
        reconnBtn.Click += async (_, _) => await GuardAsync(() => SessionActionAsync(sessionItem, "reconnect"));
        sftpBtn.Click += (_, _) => OpenFiles(sessionItem);
        leftButtons.Children.Add(disconnBtn);
        leftButtons.Children.Add(reconnBtn);
        leftButtons.Children.Add(sftpBtn);
        leftButtons.Children.Add(splitBtn);
        toolDock.Children.Add(leftButtons);
        toolBar.Child = toolDock;
        toolBar.SetResourceReference(Border.BackgroundProperty, "Card");
        toolBar.SetResourceReference(Border.BorderBrushProperty, "Border");
        Grid.SetRow(toolBar, 0);
        rootGrid.Children.Add(toolBar);

        var terminalGrid = new Grid();
        terminalGrid.ColumnDefinitions.Add(new ColumnDefinition());
        AddSessionView(sessionItem, terminalGrid, id, 0);
        splitBtn.Click += async (_, _) => {
            if (sessionItem.Host != null && api != null)
                await GuardAsync(() => ConnectHostAsync(sessionItem.Host, sessionItem, terminalGrid));
        };
        Grid.SetRow(terminalGrid, 1);
        rootGrid.Children.Add(terminalGrid);
        tab.Content = rootGrid;

        closeBtn.Click += async (_, _) => await GuardAsync(() => CloseSessionTabAsync(tab));

        SessionTabs.Items.Add(tab);
        SessionTabs.SelectedItem = tab;
        ShowPage("session");
        UpdateDashboardMetrics();
    }

    private void AddSessionView(TerminalTabItem item, Grid grid, string id, int column)
    {
        if (api == null)
        {
            grid.Children.Add(new TextBlock { Text = "Terminal preview. Connect a host to start a real session.", Margin = new Thickness(20) });
            return;
        }
        var pane = new Grid(); pane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); pane.RowDefinitions.Add(new RowDefinition());
        var paneStatus = new TextBlock { Text = item.Host?.Description + " / Connecting", Margin = new Thickness(10, 5, 10, 5), TextTrimming = TextTrimming.CharacterEllipsis };
        paneStatus.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); pane.Children.Add(paneStatus);
        var view = new TerminalView(api, id, this, message => {
            if (SessionTabs.SelectedItem is TabItem { Tag: TerminalTabItem selected } && selected == item) StatusText.Text = message;
        }, state => {
            paneStatus.Text = item.Host?.Description + " / " + state;
            if (id == item.SessionId) { item.State = state; if (state == "Connected") _ = GuardAsync(() => RecordConnectionAsync(item)); }
            UpdateDashboardMetrics();
        });
        Grid.SetRow(view, 1); pane.Children.Add(view);
        Grid.SetColumn(pane, column);
        grid.Children.Add(pane);
        item.Views.Add(view);
        terminals.Add(view);
    }

    private void AddSplitPane(TerminalTabItem item, Grid grid, string id)
    {
        var column = grid.ColumnDefinitions.Count;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(5) });
        var splitter = new GridSplitter { Width = 5, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch, ResizeDirection = GridResizeDirection.Columns, ResizeBehavior = GridResizeBehavior.PreviousAndNext };
        Grid.SetColumn(splitter, column);
        grid.Children.Add(splitter);
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        item.PaneIds.Add(id);
        AddSessionView(item, grid, id, column + 1);
        ShowPage("session");
    }

    private async Task SessionActionAsync(TerminalTabItem item, string action)
    {
        if (api == null) return;
        foreach (var id in item.PaneIds.ToArray()) await api.PostAsync($"sessions/{id}/{action}", new { });
    }

    private void OpenFiles(TerminalTabItem item)
    {
        if (api != null && item.State == "Connected") { ShowPage("sftp"); SftpSessionCombo.SelectedItem = item; if (filePane == null) SftpSessionCombo_SelectionChanged(this, new SelectionChangedEventArgs(System.Windows.Controls.Primitives.Selector.SelectionChangedEvent, new object[0], new object[0])); }
        else StatusText.Text = "Connect this session before browsing remote files.";
    }

    private async Task CloseSessionTabAsync(TabItem tab)
    {
        if (tab.Tag is not TerminalTabItem item || item.Closing) return;
        item.Closing = true;
        try
        {
            foreach (var id in item.PaneIds.ToArray())
            {
                if (api != null) await api.RequestAsync(HttpMethod.Delete, "sessions/" + id);
                item.PaneIds.Remove(id);
                var view = item.Views.FirstOrDefault(v => v.SessionId == id);
                if (view != null) { view.Dispose(); terminals.Remove(view); item.Views.Remove(view); }
            }
            if (SftpSessionCombo.SelectedItem == item) { filePane?.Dispose(); filePane = null; SftpSessionCombo.SelectedItem = null; }
            hostBySession.Remove(item.SessionId);
            SessionTabs.Items.Remove(tab);
            openSessions.Remove(item);
            UpdateDashboardMetrics();
            if (SessionTabs.Items.Count == 0) ShowPage("hosts");
        }
        finally { item.Closing = false; }
    }

    internal TerminalView OpenSessionForSmoke(Host host, string id)
    {
        AddTerminalTab(host.Name, id, host);
        return ((TerminalTabItem)((TabItem)SessionTabs.SelectedItem).Tag).Views.Single();
    }

    internal async Task VerifySessionLifecycleForSmokeAsync(Host host, string id)
    {
        if (api == null) throw new InvalidOperationException("Smoke requires a backend.");
        var first = SessionTabs.Items.Cast<TabItem>().Single(tab => ((TerminalTabItem)tab.Tag).SessionId == id);
        var firstItem = (TerminalTabItem)first.Tag;
        var duplicateId = (await api.PostAsync("sessions", host)).GetProperty("session_id").GetString()!;
        var duplicateView = OpenSessionForSmoke(host, duplicateId);
        await duplicateView.Ready.WaitAsync(TimeSpan.FromSeconds(30));
        SidebarSessionsList.SelectedItem = firstItem;
        if (SessionTabs.SelectedItem != first) throw new IOException("Same-name sessions selected the wrong tab.");
        var duplicate = SessionTabs.Items.Cast<TabItem>().Single(tab => ((TerminalTabItem)tab.Tag).SessionId == duplicateId);
        await CloseSessionTabAsync(duplicate);
        if (!duplicateView.IsDisposed || firstItem.Views.Single().IsDisposed) throw new IOException("Tab close disposed the wrong terminal.");
        try { await api.GetAsync("sessions/" + duplicateId); throw new InvalidOperationException("Closed tab left its backend session alive."); }
        catch (IOException) { }
        await SessionActionAsync(firstItem, "disconnect");
        await WaitSessionStateForSmokeAsync(id, "disconnected");
        await SessionActionAsync(firstItem, "reconnect");
        await WaitSessionStateForSmokeAsync(id, "connected");
    }

    private async Task WaitSessionStateForSmokeAsync(string id, string expected)
    {
        for (var i = 0; i < 100; i++)
        {
            var snapshot = await api!.GetAsync("sessions/" + id);
            if (snapshot.GetProperty("status").GetString() == expected) return;
            await Task.Delay(100);
        }
        throw new IOException("Session did not reach " + expected);
    }

    internal async Task VerifyFilesForSmokeAsync(string id, string localFile)
    {
        var item = openSessions.Single(item => item.SessionId == id);
        item.State = "Connected";
        OpenFiles(item);
        if (filePane == null) throw new IOException("Files toolbar did not open the integrated browser.");
        await filePane.VerifyFilesJourneyForSmokeAsync(localFile);
    }

    private void SidebarSessions_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SidebarSessionsList.SelectedItem is TerminalTabItem item)
        {
            foreach (TabItem tab in SessionTabs.Items)
            {
                if (tab.Tag is TerminalTabItem session && session.SessionId == item.SessionId)
                {
                    SessionTabs.SelectedItem = tab;
                    ShowPage("session");
                    break;
                }
            }
        }
    }

    private void SessionTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (e.Source != SessionTabs) return;
        if (SessionTabs.SelectedItem is TabItem { Tag: TerminalTabItem item })
        { SidebarSessionsList.SelectedItem = item; StatusText.Text = item.Summary.Replace("\n", " / "); }
    }

    // -------------------------------------------------------------
    // System & Daemon Communication
    // -------------------------------------------------------------
    private async Task InitializeAsync()
    {
        await RefreshDiagnosticsAsync();
        await RefreshAsync();
        await RefreshKeysAsync();
        await LoadPreferencesAsync();
        await RefreshWorkspacesAsync();
        UpdateDashboardMetrics();
    }

    private async Task RefreshAsync()
    {
        if (api == null) return;
        var response = await api.GetAsync("hosts");
        hosts = response.Deserialize<List<Host>>(DesktopClient.Json) ?? new();
        FilterHosts();
        UpdateDashboardMetrics();
    }

    private async Task GuardAsync(Func<Task> operation)
    {
        try { await operation(); }
        catch (Exception ex)
        {
            retryOperation = operation; diagnostics = ex.ToString();
            RecoveryMessage.Text = "The operation could not finish. " + ex.Message; RecoveryPanel.Visibility = Visibility.Visible;
            if (StatusText != null) StatusText.Text = ex.Message;

        }
    }

    // -------------------------------------------------------------
    // Titlebar Actions
    // -------------------------------------------------------------
    private void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void Maximize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
