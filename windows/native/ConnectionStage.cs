using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SSHClient.Windows;

public sealed class ConnectionStage : Border
{
    private readonly TextBlock heading = new() { FontSize = 21, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center };
    private readonly TextBlock detail = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 10, 0, 18) };
    private readonly ProgressBar progress = new() { Height = 3, Width = 210, IsIndeterminate = true };
    private readonly Button retry = new() { Content = "Reconnect", HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 24, 0, 0) };
    public bool MotionEnabled { get; private set; }
    public string State { get; private set; } = "Connecting";

    public ConnectionStage(string? host, Func<Task>? reconnect = null)
    {
        SetResourceReference(BackgroundProperty, "Surface");
        var panel = new StackPanel { MaxWidth = 430, Margin = new Thickness(28), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var identity = new TextBlock { Text = host ?? "SSH session", TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 24), FontSize = 12 };
        identity.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); panel.Children.Add(identity);
        heading.SetResourceReference(TextBlock.ForegroundProperty, "Text"); panel.Children.Add(heading);
        detail.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); panel.Children.Add(detail);
        var timeline = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var label in new[] { "SSH", ">_" }) {
            if (label == ">_") { progress.SetResourceReference(Control.ForegroundProperty, "AccentCyan"); progress.SetResourceReference(Control.BackgroundProperty, "Border"); timeline.Children.Add(progress); }
            var mark = new TextBlock { Text = label, FontFamily = new FontFamily("Consolas"), FontSize = 18, FontWeight = FontWeights.Bold, Margin = new Thickness(16, 8, 16, 8), VerticalAlignment = VerticalAlignment.Center };
            mark.SetResourceReference(TextBlock.ForegroundProperty, "AccentCyan"); timeline.Children.Add(mark);
        }
        panel.Children.Add(timeline);
        retry.Click += async (_, _) => {
            if (reconnect == null) return;
            retry.IsEnabled = false;
            try { SetState("Connecting"); await reconnect(); }
            catch (Exception error) { SetState("Failed", error.Message); }
            finally { retry.IsEnabled = true; }
        };
        panel.Children.Add(retry); Child = panel;
        SetMotion(false); SetState("Connecting");
    }

    public void SetMotion(bool reduced)
    {
        MotionEnabled = !reduced && SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;
        progress.IsIndeterminate = MotionEnabled && State == "Connecting";
    }

    public void SetState(string state, string? error = null)
    {
        State = state;
        Visibility = state == "Connected" ? Visibility.Collapsed : Visibility.Visible;
        heading.Text = state switch { "Connecting" => "Connecting to your host", "Awaiting host approval" => "Verify server identity", "Awaiting authentication" => "Authentication required", "Disconnected" => "Session disconnected", _ => "Connection unavailable" };
        detail.Text = error ?? (state switch { "Connecting" => "Opening a secure SSH session.", "Awaiting host approval" => "Review the server fingerprint to continue.", "Awaiting authentication" => "Complete the authentication prompt to continue.", "Disconnected" => "Reconnect when you are ready.", _ => "Reconnect or edit this host's connection settings." });
        retry.Visibility = state is "Connecting" or "Awaiting host approval" or "Awaiting authentication" or "Connected" ? Visibility.Collapsed : Visibility.Visible;
        progress.IsIndeterminate = MotionEnabled && state == "Connecting";
        progress.Value = state == "Connected" ? 100 : 0;
    }
}
