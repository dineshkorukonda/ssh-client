using System.Windows;
using System.Windows.Controls;

namespace SSHClient.Windows;

public sealed class StartupWindow : Window
{
    private readonly TextBlock message = new() { Text = "Starting the local SSH service...", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 18) };
    private readonly Button retry = new() { Content = "Retry", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Left };
    public Func<Task>? Retry { get; set; }
    public StartupWindow()
    {
        Title = "ssh-client"; Width = 480; Height = 220; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Style = (Style)Application.Current.Resources["AppWindow"];
        var panel = new StackPanel { Margin = new Thickness(28) };
        panel.Children.Add(new TextBlock { Text = "ssh-client", FontSize = 24, FontWeight = FontWeights.SemiBold });
        panel.Children.Add(message); panel.Children.Add(retry); Content = panel;
        retry.Click += async (_, _) => { retry.Visibility = Visibility.Collapsed; message.Text = "Starting the local SSH service..."; if (Retry != null) await Retry(); };
    }
    public void Fail(string reason) { message.Text = "The local service could not start. " + reason; retry.Visibility = Visibility.Visible; }
}
