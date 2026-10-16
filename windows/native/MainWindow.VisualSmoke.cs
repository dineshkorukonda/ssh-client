using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

namespace SSHClient.Windows;

public partial class MainWindow
{
    // These captures use the real local SSH fixture and real WebView2 output.
    internal async Task VerifyWorkbenchForSmokeAsync(string folder)
    {
        Directory.CreateDirectory(folder);
        var tab = SessionTabs.Items.OfType<TabItem>().First(candidate => candidate.Tag is TerminalTabItem);
        var item = (TerminalTabItem)tab.Tag;
        SessionTabs.SelectedItem = tab;
        var originalSessions = item.PaneIds.ToArray();
        sidebarCollapsed = false; ApplyCompactLayout(1280);
        CollapseSidebar_Click(this, new RoutedEventArgs());
        if (SidebarColumn.Width.Value != 60) throw new IOException("Sidebar did not collapse.");
        CollapseSidebar_Click(this, new RoutedEventArgs());
        if (SidebarColumn.Width.Value != 204 || !originalSessions.SequenceEqual(item.PaneIds))
            throw new IOException("Sidebar expansion changed the session workspace.");
        sidebarCollapsed = null;
        inspectorRequested = true; ApplyCompactLayout(720);
        if (HostInspector.Visibility != Visibility.Visible || InspectorColumn.Width.Value != 0 || Grid.GetColumn(HostInspector) != 0)
            throw new IOException("Compact host details must open as an overlay.");
        ToggleInspector_Click(this, new RoutedEventArgs());
        if (HostInspector.Visibility != Visibility.Collapsed) throw new IOException("Compact details could not be closed.");
        inspectorRequested = null;

        ShowPage("settings");
        SettingsFontFamily.SelectedIndex = 1; SettingsLineHeight.Text = "1.3";
        await SavePreferencesAsync(); await LoadPreferencesAsync();
        if (SettingsLineHeight.Text != "1.3" || ((ComboBoxItem)SettingsFontFamily.SelectedItem).Content.ToString() != "Consolas")
            throw new IOException("Terminal typography did not persist.");
        SettingsLineHeight.Text = "0.5"; await SavePreferencesAsync();
        if (!SettingsError.Text.Contains("Line height")) throw new IOException("Invalid line height did not show validation.");
        await LoadPreferencesAsync();
        if (SettingsLineHeight.Text != "1.3") throw new IOException("Invalid typography replaced saved preferences.");
        SettingsFontFamily.SelectedIndex = 0; SettingsLineHeight.Text = "1.15";
        await SavePreferencesAsync();

        var root = (Grid)tab.Content;
        var panes = root.Children.OfType<Grid>().Single();
        var split = (await api!.PostAsync("sessions", item.Host!)).GetProperty("session_id").GetString()!;
        AddSplitPane(item, panes, split, item.Host);
        var second = item.Views.Last();
        await second.Ready.WaitAsync(TimeSpan.FromSeconds(30));
        await WaitSessionStateForSmokeAsync(split, "connected");
        await second.SendSmokeInputAsync("split-pane-check\r");
        for (var retry = 0; retry < 50 && !(await second.ReadScreenAsync()).Contains("echo:split-pane-check"); retry++) await Task.Delay(100);
        if (!(await second.ReadScreenAsync()).Contains("echo:split-pane-check")) throw new IOException("Split pane did not render its own session.");
        second.FocusTerminal(); await Task.Delay(100);
        if (item.ActiveView != second) throw new IOException("Focusing a split did not select its pane.");
        ShowPage("hosts"); ShowPage("session"); await Task.Delay(100);
        if (item.ActiveView != second) throw new IOException("Page navigation forgot the active pane.");

        foreach (var (width, height) in new[] { (1536, 960), (1280, 800), (1024, 768), (720, 540) })
        {
            Width = width; Height = height; ApplyCompactLayout(width); UpdateLayout();
            foreach (var page in new[] { "dashboard", "hosts", "keys", "settings", "sftp", "session" })
            {
                ShowPage(page);
                if (page == "sftp") { OpenFiles(item); FitFileViewport(); }
                if (page == "sftp" && filePane!.Height < 400) throw new IOException("File browsers collapsed below a usable height.");
                await Task.Delay(page == "session" ? 180 : 60);
                var overlays = new List<(TerminalView View, Image Image)>();
                try
                {
                    if (page == "session") foreach (var view in item.Views)
                    {
                        await view.VerifyDimensionsForSmokeAsync();
                        overlays.Add((view, await view.CaptureForSmokeAsync()));
                    }
                    App.Capture(this, width, height, Path.Combine(folder, $"{page}-{width}.png"));
                    if (page == "sftp" && width == 720)
                    {
                        FileViewport.ScrollToEnd(); await Task.Delay(100);
                        if (FileViewport.VerticalOffset <= 0) throw new IOException("Compact file panes were not scrollable.");
                        App.Capture(this, width, height, Path.Combine(folder, "sftp-720-bottom.png"));
                        FileViewport.ScrollToHome();
                    }
                }
                finally { foreach (var (view, overlay) in overlays) view.ClearCaptureForSmoke(overlay); }
                if (item.Views.Any(view => view.IsDisposed)) throw new IOException("Page navigation disposed a running terminal.");
            }
        }
        Width = 1280; Height = 800; ApplyCompactLayout(1280);
        await SessionActionAsync(item, "disconnect");
        foreach (var id in item.PaneIds) await WaitSessionStateForSmokeAsync(id, "disconnected");
        await SessionActionAsync(item, "reconnect");
        foreach (var id in item.PaneIds) await WaitSessionStateForSmokeAsync(id, "connected");
    }
}
