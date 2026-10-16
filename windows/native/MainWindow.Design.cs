using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace SSHClient.Windows;

public partial class MainWindow
{
    private bool? sidebarCollapsed;
    private bool selectingSessionContext;

    private void CollapseSidebar_Click(object sender, RoutedEventArgs e)
    {
        sidebarCollapsed = SidebarColumn.Width.Value > 100;
        ApplyCompactLayout(ActualWidth);
    }

    private void ApplyWorkbenchLayout(double width)
    {
        if (SidebarColumn == null) return;
        var collapsed = sidebarCollapsed ?? width < 1000;
        SidebarColumn.Width = new GridLength(collapsed ? 60 : 204);
        foreach (var label in new FrameworkElement[] { WorkspaceLabel, NavDashboardLabel, NavHostsLabel, NavSftpLabel, NavKeysLabel, NavSettingsLabel, SidebarHostBadge, SidebarKeysBadge, SessionsLabel })
            label.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        SidebarSessionsList.ItemTemplate = (DataTemplate)FindResource(collapsed ? "CollapsedSessionRow" : "SessionRow");
        CollapseSidebarButton.ToolTip = collapsed ? "Expand sidebar (Ctrl+Shift+B)" : "Collapse sidebar (Ctrl+Shift+B)";
        var narrow = width < 1050;
        Grid.SetColumn(FavoritesSection, narrow ? 0 : 2);
        Grid.SetRow(FavoritesSection, narrow ? 1 : 0);
        FavoritesSection.Margin = narrow ? new Thickness(0, 20, 0, 0) : new Thickness(0);
        OverviewColumns.ColumnDefinitions[1].Width = new GridLength(narrow ? 0 : 20);
        OverviewColumns.ColumnDefinitions[2].Width = narrow ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        SettingsNavColumn.Width = new GridLength(width < 900 ? 0 : 150);
        SettingsNav.Visibility = width < 900 ? Visibility.Collapsed : Visibility.Visible;
        RecoveryPanel.Margin = new Thickness(collapsed ? 72 : 216, 12, 12, 0);
    }

    private void SettingsSection_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string name } && FindName(name) is FrameworkElement section)
        {
            section.BringIntoView();
            foreach (var button in SettingsNav.Children.OfType<Button>())
                button.SetResourceReference(Control.BackgroundProperty, ReferenceEquals(button, sender) ? "NavActiveBg" : "Sidebar");
        }
    }

    private async void QuickConnectInput_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        var input = QuickConnectInput.Text.Trim();
        if (input.Length > 0) await GuardAsync(() => HandleConnectQueryAsync(input));
    }

    private void OverviewSession_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (OverviewSessionsList.SelectedItem is not TerminalTabItem item) return;
        SidebarSessionsList.SelectedItem = item;
        ShowPage("session");
        OverviewSessionsList.SelectedItem = null;
    }

    private async void SidebarSessionAction_Click(object sender, RoutedEventArgs e)
    {
        if (SidebarSessionsList.SelectedItem is not TerminalTabItem item || sender is not MenuItem { Tag: string action }) return;
        if (action == "files") { OpenFiles(item); return; }
        if (action == "close")
        {
            var tab = SessionTabs.Items.OfType<TabItem>().FirstOrDefault(candidate => candidate.Tag == item);
            if (tab != null) await GuardAsync(() => CloseSessionTabAsync(tab));
        }
        else await GuardAsync(() => SessionActionAsync(item, action));
    }

    private void SidebarSession_RightClick(object sender, MouseButtonEventArgs e)
    {
        var source = e.OriginalSource as DependencyObject;
        while (source != null && source is not ListBoxItem)
            source = VisualTreeHelper.GetParent(source);
        if (source is ListBoxItem row)
        {
            selectingSessionContext = true;
            try { row.IsSelected = true; }
            finally { selectingSessionContext = false; }
        }
    }

    internal void ToggleSidebarFromTerminal() => CollapseSidebar_Click(this, new RoutedEventArgs());

    private void FileViewport_SizeChanged(object sender, SizeChangedEventArgs e) => FitFileViewport();

    private void FitFileViewport()
    {
        if (filePane != null && FileViewport != null)
            filePane.Height = Math.Max(FileViewport.ActualHeight, FileViewport.ActualWidth < 760 ? 720 : 460);
    }

    private void FocusSelectedTerminal()
    {
        if (!selectingSessionContext && currentPage == "session" && SessionTabs.SelectedItem is TabItem { Tag: TerminalTabItem item })
            Dispatcher.BeginInvoke(() => (item.ActiveView ?? item.Views.FirstOrDefault())?.FocusTerminal(), System.Windows.Threading.DispatcherPriority.Input);
    }
}
