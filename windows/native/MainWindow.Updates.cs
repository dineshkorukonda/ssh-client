using System.Windows;

namespace SSHClient.Windows;

public partial class MainWindow
{
    private NativeUpdate? availableUpdate;
    private string runningVersion = "";
    private bool updating;
    private readonly CancellationTokenSource updateCancellation = new();

    private async void CheckUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (updating || string.IsNullOrEmpty(runningVersion)) return;
        updating = true; UpdateCheckButton.IsEnabled = false; UpdateInstallButton.IsEnabled = false;
        UpdateStatus.Text = "Checking for updates...";
        try {
            availableUpdate = await NativeUpdater.CheckAsync(runningVersion, AppContext.BaseDirectory, updateCancellation.Token);
            UpdateStatus.Text = availableUpdate == null ? $"You are up to date (v{runningVersion})." : $"v{availableUpdate.Version} is available. Your saved hosts and key files will be preserved.";
            UpdateInstallButton.Visibility = availableUpdate == null ? Visibility.Collapsed : Visibility.Visible;
            UpdateInstallButton.IsEnabled = availableUpdate != null;
        } catch (OperationCanceledException) { if (!updateCancellation.IsCancellationRequested) UpdateStatus.Text = "Update check timed out. Try again."; }
        catch (Exception error) { UpdateStatus.Text = "Could not check for updates: " + error.Message; }
        finally { updating = false; UpdateCheckButton.IsEnabled = !string.IsNullOrEmpty(runningVersion); }
    }

    private async void InstallUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (updating || availableUpdate == null || !ConfirmDiscard()) return;
        if (MessageBox.Show(this, "Install the update and restart ssh-client? Active SSH sessions and file transfers will close. Saved hosts and existing key files are preserved.", "Update ssh-client", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        updating = true; UpdateCheckButton.IsEnabled = false; UpdateInstallButton.IsEnabled = false;
        UpdateProgress.Visibility = Visibility.Visible;
        try {
            var update = availableUpdate;
            var payload = await NativeUpdater.StageAsync(update, new Progress<int>(percent => {
                UpdateProgress.Value = percent; UpdateStatus.Text = $"Downloading v{update.Version}: {percent}%";
            }), updateCancellation.Token);
            if (!ConfirmDiscard()) { UpdateStatus.Text = "Update downloaded. Your unsaved host changes are still open."; return; }
            updateCancellation.Token.ThrowIfCancellationRequested();
            UpdateStatus.Text = "Installing update and restarting...";
            NativeUpdater.LaunchApply(payload, AppContext.BaseDirectory, update.Installed);
            Application.Current.Shutdown();
        } catch (OperationCanceledException) { }
        catch (Exception error) { UpdateStatus.Text = "Update failed: " + error.Message + " Your current app is still installed."; }
        finally { updating = false; UpdateProgress.Visibility = Visibility.Collapsed; UpdateCheckButton.IsEnabled = true; UpdateInstallButton.IsEnabled = true; }
    }
}
