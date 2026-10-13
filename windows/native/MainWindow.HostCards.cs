using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;

namespace SSHClient.Windows;

public partial class MainWindow
{
    private bool hostGridView = true;

    internal void ShowConnectionForPreview(string state)
    {
        ShowPage("session"); SessionTabs.Items.Clear();
        var stage = new ConnectionStage("deploy@production.internal:22");
        stage.SetMotion(true); stage.SetState(state, state == "Failed" ? "The host did not respond. Reconnect or review its address and port." : null);
        SessionTabs.Items.Add(new TabItem { Header = "Production gateway", Content = stage });
        SessionTabs.SelectedIndex = 0;
    }

    private void HostGrid_Click(object sender, RoutedEventArgs e) => SetHostView(true);
    private void HostList_Click(object sender, RoutedEventArgs e) => SetHostView(false);

    private void SetHostView(bool grid)
    {
        hostGridView = grid;
        Hosts.ItemTemplate = (DataTemplate)Hosts.Resources[grid ? "HostGridTemplate" : "HostListTemplate"];
        Hosts.ItemsPanel = new ItemsPanelTemplate(new FrameworkElementFactory(grid ? typeof(WrapPanel) : typeof(StackPanel)));
        var style = new Style(typeof(ListBoxItem), (Style)FindResource(typeof(ListBoxItem)));
        style.Setters.Add(new Setter(FrameworkElement.WidthProperty, new Binding("ActualWidth") {
            Source = Hosts, Converter = new HostCardWidthConverter(), ConverterParameter = grid
        }));
        style.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(0, 0, grid ? 8 : 0, 8)));
        Hosts.ItemContainerStyle = style;
        HostGridButton.SetResourceReference(Control.BorderBrushProperty, grid ? "AccentCyan" : "Border");
        HostListButton.SetResourceReference(Control.BorderBrushProperty, grid ? "Border" : "AccentCyan");
    }

    private void HostCardDetails_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Host host }) return;
        Hosts.SelectedItem = host; inspectorRequested = true; ApplyCompactLayout(ActualWidth);
    }

    internal void VerifyHostCardsForSmoke()
    {
        var selected = Hosts.SelectedItem;
        SetHostView(false);
        if (Hosts.ItemsPanel.VisualTree.Type != typeof(StackPanel)) throw new InvalidOperationException("List view must use a vertical list.");
        SetHostView(true);
        if (Hosts.ItemsPanel.VisualTree.Type != typeof(WrapPanel) || !ReferenceEquals(selected, Hosts.SelectedItem)) throw new InvalidOperationException("Grid view must preserve the selected host.");
        var stage = new ConnectionStage("fixture@example.internal:22");
        stage.SetMotion(true);
        if (stage.MotionEnabled) throw new InvalidOperationException("Reduced motion must stop connection animation.");
        stage.SetState("Awaiting host approval");
        if (stage.Visibility != Visibility.Visible) throw new InvalidOperationException("Host trust must remain visible during connection.");
        stage.SetState("Connected");
        if (stage.Visibility != Visibility.Collapsed) throw new InvalidOperationException("Connected terminals must dismiss the connection stage.");
        stage.SetState("Failed", "Fixture failure");
        if (stage.Visibility != Visibility.Visible) throw new InvalidOperationException("Connection failures must retain an actionable state.");
    }
}

public sealed class HostCardWidthConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture)
    {
        return HostCardLayout.Width(value is double available ? available : 320, parameter is true);
    }
    public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) => throw new NotSupportedException();
}
