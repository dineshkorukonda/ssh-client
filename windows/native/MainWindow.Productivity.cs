using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace SSHClient.Windows;

public partial class MainWindow
{
    private readonly HashSet<string> recordedSessions = [];
    public Func<Task>? RestartBackend { get; set; }

    private string EditorSnapshot() => string.Join('\n', EditorName.Text, EditorHost.Text, EditorPort.Text, EditorUser.Text, EditorKeyPath.Text, EditorJump.Text, EditorTags.Text, EditorNotes.Text, (EditorAuth.SelectedItem as ComboBoxItem)?.Tag);
    private bool EditorDirty() => editingHost != null && HostEditorGrid.Visibility == Visibility.Visible && EditorSnapshot() != editorBaseline;
    private bool ConfirmDiscard()
    {
        if (!EditorDirty()) return true;
        if (MessageBox.Show(this, "Discard unsaved host changes?", "Unsaved changes", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return false;
        HostEditorGrid.Visibility = Visibility.Collapsed; HostListGrid.Visibility = Visibility.Visible; editingHost = null; return true;
    }

    internal void OpenCommandPalette() { OmniBar.Focus(); OmniBar.SelectAll(); UpdatePalette(); }
    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.B && Keyboard.Modifiers == (ModifierKeys.Control | ModifierKeys.Shift)) { CollapseSidebar_Click(this, new()); e.Handled = true; }
        if (e.Key == Key.K && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { OpenCommandPalette(); e.Handled = true; }
        if (e.Key == Key.Escape && PalettePopup.IsOpen) { PalettePopup.IsOpen = false; e.Handled = true; }
        if (PalettePopup.IsOpen && e.Key is Key.Down or Key.Up && PaletteList.Items.Count > 0) {
            PaletteList.SelectedIndex = Math.Clamp(PaletteList.SelectedIndex + (e.Key == Key.Down ? 1 : -1), 0, PaletteList.Items.Count - 1);
            PaletteList.ScrollIntoView(PaletteList.SelectedItem); e.Handled = true;
        }
    }
    private void Window_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (PalettePopup.IsOpen && !OmniBar.IsMouseOver && !PaletteList.IsMouseOver) PalettePopup.IsOpen = false;
    }
    private void UpdatePalette()
    {
        var query = OmniBar.Text.Trim();
        var results = hosts.Where(host => host.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || host.Address.Contains(query, StringComparison.OrdinalIgnoreCase) || string.Join(' ', host.Tags).Contains(query, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(host => host.Name.Equals(query, StringComparison.OrdinalIgnoreCase)).ThenByDescending(host => host.Favorite).ThenByDescending(host => host.LastConnectedAt)
            .Take(12).Select(host => new PaletteEntry($"{host.Name} — {host.Description}", host)).ToList();
        results.InsertRange(0, openSessions.Reverse().Where(item => item.Summary.Contains(query, StringComparison.OrdinalIgnoreCase))
            .Take(8).Select(item => new PaletteEntry("Switch to session: " + item.SelectionLabel, SessionId: item.SessionId)));
        foreach (var (label, command) in new[] { ("Add host", "add"), ("Hosts", "hosts"), ("Files", "sftp"), ("SSH keys", "keys"), ("Settings", "settings") })
            if (label.Contains(query, StringComparison.OrdinalIgnoreCase)) results.Add(new PaletteEntry(label, Command: command));
        try { if (query.Length > 0) { var host = QuickConnect.Parse(query); results.Add(new PaletteEntry("Quick connect: " + host.Description, host)); } } catch (ArgumentException) { }
        PaletteList.ItemsSource = results; PaletteList.SelectedIndex = results.Count > 0 ? 0 : -1; PalettePopup.IsOpen = true;
    }
    private async void PaletteRun_Click(object sender, MouseButtonEventArgs e) => await GuardAsync(RunPaletteAsync);
    private async void Palette_KeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) { e.Handled = true; await GuardAsync(RunPaletteAsync); } }
    private async Task RunPaletteAsync()
    {
        if (PaletteList.SelectedItem is not PaletteEntry entry) return;
        PalettePopup.IsOpen = false;
        if (entry.SessionId != null) {
            var tab = SessionTabs.Items.Cast<TabItem>().FirstOrDefault(tab => tab.Tag is TerminalTabItem item && item.SessionId == entry.SessionId);
            if (tab != null) { ShowPage("session"); SessionTabs.SelectedItem = tab; }
        }
        else if (entry.Host != null) await ConnectHostAsync(entry.Host);
        else if (entry.Command == "add") { ShowPage("hosts"); NewHost_Click(this, new()); }
        else if (entry.Command != null) ShowPage(entry.Command);
    }

