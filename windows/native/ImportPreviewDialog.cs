using System.Windows;
using System.Windows.Controls;

namespace SSHClient.Windows;

public sealed class ImportPreview
{
    public List<ImportHost> Hosts { get; set; } = [];
    public string[] Unsupported { get; set; } = [];
}
public sealed class ImportHost
{
    public Host Host { get; set; } = new();
    public bool Duplicate { get; set; }
    public bool KeyMissing { get; set; }
}

public sealed class ImportPreviewDialog : Window
{
    private readonly List<(CheckBox Check, string Id)> selections = [];
    public string[] SelectedIds => selections.Where(item => item.Check.IsChecked == true).Select(item => item.Id).ToArray();

    public ImportPreviewDialog(Window owner, ImportPreview preview)
    {
        Owner = owner; Title = "Import hosts"; Width = 570; Height = 500;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Style = (Style)Application.Current.Resources["AppWindow"];
        var root = new DockPanel { Margin = new Thickness(20) };
        var heading = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
        heading.Children.Add(new TextBlock { Text = "Choose hosts to import", FontSize = 22, FontWeight = FontWeights.SemiBold });
        heading.Children.Add(new TextBlock { Text = "Existing hosts are preserved. Missing key files can be changed after import.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });
        if (preview.Unsupported.Length > 0) heading.Children.Add(new TextBlock { Text = "Unsupported SSH settings: " + string.Join(", ", preview.Unsupported) + ". Review these hosts before connecting.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });
        DockPanel.SetDock(heading, Dock.Top); root.Children.Add(heading);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(new Button { Content = "Cancel", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) });
        var import = new Button { Content = "Import selected", IsDefault = true, IsEnabled = preview.Hosts.Any(item => !item.Duplicate) };
        import.Click += (_, _) => { if (SelectedIds.Length > 0) DialogResult = true; };
        buttons.Children.Add(import); DockPanel.SetDock(buttons, Dock.Bottom); root.Children.Add(buttons);
        var list = new StackPanel();
        if (preview.Hosts.Count == 0) list.Children.Add(new TextBlock { Text = "No supported host entries were found in this file.", TextWrapping = TextWrapping.Wrap });
        foreach (var item in preview.Hosts) {
            var text = $"{item.Host.Name}\n{item.Host.Description}";
            if (item.Duplicate) text += "\nAlready saved or duplicated in this file; skipped.";
            if (item.Host.IdentityFile != null) text += "\nKey: " + item.Host.IdentityFile + (item.KeyMissing ? " (file missing)" : "");
            var check = new CheckBox { Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap }, IsChecked = !item.Duplicate, IsEnabled = !item.Duplicate, Margin = new Thickness(0, 0, 0, 16) };
            System.Windows.Automation.AutomationProperties.SetName(check, "Import " + item.Host.Name);
            selections.Add((check, item.Host.Id)); list.Children.Add(check);
        }
        root.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = root;
    }
}
