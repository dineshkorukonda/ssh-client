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
    public FormDialog(Window owner, string title, IEnumerable<Field> fields, string action = "Save", string? explanation = null)
    {
        Owner = owner; Title = title; Width = 480; SizeToContent = SizeToContent.Height;
        Style = (Style)Application.Current.Resources["AppWindow"];
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        MaxHeight = Math.Min(850, SystemParameters.WorkArea.Height - 70); WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new DockPanel { Margin = new Thickness(28) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Margin = new Thickness(0, 0, 10, 0) };
        var save = new Button { Content = action, IsDefault = true, Style = (Style)Application.Current.Resources["PrimaryButton"] };
        save.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(cancel); buttons.Children.Add(save);
        DockPanel.SetDock(buttons, Dock.Bottom); root.Children.Add(buttons);
        var contents = new StackPanel();
        var heading = new TextBlock { Text = title, FontSize = 23, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 18) };
        heading.MouseLeftButtonDown += (_, args) => { if (args.LeftButton == System.Windows.Input.MouseButtonState.Pressed) DragMove(); };
        contents.Children.Add(heading);
        if (explanation != null) contents.Children.Add(new TextBlock { Text = explanation, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 18) });
        foreach (var field in fields)
        {
            contents.Children.Add(new TextBlock { Text = field.Label });
            if (field.Options != null)
            {
                var input = new ComboBox { ItemsSource = field.Options, SelectedItem = field.Value, Margin = new Thickness(0, 6, 0, 16), Padding = new Thickness(11, 9, 11, 9) };
                contents.Children.Add(input); readers[field.Key] = () => input.SelectedItem?.ToString() ?? field.Options[0];
            }
            else if (field.Secret)
            {
                var input = new PasswordBox { Password = field.Value };
                contents.Children.Add(input); readers[field.Key] = () => input.Password;
            }
            else
            {
                var input = new TextBox { Text = field.Value };
                if (field.Multiline) { input.AcceptsReturn = true; input.TextWrapping = TextWrapping.Wrap; input.MinHeight = 72; }
                if (field.File)
                {
                    var row = new DockPanel();
                    var browse = new Button { Content = "Browse", Margin = new Thickness(8, 4, 0, 12) };
                    browse.Click += (_, _) => { var picker = new OpenFileDialog(); if (picker.ShowDialog(this) == true) input.Text = picker.FileName; };
                    DockPanel.SetDock(browse, Dock.Right); row.Children.Add(browse); row.Children.Add(input); contents.Children.Add(row);
                }
                else contents.Children.Add(input);
                readers[field.Key] = () => input.Text;
            }
        }
        root.Children.Add(new ScrollViewer { Content = contents, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = new Border { Background = (Brush)Application.Current.Resources["Surface"], BorderBrush = (Brush)Application.Current.Resources["Border"], BorderThickness = new Thickness(1), Child = root };
    }
}
