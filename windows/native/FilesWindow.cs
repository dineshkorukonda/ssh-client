using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
namespace SSHClient.Windows;

public sealed class FilesWindow : Window
{
    private readonly DesktopClient api;
    private readonly string session;
    private readonly TextBox path = new() { Text = "." };
    private readonly ListBox entries = new();
    private readonly TextBlock status = new() { Text = "Loading...", Margin = new Thickness(0, 12, 0, 0) };
    private readonly StackPanel toolbar = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
    public FilesWindow(DesktopClient api, string session)
    {
        this.api = api; this.session = session; Title = "Remote files"; Width = 760; Height = 540;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new DockPanel { Margin = new Thickness(24) };
        DockPanel.SetDock(path, Dock.Top); root.Children.Add(path);
        DockPanel.SetDock(toolbar, Dock.Top); root.Children.Add(toolbar);
        AddButton("Open", LoadAsync); AddButton("Up", () => { var current = path.Text.TrimEnd('/'); var slash = current.LastIndexOf('/'); path.Text = slash > 0 ? current[..slash] : "/"; return LoadAsync(); });
        AddButton("Upload", UploadAsync); AddButton("Download", DownloadAsync); AddButton("Rename", RenameAsync); AddButton("Delete", DeleteAsync);
        DockPanel.SetDock(status, Dock.Bottom); root.Children.Add(status);
        root.Children.Add(entries); Content = root;
        entries.MouseDoubleClick += async (_, _) =>
        {
            if (entries.SelectedItem is FileEntry entry && entry.Type == "directory") { path.Text = entry.Path; await GuardAsync(LoadAsync); }
        };
        Loaded += async (_, _) => await GuardAsync(LoadAsync);
    }
    private void AddButton(string title, Func<Task> action)
    {
        var button = new Button { Content = title }; button.Click += async (_, _) => await GuardAsync(action); toolbar.Children.Add(button);
    }
    private async Task GuardAsync(Func<Task> action)
    {
        toolbar.IsEnabled = false;
        try { await action(); }
        catch (Exception error) { status.Text = error.Message; }
        finally { toolbar.IsEnabled = true; }
    }
    private async Task LoadAsync()
    {
        var result = await api.PostAsync($"files/{session}/list", new { path = path.Text });
        entries.ItemsSource = result.Deserialize<List<FileEntry>>(DesktopClient.Json);
        status.Text = "Double-click a directory to open it.";
    }
    private string RemotePath(string name) => path.Text.TrimEnd('/') + "/" + name;
    private async Task UploadAsync()
    {
        var picker = new OpenFileDialog(); if (picker.ShowDialog(this) != true) return;
        var remote = RemotePath(System.IO.Path.GetFileName(picker.FileName));
        if (MessageBox.Show(this, $"Upload to {remote}? An existing file at this path will be replaced.", "Upload file", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        status.Text = "Uploading...";
        await api.PostAsync($"files/{session}/upload", new { path = remote, local_path = picker.FileName });
        await LoadAsync(); status.Text = "Upload complete.";
    }
    private async Task DownloadAsync()
    {
        if (entries.SelectedItem is not FileEntry entry || entry.Type == "directory") return;
        var picker = new SaveFileDialog { FileName = entry.Name }; if (picker.ShowDialog(this) != true) return;
        status.Text = "Downloading...";
        await api.PostAsync($"files/{session}/download", new { path = entry.Path, local_path = picker.FileName });
        status.Text = "Download complete.";
    }
    private async Task RenameAsync()
    {
        if (entries.SelectedItem is not FileEntry entry) return;
        var dialog = new FormDialog(this, "Rename remote file", [new("name", "New name", entry.Name)]);
        if (dialog.ShowDialog() != true) return;
        var name = dialog.Values["name"];
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(['/', '\\']) >= 0 || name is "." or "..") throw new ArgumentException("Enter a filename without directory separators.");
        await api.PostAsync($"files/{session}/rename", new { path = entry.Path, new_path = RemotePath(name) }); await LoadAsync();
    }
    private async Task DeleteAsync()
    {
        if (entries.SelectedItem is not FileEntry entry || entry.Type == "directory") return;
        if (MessageBox.Show(this, "Delete remote file " + entry.Name + "?", "Delete file", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        await api.PostAsync($"files/{session}/delete", new { path = entry.Path }); await LoadAsync();
    }
    public sealed class FileEntry
    {
        public string Name { get; set; } = "";
        public string Path { get; set; } = "";
        public string Type { get; set; } = "";
        public long Size { get; set; }
        public string Permissions { get; set; } = "";
        public override string ToString() => $"{(Type == "directory" ? "DIR " : "FILE")}   {Name}   {Size:N0} bytes   {Permissions}";
    }
}
