using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
namespace SSHClient.Windows;

public sealed record Field(string Key, string Label, string Value = "", bool Secret = false, bool File = false);
public sealed class FormDialog : Window
{
    private readonly Dictionary<string, Func<string>> readers = new();
    public Dictionary<string, string> Values => readers.ToDictionary(pair => pair.Key, pair => pair.Value());
    public FormDialog(Window owner, string title, IEnumerable<Field> fields, string action = "Save", string? explanation = null)
    {
        Owner = owner; Title = title; Width = 480; SizeToContent = SizeToContent.Height;
        MaxHeight = 850; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new DockPanel { Margin = new Thickness(24) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        var save = new Button { Content = action, IsDefault = true };
        save.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(cancel); buttons.Children.Add(save);
        DockPanel.SetDock(buttons, Dock.Bottom); root.Children.Add(buttons);
        var contents = new StackPanel();
        if (explanation != null) contents.Children.Add(new TextBlock { Text = explanation, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 18) });
        foreach (var field in fields)
        {
            contents.Children.Add(new TextBlock { Text = field.Label });
            if (field.Secret)
            {
                var input = new PasswordBox { Password = field.Value };
                contents.Children.Add(input); readers[field.Key] = () => input.Password;
            }
            else
            {
                var input = new TextBox { Text = field.Value };
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
        Content = root;
    }
}