    private async Task LoadPreferencesAsync()
    {
        if (api == null) return;
        var settings = await api.GetAsync("settings");
        SettingsFontSize.Text = settings.TryGetProperty("font_size", out var font) ? font.ToString() : "13";
        SettingsScrollback.Text = settings.TryGetProperty("scrollback", out var lines) ? lines.ToString() : "5000";
        var family = settings.TryGetProperty("font_family", out var savedFamily) ? savedFamily.GetString() : "Cascadia Code";
        SettingsFontFamily.SelectedItem = SettingsFontFamily.Items.Cast<ComboBoxItem>().FirstOrDefault(option => option.Content.ToString() == family) ?? SettingsFontFamily.Items[0];
        SettingsLineHeight.Text = settings.TryGetProperty("line_height", out var height) ? height.ToString() : "1.15";
        reducedMotion = settings.TryGetProperty("reduced_motion", out var motion) && motion.GetBoolean(); ReducedMotion.IsChecked = reducedMotion;
        ThemeManager.ApplyTheme(settings.TryGetProperty("theme", out var theme) && theme.GetString() == "light" ? AppTheme.Light : AppTheme.Dark);
        ThemeToggleBtn.Content = "Theme"; HighlightNavButton(currentPage);
    }
    private async void SaveSettings_Click(object sender, RoutedEventArgs e) => await GuardAsync(SavePreferencesAsync);
    private async Task SavePreferencesAsync()
    {
        if (!int.TryParse(SettingsFontSize.Text, out var font) || font is < 8 or > 32 || !int.TryParse(SettingsScrollback.Text, out var lines) || lines is < 100 or > 100000) {
            SettingsError.Text = "Font size must be 8–32 and scrollback must be 100–100000 lines."; return;
        }
        if (!double.TryParse(SettingsLineHeight.Text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var lineHeight) || !double.IsFinite(lineHeight) || lineHeight is < 1 or > 1.6) {
            SettingsError.Text = "Line height must be between 1.0 and 1.6."; SettingsLineHeight.Focus(); return;
        }
        var fontFamily = (SettingsFontFamily.SelectedItem as ComboBoxItem)?.Content.ToString() ?? "Cascadia Code";
        if (api != null) await api.PostAsync("settings", new { font_family = fontFamily, line_height = lineHeight, font_size = font, scrollback = lines, theme = ThemeManager.CurrentTheme == AppTheme.Light ? "light" : "dark", reduced_motion = ReducedMotion.IsChecked == true });
        reducedMotion = ReducedMotion.IsChecked == true;
        foreach (var terminal in terminals.ToArray()) await terminal.ApplySettingsAsync();
        SettingsError.Text = "Preferences saved and applied to open terminals.";
    }
    private async Task SetThemeAsync(AppTheme theme)
    {
        if (api != null) {
            var settings = (await api.GetAsync("settings")).Deserialize<Dictionary<string, object?>>() ?? [];
            settings.TryAdd("font_size", 13); settings.TryAdd("scrollback", 5000); settings["theme"] = theme == AppTheme.Light ? "light" : "dark";
            await api.PostAsync("settings", settings);
        }
        ThemeManager.ApplyTheme(theme); ThemeToggleBtn.Content = "Theme"; HighlightNavButton(currentPage);
        foreach (var terminal in terminals.ToArray()) await terminal.ApplySettingsAsync();
    }
    private async Task RecordConnectionAsync(TerminalTabItem item)
    {
        if (api == null || item.Host == null || !hosts.Any(host => host.Id == item.Host.Id) || !recordedSessions.Add(item.SessionId)) return;
        var saved = hosts.Single(host => host.Id == item.Host.Id).Copy();
        saved.LastConnectedAt = DateTimeOffset.UtcNow.ToString("O");
        await api.PostAsync("hosts", saved);
        await RefreshAsync();
    }

