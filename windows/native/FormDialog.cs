using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace SSHClient.Windows;

public sealed record Field(string Key, string Label, string Value = "", bool Secret = false, bool File = false, string[]? Options = null, bool Multiline = false);

public sealed class FormDialog : Window
{
    private readonly Dictionary<string, Func<string>> readers = new();
    public Dictionary<string, string> Values => readers.ToDictionary(pair => pair.Key, pair => pair.Value());

    public FormDialog(Window? owner, string title, IEnumerable<Field> fields, string action = "Save", string? explanation = null)
    {
        if (owner != null && new System.Windows.Interop.WindowInteropHelper(owner).Handle != IntPtr.Zero)
        {
            try { Owner = owner; }
            catch (InvalidOperationException) { }
        }
        Title = title;
        Width = 480;
        SizeToContent = SizeToContent.Height;
        Style = (Style)Application.Current.Resources["AppWindow"];
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        MaxHeight = Math.Min(850, SystemParameters.WorkArea.Height - 70);
        WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;

        var root = new DockPanel { Margin = new Thickness(28) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Margin = new Thickness(0, 0, 10, 0) };
        var save = new Button { Content = action, IsDefault = true, Style = (Style)Application.Current.Resources["PrimaryButton"] };
        save.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(cancel);
        buttons.Children.Add(save);
        DockPanel.SetDock(buttons, Dock.Bottom);
        root.Children.Add(buttons);

        var contents = new StackPanel();
        var heading = new TextBlock { Text = title, FontSize = 23, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 18) };
        heading.MouseLeftButtonDown += (_, args) => { if (args.LeftButton == System.Windows.Input.MouseButtonState.Pressed) DragMove(); };
        contents.Children.Add(heading);
        if (explanation != null) contents.Children.Add(new TextBlock { Text = explanation, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 18) });

        foreach (var field in fields)
        {
            var label = new TextBlock { Text = field.Label, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 6) };
            contents.Children.Add(label);
            if (field.Options != null)
            {
                var combo = new ComboBox { ItemsSource = field.Options, SelectedItem = field.Value != "" ? field.Value : field.Options.FirstOrDefault(), Margin = new Thickness(0, 0, 0, 14) };
                contents.Children.Add(combo);
                readers[field.Key] = () => combo.SelectedItem?.ToString() ?? "";
            }
            else if (field.Secret)
            {
                var pass = new PasswordBox { Password = field.Value, Margin = new Thickness(0, 0, 0, 14) };
                contents.Children.Add(pass);
                readers[field.Key] = () => pass.Password;
            }
            else if (field.File)
            {
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
                var browse = new Button { Content = "Browse", Margin = new Thickness(8, 0, 0, 0), Style = (Style)Application.Current.Resources["PrimaryButton"] };
                var text = new TextBox { Text = field.Value };
                browse.Click += (_, _) =>
                {
                    var picker = new OpenFileDialog { Title = "Select " + field.Label };
                    if (picker.ShowDialog(this) == true) text.Text = picker.FileName;
                };
                DockPanel.SetDock(browse, Dock.Right);
                row.Children.Add(browse);
                row.Children.Add(text);
                contents.Children.Add(row);
                readers[field.Key] = () => text.Text;
            }
            else if (field.Multiline)
            {
                var text = new TextBox { Text = field.Value, Height = 90, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) };
                contents.Children.Add(text);
                readers[field.Key] = () => text.Text;
            }
            else
            {
                var text = new TextBox { Text = field.Value, Margin = new Thickness(0, 0, 0, 14) };
                contents.Children.Add(text);
                readers[field.Key] = () => text.Text;
            }
        }

        root.Children.Add(new ScrollViewer { Content = contents, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = new Border { Background = (Brush)Application.Current.Resources["Surface"], BorderBrush = (Brush)Application.Current.Resources["Border"], BorderThickness = new Thickness(1), Child = root };
    }
}
