using System.Windows;
using System.Windows.Controls;

namespace SSHClient.Windows;

public partial class MainWindow
{
    private bool? inspectorRequested;
    private void Window_SizeChanged(object sender, SizeChangedEventArgs e)
        => ApplyCompactLayout(ActualWidth);

    private void ApplyCompactLayout(double width)
    {
        if (InspectorColumn == null) return;
        ApplyWorkbenchLayout(width);
        var visible = inspectorRequested ?? false;
        var overlay = width < 1100;
        InspectorColumn.Width = new GridLength(visible && !overlay ? 300 : 0);
        Grid.SetColumn(HostInspector, overlay ? 0 : 1);
        HostInspector.HorizontalAlignment = overlay ? HorizontalAlignment.Right : HorizontalAlignment.Stretch;
        HostInspector.Width = overlay ? 300 : double.NaN;
        Panel.SetZIndex(HostInspector, 2);
        HostInspector.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        PalettePopup.Width = Math.Max(260, Math.Min(420, width - 200));
        DashboardCards.Columns = width < 1100 ? 2 : 4;
        DashboardCards.Visibility = Visibility.Visible;
    }
    private void ToggleInspector_Click(object sender, RoutedEventArgs e)
    {
        inspectorRequested = !(inspectorRequested ?? false);
        ApplyCompactLayout(ActualWidth);
    }
    internal void SetPreviewWidth(double width) => ApplyCompactLayout(width);
    private void HostSort_Changed(object sender, SelectionChangedEventArgs e) => FilterHosts();
    private async void RefreshDiagnostics_Click(object sender, RoutedEventArgs e) => await GuardAsync(RefreshDiagnosticsAsync);
    private async Task RefreshDiagnosticsAsync()
    {
        if (api == null) { BackendReadyText.Text = isPreview ? "Preview" : "Starting"; return; }
        var health = await api.GetAsync("health");
        var ready = health.GetProperty("ready").GetBoolean();
        var version = health.GetProperty("version").GetString();
        runningVersion = version ?? "";
        UpdateCheckButton.IsEnabled = !string.IsNullOrEmpty(runningVersion) && !updating;
        if (!updating && availableUpdate == null) UpdateStatus.Text = $"Installed version: v{version}. Updates replace the app in place.";
        AppVersionLabel.Text = "v" + version;
        BackendReadyText.Text = ready ? "Ready" : "Starting";
        DaemonStatusText.Text = ready ? "Local SSH service ready" : "Local SSH service starting";
        DaemonUptimeText.Text = $"Version {version} / desktop API {health.GetProperty("api_version")}\nHosts, keys and preferences are stored locally.";
    }

    internal void VerifyAccessibilityForSmoke()
    {
        VerifyHostCardsForSmoke();
        ApplyCompactLayout(720);
        if (HostInspector.Visibility != Visibility.Collapsed || InspectorColumn.Width.Value != 0) throw new InvalidOperationException("Compact host layout did not release inspector space.");
        if (System.Windows.Automation.AutomationProperties.GetName(EditorHost) != "Server address") throw new InvalidOperationException("Host input lacks its accessible name.");
        if (ThemeManager.CurrentTheme == AppTheme.Light && !SystemParameters.HighContrast) {
            var muted = (System.Windows.Media.SolidColorBrush)Application.Current.Resources["MutedSubtle"];
            if (muted.Color.R > 120) throw new InvalidOperationException("Light theme muted labels lost contrast.");
        }
    }
}