    private async Task RefreshWorkspacesAsync()
    {
        if (api == null) return;
        WorkspaceList.ItemsSource = (await api.GetAsync("workspaces")).Deserialize<List<WorkspaceEntry>>(DesktopClient.Json) ?? [];
    }
    private async void SaveWorkspace_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () => {
        if (api == null) return;
        var dialog = new FormDialog(this, "Save workspace", [new("name", "Workspace name")]);
        if (dialog.ShowDialog() != true || string.IsNullOrWhiteSpace(dialog.Values["name"])) return;
        var layouts = openSessions.Where(item => item.Host != null && hosts.Any(host => host.Id == item.Host.Id)).Select(item => new WorkspaceLayout { HostId = item.Host!.Id, Panes = item.PaneIds.Count }).ToArray();
        await api.PostAsync("workspace", new { id = Guid.NewGuid().ToString("N"), name = dialog.Values["name"], host_ids = layouts.Select(layout => layout.HostId).Distinct().ToArray(), layouts });
        await RefreshWorkspacesAsync(); StatusText.Text = "Workspace saved. Credentials were excluded.";
    });
    private async void RestoreWorkspace_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () => {
        if (WorkspaceList.SelectedItem is not WorkspaceEntry workspace) { StatusText.Text = "Choose a workspace."; return; }
        if (MessageBox.Show(this, "Reconnect the saved hosts? You will be asked for any required credentials. Existing sessions remain open.", "Restore workspace", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        var layouts = workspace.Layouts.Length > 0 ? workspace.Layouts : workspace.HostIds.Select(id => new WorkspaceLayout { HostId = id, Panes = 1 }).ToArray();
        foreach (var layout in layouts.Take(100)) {
            var host = hosts.FirstOrDefault(host => host.Id == layout.HostId); if (host == null) continue;
            var before = openSessions.Count; await ConnectHostAsync(host);
            if (openSessions.Count == before) continue;
            var item = openSessions.Last(); var tab = SessionTabs.Items.Cast<TabItem>().Single(tab => tab.Tag == item);
            var grid = ((Grid)tab.Content).Children.OfType<Grid>().Single();
            for (var i = 1; i < Math.Clamp(layout.Panes, 1, 8); i++) await ConnectHostAsync(host, item, grid);
        }
    });
    private async void Backup_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () => {
        if (api == null) return; var result = await api.PostAsync("backup", new { }); StatusText.Text = "Database backup saved to " + result.GetProperty("path").GetString();
    });
    private async void ExportHosts_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () => {
        if (api == null) return; var picker = new SaveFileDialog { FileName = "ssh-client-hosts.json", Filter = "Host metadata|*.json" };
        if (picker.ShowDialog(this) == true) { var data = await api.GetAsync("export"); await File.WriteAllTextAsync(picker.FileName, data.GetRawText()); StatusText.Text = "Host metadata exported. Connection passwords and private-key files are excluded."; }
    });
    private async void ImportHosts_Click(object sender, RoutedEventArgs e) => await ImportHostsAsync("json");
    private async void ImportSshConfig_Click(object sender, RoutedEventArgs e) => await ImportHostsAsync("ssh_config");
    private async Task ImportHostsAsync(string type) => await GuardAsync(async () => {
        if (api == null) return; var picker = new OpenFileDialog { Title = type == "json" ? "Import exported host metadata" : "Import OpenSSH config", FileName = type == "ssh_config" ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "config") : "" };
        if (picker.ShowDialog(this) != true) return;
        var preview = (await api.PostAsync("import/preview", new { path = picker.FileName, type })).Deserialize<ImportPreview>(DesktopClient.Json)!;
        var dialog = new ImportPreviewDialog(this, preview);
        if (dialog.ShowDialog() != true) return;
        var result = await api.PostAsync("import", new { path = picker.FileName, type, selected_ids = dialog.SelectedIds });
        await RefreshAsync(); await RefreshKeysAsync();
        StatusText.Text = $"Imported {result.GetProperty("imported")} host(s); skipped {result.GetProperty("skipped")}. Existing hosts were preserved.";
    });

    private async void RetryOperation_Click(object sender, RoutedEventArgs e) { RecoveryPanel.Visibility = Visibility.Collapsed; if (retryOperation != null) await GuardAsync(retryOperation); }
    private void RecoveryEdit_Click(object sender, RoutedEventArgs e) { RecoveryPanel.Visibility = Visibility.Collapsed; ShowPage("hosts"); if (Hosts.SelectedItem is Host host) OpenHostEditor(host.Copy()); }
    private void CopyDiagnostics_Click(object sender, RoutedEventArgs e) { Clipboard.SetText(diagnostics); StatusText.Text = "Diagnostics copied. Review them before sharing."; }
    private void DismissRecovery_Click(object sender, RoutedEventArgs e) => RecoveryPanel.Visibility = Visibility.Collapsed;
    internal void SetBackendUnavailable()
    {
        foreach (var item in openSessions) item.State = "Backend unavailable";
        RecoveryMessage.Text = "The local SSH service stopped. Existing connections ended. Retry restarts the service; restore a workspace to reconnect.";
        RecoveryPanel.Visibility = Visibility.Visible;
        retryOperation = async () => { if (RestartBackend != null && ConfirmDiscard()) await RestartBackend(); };
    }

    internal async Task VerifyProductivityForSmokeAsync(Host fixture)
    {
        await InitializeAsync();
        ShowPage("hosts"); OpenHostEditor(fixture.Copy());
        EditorPort.Text = "0"; await SaveEditorAsync(false);
        if (string.IsNullOrEmpty(EditorError.Text) || HostEditorGrid.Visibility != Visibility.Visible) throw new IOException("Invalid host edit did not stay open with a field error.");
        EditorPort.Text = fixture.Port.ToString(); EditorNotes.Text = "Smoke editor persistence";
        await SaveEditorAsync(false);
        var loaded = (await api!.GetAsync("hosts")).Deserialize<List<Host>>(DesktopClient.Json)!.Single(host => host.Id == fixture.Id);
        if (loaded.Notes != "Smoke editor persistence") throw new IOException("Editor save did not persist its changes.");
        await VerifyHostKeyFlowForSmokeAsync(fixture);
        SettingsFontSize.Text = "16"; SettingsScrollback.Text = "5000"; ReducedMotion.IsChecked = true;
        await SavePreferencesAsync(); await LoadPreferencesAsync();
        if (SettingsFontSize.Text != "16" || ReducedMotion.IsChecked != true) throw new IOException("Preferences did not survive reload.");
        await SetThemeAsync(AppTheme.Light); await LoadPreferencesAsync();
        if (ThemeManager.CurrentTheme != AppTheme.Light) throw new IOException("Theme was not persisted.");
        VerifyAccessibilityForSmoke();
        await SetThemeAsync(AppTheme.Dark);
        OmniBar.Text = fixture.Name; OpenCommandPalette();
        if (!PaletteList.Items.Cast<PaletteEntry>().Any(entry => entry.Host?.Id == fixture.Id)) throw new IOException("Palette did not find a saved host.");
        var sessionEntry = PaletteList.Items.Cast<PaletteEntry>().FirstOrDefault(entry => entry.SessionId != null);
        if (sessionEntry == null) throw new IOException("Palette did not offer the existing session.");
        var key = new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(this), Environment.TickCount, Key.Down) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        RaiseEvent(key);
        if (!key.Handled || PaletteList.SelectedIndex != 1) throw new IOException("Palette keyboard navigation did not move selection.");
        var sessionCount = openSessions.Count;
        PaletteList.SelectedItem = sessionEntry; await RunPaletteAsync();
        if (openSessions.Count != sessionCount || SessionTabs.SelectedItem is not TabItem { Tag: TerminalTabItem selected } || selected.SessionId != sessionEntry.SessionId) throw new IOException("Palette did not select the existing session by ID.");
        PalettePopup.IsOpen = false;
    }

    internal async Task VerifyConnectionFormForSmokeAsync(Host fixture)
    {
        var passwordHost = fixture.Copy(); passwordHost.DefaultAuthMethod = "password"; passwordHost.IdentityFile = null;
        passwordHost.Extra ??= []; passwordHost.Extra["auth_order"] = JsonSerializer.SerializeToElement(new[] { "password" });
        var before = openSessions.Count;
        PrepareDialogForSmoke = dialog => {
            dialog.Opacity = 0; dialog.ShowInTaskbar = false;
            dialog.Loaded += (_, _) => dialog.Dispatcher.BeginInvoke(() => dialog.CompleteForSmoke(new Dictionary<string, string> { ["user"] = "fixture", ["password"] = "fixture-password" }, true));
        };
        try {
            await ConnectHostAsync(passwordHost);
            var tab = (TabItem)SessionTabs.SelectedItem; var item = (TerminalTabItem)tab.Tag;
            await WaitSessionStateForSmokeAsync(item.SessionId, "connected");
            await CloseSessionTabAsync(tab);
            PrepareDialogForSmoke = dialog => { dialog.Opacity = 0; dialog.ShowInTaskbar = false; dialog.Loaded += (_, _) => dialog.Dispatcher.BeginInvoke(() => dialog.CompleteForSmoke(new Dictionary<string, string>(), false)); };
            await ConnectHostAsync(passwordHost);
            if (openSessions.Count != before) throw new IOException("Cancelled connection dialog created a terminal.");
        }
        finally { PrepareDialogForSmoke = null; }
    }
}

public sealed class WorkspaceEntry
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "Saved workspace";
    public string[] HostIds { get; set; } = [];
    public WorkspaceLayout[] Layouts { get; set; } = [];
}
public sealed class WorkspaceLayout { public string HostId { get; set; } = ""; public int Panes { get; set; } = 1; }
