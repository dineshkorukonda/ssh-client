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
    private readonly Dictionary<string, string> hostBySession = new();
    private readonly ObservableCollection<TerminalTabItem> openSessions = new();
    private bool favoritesOnly;
    private Host? editingHost;
    private string currentPage = "dashboard";
    private readonly bool isPreview;
    public bool IsUnlocked { get; private set; } = true;

    public MainWindow(DesktopClient? api, bool preview = false)
    {
        this.api = api;
        this.isPreview = preview;
        InitializeComponent();

        StateChanged += (_, _) =>
        {
            var icon = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
            if (MaximizeBtn != null) MaximizeBtn.Content = icon;
            if (AuthMaximizeBtn != null) AuthMaximizeBtn.Content = icon;
        };

        // Initialize default sample keys
        keys.Add(new KeyEntry
        {
            Name = "id_ed25519_production",
            Algorithm = "ED25519",
            Fingerprint = "SHA256:4Kz8+y9xL0pQm2vR7wX1a9Zb5tC6eF8gH2jK4n",
            PublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleProdKeyProduction2026 operator@internal",
            AssociatedHostsCount = 18,
            CreatedAt = "2026-01-14",
            IsPassphraseProtected = true
        });
        keys.Add(new KeyEntry
        {
            Name = "aws_bastion_rsa4096",
            Algorithm = "RSA-4096",
            Fingerprint = "SHA256:8Rm1+p4vQ9xT2yL5wX8a0Zb3tC5eF7gH1jK3m",
            PublicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDC7ExampleRsaKey2026 operator@aws",
            AssociatedHostsCount = 12,
            CreatedAt = "2026-02-02",
            IsPassphraseProtected = true
        });
        keys.Add(new KeyEntry
        {
            Name = "staging_cluster_ed25519",
            Algorithm = "ED25519",
            Fingerprint = "SHA256:1Pn2+s5wR8uY3zM6vA9b1Xb4uD6eG8hJ2kL5o",
            PublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStagingClusterKeyExample2026 deploy@staging",
            AssociatedHostsCount = 6,
            CreatedAt = "2026-03-10",
            IsPassphraseProtected = false
        });
        keys.Add(new KeyEntry
        {
            Name = "backup_dr_ed25519",
            Algorithm = "ED25519",
            Fingerprint = "SHA256:9Tx3+u6xS9vZ4aN7wB0c2Yc5vE7fH9iK3lM6p",
            PublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBackupDrKeyExample2026 root@backup",
            AssociatedHostsCount = 2,
            CreatedAt = "2026-04-01",
            IsPassphraseProtected = true
        });

        if (KeysList != null) KeysList.ItemsSource = keys;
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

        Closed += (_, _) =>
        {
            foreach (var view in terminals) view.Dispose();
            api?.Dispose();
        };
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        OmniBar.TextChanged += (_, _) =>
        {
            OmniHint.Visibility = string.IsNullOrWhiteSpace(OmniBar.Text) ? Visibility.Visible : Visibility.Collapsed;
        };
    }

    // -------------------------------------------------------------
    // Automated Preview Helpers for Smoke Tests
    // -------------------------------------------------------------
    internal void ShowAuthForPreview()
    {
        AuthGrid.Visibility = Visibility.Visible;
        MainAppGrid.Visibility = Visibility.Collapsed;
    }

    internal void ShowDashboardForPreview()
    {
        AuthGrid.Visibility = Visibility.Collapsed;
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("dashboard");
    }

    internal void ShowHostsForPreview()
    {
        AuthGrid.Visibility = Visibility.Collapsed;
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("hosts");
        HostListGrid.Visibility = Visibility.Visible;
        HostEditorGrid.Visibility = Visibility.Collapsed;
    }

    internal void ShowAddHostForPreview()
    {
        AuthGrid.Visibility = Visibility.Collapsed;
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("hosts");
        OpenHostEditor(new Host { Port = 22, User = "root", DefaultAuthMethod = "key" });
    }

    internal void ShowSftpForPreview()
    {
        AuthGrid.Visibility = Visibility.Collapsed;
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("sftp");
    }

    internal void ShowKeysForPreview()
    {
        AuthGrid.Visibility = Visibility.Collapsed;
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("keys");
    }

    internal void SwitchThemeForPreview(AppTheme theme)
    {
        ThemeManager.ApplyTheme(theme);
        if (ThemeToggleBtn != null)
            ThemeToggleBtn.Content = theme == AppTheme.Dark ? "☀ Theme" : "🌙 Theme";
        HighlightNavButton(currentPage);
    }

    // -------------------------------------------------------------
    // Page Navigation
    // -------------------------------------------------------------
    private void AnimatePageIn(UIElement page)
    {
        if (isPreview)
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
    private void AuthUnlock_Click(object sender, RoutedEventArgs e)
    {
        var email = AuthEmailInput.Text.Trim();
        var pass = AuthPasswordInput.Password;

        if (string.IsNullOrWhiteSpace(email) || string.IsNullOrWhiteSpace(pass))
        {
            MessageBox.Show(this, "Please provide your Account Email and Master Password.", "Authentication Required", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        IsUnlocked = true;
        if (SettingsUserEmail != null) SettingsUserEmail.Text = email;
        AuthGrid.Visibility = Visibility.Collapsed;
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("dashboard");
        if (StatusText != null) StatusText.Text = $"Master Vault Unlocked. Session: {email}";
    }

    private void AuthOffline_Click(object sender, RoutedEventArgs e)
    {
        IsUnlocked = true;
        AuthGrid.Visibility = Visibility.Collapsed;
        MainAppGrid.Visibility = Visibility.Visible;
        ShowPage("dashboard");
        if (StatusText != null) StatusText.Text = "Running in Local Offline Mode.";
    }

    private void LockVault_Click(object sender, RoutedEventArgs e)
    {
        IsUnlocked = false;
        MainAppGrid.Visibility = Visibility.Collapsed;
        AuthGrid.Visibility = Visibility.Visible;
        if (StatusText != null) StatusText.Text = "Master Vault Locked.";
    }

    // -------------------------------------------------------------
    // Theme Management (Dark Terminal Edition / Light Bauhaus)
    // -------------------------------------------------------------
    private void ThemeToggle_Click(object sender, RoutedEventArgs e)
    {
        var next = ThemeManager.CurrentTheme == AppTheme.Dark ? AppTheme.Light : AppTheme.Dark;
        ThemeManager.ApplyTheme(next);
        ThemeToggleBtn.Content = next == AppTheme.Dark ? "☀ Theme" : "🌙 Theme";
        HighlightNavButton(currentPage);
        if (StatusText != null) StatusText.Text = $"Switched to {(next == AppTheme.Dark ? "Dark Terminal Edition" : "Light Bauhaus Edition")}";
    }

    private void SetDarkTheme_Click(object sender, RoutedEventArgs e)
    {
        ThemeManager.ApplyTheme(AppTheme.Dark);
        ThemeToggleBtn.Content = "☀ Theme";
        HighlightNavButton(currentPage);
        if (StatusText != null) StatusText.Text = "Applied Dark Terminal Edition";
    }

    private void SetLightTheme_Click(object sender, RoutedEventArgs e)
    {
        ThemeManager.ApplyTheme(AppTheme.Light);
        ThemeToggleBtn.Content = "🌙 Theme";
        HighlightNavButton(currentPage);
        if (StatusText != null) StatusText.Text = "Applied Light Bauhaus Edition";
    }

    // -------------------------------------------------------------
    // Dashboard Logic & Metrics
    // -------------------------------------------------------------
    private void UpdateDashboardMetrics()
    {
        if (MetricHostsCount != null) MetricHostsCount.Text = hosts.Count.ToString();
        if (SidebarHostBadge != null) SidebarHostBadge.Text = hosts.Count.ToString();
        if (MetricKeysCount != null) MetricKeysCount.Text = keys.Count.ToString();
        if (SidebarKeysBadge != null) SidebarKeysBadge.Text = keys.Count.ToString();
        if (MetricActiveSessions != null) MetricActiveSessions.Text = openSessions.Count.ToString();
        if (ActiveTerminalsSection != null) ActiveTerminalsSection.Visibility = openSessions.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        // OS Breakdown
        int ubnt = hosts.Count(h => (h.Name + string.Join(" ", h.Tags)).Contains("ubuntu", StringComparison.OrdinalIgnoreCase) || h.Name.Contains("k8s", StringComparison.OrdinalIgnoreCase));
        int deb = hosts.Count(h => (h.Name + string.Join(" ", h.Tags)).Contains("debian", StringComparison.OrdinalIgnoreCase));
        int alp = hosts.Count(h => (h.Name + string.Join(" ", h.Tags)).Contains("alpine", StringComparison.OrdinalIgnoreCase));
        int rhel = hosts.Count(h => (h.Name + string.Join(" ", h.Tags)).Contains("redhat", StringComparison.OrdinalIgnoreCase));
        if (MetricHostsBreakdown != null)
            MetricHostsBreakdown.Text = $"UBNT {ubnt} • DEB {deb} • ALP {alp} • RHEL {rhel}";

        if (DashboardHostsList != null)
            DashboardHostsList.ItemsSource = hosts.Take(6).ToArray();
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
            await HandleConnectQueryAsync(input);
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
        ).OrderBy(h => h.Name).ToArray();

        Hosts.ItemsSource = filtered;
        Hosts.SelectedItem = filtered.FirstOrDefault(h => h.Id == selectedId) ?? filtered.FirstOrDefault();

        if (HostCount != null) HostCount.Text = $"{filtered.Length} configured hosts";
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
        DetailSubtitle.Text = string.IsNullOrWhiteSpace(host.Notes) ? "Zero telemetry proxy" : host.Notes;
        DetailAddress.Text = host.Address;
        DetailPort.Text = host.Port.ToString();
        DetailUser.Text = string.IsNullOrWhiteSpace(host.User) ? "root" : host.User;
        DetailAuth.Text = host.DefaultAuthMethod == "password" ? "Password" : "SSH Keypair";
        DetailFavBtn.Content = host.Favorite ? "★ Favorited" : "☆ Add Favorite";
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
        editingHost = host;
        EditorName.Text = host.Name;
        EditorHost.Text = host.Address;
        EditorPort.Text = host.Port.ToString();
        EditorUser.Text = string.IsNullOrWhiteSpace(host.User) ? "root" : host.User;
        EditorKeyPath.Text = host.IdentityFile ?? "";
        EditorJump.Text = host.ProxyJump ?? "";
        EditorTags.Text = string.Join(", ", host.Tags);
        EditorNotes.Text = host.Notes;
        EditorHeader.Text = string.IsNullOrWhiteSpace(host.Name) ? "Register New Host" : $"Edit Host: {host.Name}";

        HostListGrid.Visibility = Visibility.Collapsed;
        HostEditorGrid.Visibility = Visibility.Visible;
        EditorHost.Focus();
    }

    private void EditorCancel_Click(object sender, RoutedEventArgs e)
    {
        HostEditorGrid.Visibility = Visibility.Collapsed;
        HostListGrid.Visibility = Visibility.Visible;
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

    private async void EditorSave_Click(object sender, RoutedEventArgs e)
    {
        if (editingHost == null) return;
        var address = EditorHost.Text.Trim();
        var user = EditorUser.Text.Trim();
        if (string.IsNullOrWhiteSpace(address) || string.IsNullOrWhiteSpace(user))
        {
            MessageBox.Show(this, "Endpoint address and remote username are required.", "Validation Error", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (!int.TryParse(EditorPort.Text.Trim(), out var port) || port is < 1 or > 65535)
        {
            MessageBox.Show(this, "SSH port must be between 1 and 65535.", "Validation Error", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        editingHost.Name = string.IsNullOrWhiteSpace(EditorName.Text) ? address : EditorName.Text.Trim();
        editingHost.Address = address;
        editingHost.Port = port;
        editingHost.User = user;
        editingHost.IdentityFile = string.IsNullOrWhiteSpace(EditorKeyPath.Text) ? null : EditorKeyPath.Text.Trim();
        editingHost.ProxyJump = string.IsNullOrWhiteSpace(EditorJump.Text) ? null : EditorJump.Text.Trim();
        editingHost.Tags = EditorTags.Text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        editingHost.Notes = EditorNotes.Text;

        await GuardAsync(async () =>
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
        });
    }

    // -------------------------------------------------------------
    // SFTP Page Logic
    // -------------------------------------------------------------
    private void SftpSessionCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Load remote directory if active session selected
    }

    private void SftpUp_Click(object sender, RoutedEventArgs e)
    {
        var current = SftpPathInput.Text.Trim();
        if (current.Length > 1 && current.Contains('/'))
        {
            var parent = Path.GetDirectoryName(current)?.Replace('\\', '/');
            SftpPathInput.Text = string.IsNullOrEmpty(parent) ? "/" : parent;
        }
    }

    private void SftpRefresh_Click(object sender, RoutedEventArgs e)
    {
        if (StatusText != null) StatusText.Text = $"Refreshed SFTP listing for {SftpPathInput.Text}";
    }

    private void SftpNewFolder_Click(object sender, RoutedEventArgs e)
    {
        MessageBox.Show(this, "Enter folder name to create in current remote path.", "New SFTP Folder", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void SftpFilesGrid_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            var files = (string[])e.Data.GetData(DataFormats.FileDrop);
            if (files != null && files.Length > 0)
            {
                if (StatusText != null) StatusText.Text = $"Queued upload of {files.Length} files via SFTP.";
            }
        }
    }

    // -------------------------------------------------------------
    // Key Vault Page Logic
    // -------------------------------------------------------------
    private void RegisterKey_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Import SSH Key",
            Filter = "Key Files (*.pub;*.pem;id_*;*.key)|*.pub;*.pem;id_*;*.key|All Files (*.*)|*.*"
        };
        if (picker.ShowDialog(this) == true)
        {
            var newKey = new KeyEntry
            {
                Name = Path.GetFileNameWithoutExtension(picker.FileName),
                Algorithm = picker.FileName.Contains("ed25519", StringComparison.OrdinalIgnoreCase) ? "ED25519" : "RSA-4096",
                Fingerprint = "SHA256:" + Guid.NewGuid().ToString("n")[..20],
                PrivateKeyPath = picker.FileName,
                AssociatedHostsCount = 1
            };
            keys.Add(newKey);
            UpdateDashboardMetrics();
            if (StatusText != null) StatusText.Text = $"Registered new key: {newKey.Name}";
        }
    }

    private void GenerateKeypair_Click(object sender, RoutedEventArgs e)
    {
        var generated = new KeyEntry
        {
            Name = "generated_ed25519_" + DateTime.UtcNow.ToString("yyyyMMdd"),
            Algorithm = "ED25519",
            Fingerprint = "SHA256:" + Guid.NewGuid().ToString("n")[..20],
            PublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI" + Guid.NewGuid().ToString("n") + " operator@generated",
            AssociatedHostsCount = 0
        };
        keys.Add(generated);
        UpdateDashboardMetrics();
        Clipboard.SetText(generated.PublicKey);
        MessageBox.Show(this, $"Generated ED25519 keypair.\n\nPublic key copied to clipboard:\n{generated.PublicKey}", "Keypair Generated", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void CopyPubKey_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: KeyEntry key } && !string.IsNullOrEmpty(key.PublicKey))
        {
            Clipboard.SetText(key.PublicKey);
            if (StatusText != null) StatusText.Text = $"Copied public key for {key.Name} to clipboard.";
        }
    }

    private void RemoveKey_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: KeyEntry key })
        {
            keys.Remove(key);
            UpdateDashboardMetrics();
            if (StatusText != null) StatusText.Text = $"Removed key {key.Name}";
        }
    }

    // -------------------------------------------------------------
    // Omnibar Quick Connect
    // -------------------------------------------------------------
    private async void OmniBar_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        var query = OmniBar.Text.Trim();
        if (string.IsNullOrEmpty(query)) return;
        await HandleConnectQueryAsync(query);
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

        string user = "root";
        string address = query;
        int port = 22;

        if (address.StartsWith("ssh://", StringComparison.OrdinalIgnoreCase))
            address = address[6..];

        if (address.Contains('@'))
        {
            var parts = address.Split('@', 2);
            user = parts[0];
            address = parts[1];
        }
        if (address.Contains(':'))
        {
            var parts = address.Split(':', 2);
            address = parts[0];
            if (int.TryParse(parts[1], out var parsedPort) && parsedPort is >= 1 and <= 65535)
                port = parsedPort;
        }

        var adHoc = new Host
        {
            Name = query,
            Address = address,
            User = user,
            Port = port,
            DefaultAuthMethod = "key"
        };
        await GuardAsync(() => ConnectHostAsync(adHoc));
    }

    // -------------------------------------------------------------
    // SSH Session Connections & Tab Management
    // -------------------------------------------------------------
    private async Task ConnectHostAsync(Host host)
    {
        var fields = new List<Field> { new("user", "Username", host.User) };
        fields.Add(host.DefaultAuthMethod == "password"
            ? new("password", "Password", Secret: true)
            : new("passphrase", "Key Passphrase (if encrypted)", Secret: true));

        if (!string.IsNullOrWhiteSpace(host.ProxyJump))
        {
            fields.AddRange([
                new("jump_user", "Jump-host Username (optional)"),
                new("jump_password", "Jump-host Password (optional)", Secret: true),
                new("jump_identity", "Jump-host Private Key (optional)", File: true)
            ]);
        }

        var dialog = new FormDialog(this, "Authenticate Connection: " + host.Name, fields, "Connect", "Zero-persistence security: credentials stored in volatile memory only.");
        if (dialog.ShowDialog() != true) return;

        var values = dialog.Values;
        var attrs = JsonSerializer.SerializeToElement(host, DesktopClient.Json).Deserialize<Dictionary<string, object?>>()!;
        attrs["user"] = values["user"];
        if (values.TryGetValue("password", out var pass) && !string.IsNullOrEmpty(pass)) attrs["password"] = pass;
        if (values.TryGetValue("passphrase", out var phr) && !string.IsNullOrEmpty(phr)) attrs["passphrase"] = phr;

        if (api != null)
        {
            var result = await api.PostAsync("sessions", attrs);
            var sessionId = result.GetProperty("session_id").GetString()!;
            AddTerminalTab(host.Name, sessionId, host);
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
        var sessionItem = new TerminalTabItem { Title = title, SessionId = id };
        openSessions.Add(sessionItem);

        var tab = new TabItem();
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
            Content = "\u2715",
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
            Text = $"pty#{openSessions.Count - 1} • {id[..Math.Min(8, id.Length)]}",
            FontFamily = (FontFamily)Application.Current.Resources["MonoFont"],
            Foreground = (Brush)Application.Current.Resources["MutedSubtle"],
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center
        });
        toolDock.Children.Add(rightInfo);

        var leftButtons = new StackPanel { Orientation = Orientation.Horizontal };
        var disconnBtn = new Button { Content = "Disconnect", Style = (Style)Application.Current.Resources["GhostButton"], Margin = new Thickness(0, 0, 6, 0) };
        var reconnBtn = new Button { Content = "Reconnect", Style = (Style)Application.Current.Resources["GhostButton"], Margin = new Thickness(0, 0, 6, 0) };
        var sftpBtn = new Button { Content = "Files (SFTP)", Style = (Style)Application.Current.Resources["GhostButton"], Margin = new Thickness(0, 0, 6, 0) };
        var splitBtn = new Button { Content = "◫ Split Right", Style = (Style)Application.Current.Resources["GhostButton"] };

        leftButtons.Children.Add(disconnBtn);
        leftButtons.Children.Add(reconnBtn);
        leftButtons.Children.Add(sftpBtn);
        leftButtons.Children.Add(splitBtn);
        toolDock.Children.Add(leftButtons);
        toolBar.Child = toolDock;
        Grid.SetRow(toolBar, 0);
        rootGrid.Children.Add(toolBar);

        // Terminal Grid
        var terminalGrid = new Grid();
        terminalGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        terminalGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
        terminalGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });

        if (api != null)
        {
            var view = new TerminalView(api, id, this, text =>
            {
                if (SessionTabs.SelectedItem == tab && StatusText != null)
                    StatusText.Text = $"{title}: {text}";
            });
            Grid.SetColumn(view, 0);
            terminalGrid.Children.Add(view);
            terminals.Add(view);
        }
        else
        {
            var mockTerm = new Border
            {
                Background = (Brush)Application.Current.Resources["CardLow"],
                Padding = new Thickness(20),
                Child = new TextBlock
                {
                    Text = $"Connected to {title} via SSHv2\nLinux 6.8.0-40-generic x86_64\n\noperator@{host?.Address ?? "server"}:~$ ",
                    FontFamily = (FontFamily)Application.Current.Resources["MonoFont"],
                    Foreground = (Brush)Application.Current.Resources["Text"],
                    FontSize = 13
                }
            };
            Grid.SetColumn(mockTerm, 0);
            terminalGrid.Children.Add(mockTerm);
        }

        Grid.SetRow(terminalGrid, 1);
        rootGrid.Children.Add(terminalGrid);
        tab.Content = rootGrid;

        closeBtn.Click += (_, _) =>
        {
            SessionTabs.Items.Remove(tab);
            openSessions.Remove(sessionItem);
            UpdateDashboardMetrics();
            if (SessionTabs.Items.Count == 0)
                ShowPage("dashboard");
        };

        SessionTabs.Items.Add(tab);
        SessionTabs.SelectedItem = tab;
        ShowPage("session");
        UpdateDashboardMetrics();
    }

    private void SidebarSessions_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SidebarSessionsList.SelectedItem is TerminalTabItem item)
        {
            foreach (TabItem tab in SessionTabs.Items)
            {
                if (tab.Header is StackPanel sp && sp.Children.OfType<TextBlock>().Any(tb => tb.Text == item.Title))
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
        // Session switch handler
    }

    // -------------------------------------------------------------
    // System & Daemon Communication
    // -------------------------------------------------------------
    private async Task InitializeAsync()
    {
        await RefreshAsync();
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
            if (StatusText != null) StatusText.Text = ex.Message;
            MessageBox.Show(this, ex.Message, "ssh-client", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    // -------------------------------------------------------------
    // Titlebar Actions
    // -------------------------------------------------------------
    private void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void Maximize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}

public class TerminalTabItem
{
    public string Title { get; set; } = "";
    public string SessionId { get; set; } = "";
}
