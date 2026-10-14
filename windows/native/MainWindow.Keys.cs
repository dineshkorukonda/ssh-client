using System.IO;
using System.Text.Json;
using System.Windows;

namespace SSHClient.Windows;

public partial class MainWindow
{
    public static bool IsKeyEncrypted(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return false;
        try
        {
            var text = File.ReadAllText(path);
            if (text.Contains("ENCRYPTED", StringComparison.OrdinalIgnoreCase)) return true;
            if (text.Contains("OPENSSH PRIVATE KEY", StringComparison.Ordinal))
            {
                var lines = text.Split('\n')
                    .Select(l => l.Trim())
                    .Where(l => !l.StartsWith("-----") && !string.IsNullOrEmpty(l));
                var base64 = string.Concat(lines);
                var bytes = Convert.FromBase64String(base64);
                var magic = "openssh-key-v1\0"u8;
                if (bytes.Length > magic.Length + 4 && bytes.AsSpan(0, magic.Length).SequenceEqual(magic))
                {
                    int offset = magic.Length;
                    int cipherLen = (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
                    offset += 4;
                    if (cipherLen > 0 && offset + cipherLen <= bytes.Length)
                    {
                        var cipher = System.Text.Encoding.ASCII.GetString(bytes, offset, cipherLen);
                        return !string.Equals(cipher, "none", StringComparison.OrdinalIgnoreCase);
                    }
                }
            }
        }
        catch { }
        return false;
    }

    private static string LocalSshDirectory()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");
        return Directory.Exists(directory) ? directory : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    private void SelectEditorKey(KeyEntry entry)
    {
        var choices = EditorIdentity.ItemsSource?.Cast<KeyEntry>().ToList() ?? [];
        var existing = choices.FirstOrDefault(key => string.Equals(key.PrivateKeyPath, entry.PrivateKeyPath, StringComparison.OrdinalIgnoreCase));
        if (existing == null) { choices.Add(entry); existing = entry; }
        EditorIdentity.ItemsSource = choices;
        EditorIdentity.SelectedItem = existing;
        EditorAuth.SelectedIndex = 0;
        EditorError.Text = "";
    }

    private async Task<KeyEntry?> InspectKeyForImportAsync(string path)
    {
        try {
            var key = (await api!.PostAsync("keys/inspect", new { path })).Deserialize<KeyEntry>(DesktopClient.Json);
            if (key?.Status == "unsupported") { StatusText.Text = key.Details; return null; }
            return key;
        }
        catch (Exception error) { StatusText.Text = error.Message; return null; }
    }

    private async void DiscoverKeys_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () => {
        await RefreshKeysAsync();
        StatusText.Text = "Local .ssh keys refreshed. Private keys remain in their existing files.";
    });

    internal async Task VerifyHostKeyFlowForSmokeAsync(Host fixture)
    {
        var draft = new Host { Port = 22 };
        OpenHostEditor(draft);
        if (EditorUser.Text != "") throw new IOException("New hosts must not assume a root login.");
        EditorHost.Text = fixture.Address; EditorUser.Text = fixture.User;
        await SaveEditorAsync(false);
        if (!EditorError.Text.Contains("Choose an SSH private key")) throw new IOException("An empty key choice must explain how to continue.");
        var selected = (await api!.PostAsync("keys/inspect", new { path = fixture.IdentityFile })).Deserialize<KeyEntry>(DesktopClient.Json)!;
        SelectEditorKey(selected);
        if (EditorIdentity.SelectedItem is not KeyEntry || EditorKeyPath.Text != selected.PrivateKeyPath) throw new IOException("An existing local key could not be selected inline.");
        EditorHost.Text = $"{fixture.User}@{fixture.Address}:{fixture.Port}"; EditorUser.Text = "";
        await SaveEditorAsync(false);
        var saved = (await api.GetAsync("hosts")).Deserialize<List<Host>>(DesktopClient.Json)!.Single(host => host.Id == draft.Id);
        if (saved.Address != fixture.Address || saved.Port != fixture.Port || saved.User != fixture.User || saved.Name != fixture.Address || saved.IdentityFile != selected.PrivateKeyPath)
            throw new IOException("Pasted endpoints, optional naming or inline key selection did not persist.");
        OpenHostEditor(saved.Copy()); EditorAuth.SelectedIndex = 1;
        if (EditorKeySection.Visibility != Visibility.Collapsed) throw new IOException("Password authentication must hide the key chooser.");
        await SaveEditorAsync(false);
        saved = (await api.GetAsync("hosts")).Deserialize<List<Host>>(DesktopClient.Json)!.Single(host => host.Id == draft.Id);
        if (saved.IdentityFile != null) throw new IOException("Password hosts must not retain stale key paths.");
        if (!UpdateCheckButton.IsEnabled || string.IsNullOrEmpty(runningVersion)) throw new IOException("Settings must expose update checking for the running version.");
        if (EditorAdvanced.Foreground is not System.Windows.Media.SolidColorBrush foreground || foreground.Color == System.Windows.Media.Colors.Black) throw new IOException("Advanced options must have a visible header in the dark theme.");
        await api.RequestAsync(System.Net.Http.HttpMethod.Delete, "hosts/" + draft.Id);
        await RefreshAsync();
    }
}
