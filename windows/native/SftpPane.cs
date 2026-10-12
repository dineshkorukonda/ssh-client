using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using Microsoft.Win32;

namespace SSHClient.Windows;

public sealed class SftpPane : UserControl
{
    private readonly DesktopClient api;
    private readonly string session;
    private readonly Window? owner;
    private readonly TextBox path = new() { Text = ".", Margin = new Thickness(0, 0, 8, 0) };
    private readonly ListView entries = new();
    private readonly TextBlock status = new() { Text = "Loading files...", FontSize = 11, Foreground = (System.Windows.Media.Brush)Application.Current.Resources["Muted"], Margin = new Thickness(0, 8, 0, 0) };
    private readonly StackPanel toolbar = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };

    public SftpPane(DesktopClient api, string session, Window? owner = null)
    {
        this.api = api;
        this.session = session;
        this.owner = owner;

        var root = new DockPanel { Margin = new Thickness(12) };

        // Header bar with Path navigation
        var pathBar = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var upBtn = new Button { Content = "▲ Up", Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(0, 0, 6, 0), ToolTip = "Navigate up one directory" };
        upBtn.Click += async (_, _) =>
        {
            var current = path.Text.TrimEnd('/');
            var slash = current.LastIndexOf('/');
            path.Text = slash > 0 ? current[..slash] : "/";
            await GuardAsync(LoadAsync);
        };
        DockPanel.SetDock(upBtn, Dock.Left);
        pathBar.Children.Add(upBtn);

        var refreshBtn = new Button { Content = "↻ Refresh", Padding = new Thickness(8, 4, 8, 4), ToolTip = "Refresh folder contents" };
        refreshBtn.Click += async (_, _) => await GuardAsync(LoadAsync);
        DockPanel.SetDock(refreshBtn, Dock.Right);
        pathBar.Children.Add(refreshBtn);

        path.KeyDown += async (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter)
                await GuardAsync(LoadAsync);
        };
        pathBar.Children.Add(path);
        DockPanel.SetDock(pathBar, Dock.Top);
        root.Children.Add(pathBar);

        // Action Toolbar
        AddButton("Upload", UploadAsync);
        AddButton("Download", DownloadAsync);
        AddButton("Rename", RenameAsync);
        AddButton("Delete", DeleteAsync);
        DockPanel.SetDock(toolbar, Dock.Top);
        root.Children.Add(toolbar);

        // File List View
        var columns = new GridView();
        columns.Columns.Add(new GridViewColumn { Header = "Type", DisplayMemberBinding = new Binding("Icon"), Width = 45 });
        columns.Columns.Add(new GridViewColumn { Header = "Name", DisplayMemberBinding = new Binding("Name"), Width = 220 });
        columns.Columns.Add(new GridViewColumn { Header = "Size", DisplayMemberBinding = new Binding("SizeLabel"), Width = 90 });
        columns.Columns.Add(new GridViewColumn { Header = "Permissions", DisplayMemberBinding = new Binding("Permissions"), Width = 95 });
        entries.View = columns;

        // Drag and drop upload support from Windows Explorer
        entries.AllowDrop = true;
        entries.Drop += async (_, e) =>
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                var files = (string[])e.Data.GetData(DataFormats.FileDrop);
                if (files != null && files.Length > 0)
                {
                    await GuardAsync(async () =>
                    {
                        foreach (var file in files)
                        {
                            if (File.Exists(file))
                            {
                                var remote = RemotePath(System.IO.Path.GetFileName(file));
                                status.Text = $"Uploading {System.IO.Path.GetFileName(file)}...";
                                await api.PostAsync($"files/{session}/upload", new { path = remote, local_path = file });
                            }
                        }
                        await LoadAsync();
                        status.Text = $"Uploaded {files.Length} file(s).";
                    });
                }
            }
        };

        entries.MouseDoubleClick += async (_, _) =>
        {
            if (entries.SelectedItem is FileEntry entry && entry.Type == "directory")
            {
                path.Text = entry.Path;
                await GuardAsync(LoadAsync);
            }
        };

        DockPanel.SetDock(status, Dock.Bottom);
        root.Children.Add(status);

        root.Children.Add(entries);
        Content = root;

        Loaded += async (_, _) => await GuardAsync(LoadAsync);
    }

    private void AddButton(string title, Func<Task> action)
    {
        var button = new Button { Content = title, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(10, 5, 10, 5) };
        button.Click += async (_, _) => await GuardAsync(action);
        toolbar.Children.Add(button);
    }

    private async Task GuardAsync(Func<Task> action)
    {
        toolbar.IsEnabled = false;
        try { await action(); }
        catch (Exception error) { status.Text = error.Message; }
        finally { toolbar.IsEnabled = true; }
    }

    public async Task LoadAsync()
    {
        var result = await api.PostAsync($"files/{session}/list", new { path = path.Text });
        entries.ItemsSource = result.Deserialize<List<FileEntry>>(DesktopClient.Json);
        status.Text = "Double-click folder to open. Drag files here to upload.";
    }

    private string RemotePath(string name) => path.Text.TrimEnd('/') + "/" + name;

    private Window ResolveOwner() => owner ?? Window.GetWindow(this) ?? Application.Current.MainWindow;

    private async Task UploadAsync()
    {
        var picker = new OpenFileDialog();
        var parent = ResolveOwner();
        if (picker.ShowDialog(parent) != true) return;
        var remote = RemotePath(System.IO.Path.GetFileName(picker.FileName));
        if (MessageBox.Show(parent, $"Upload to {remote}? An existing file at this path will be replaced.", "Upload file", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        status.Text = "Uploading...";
        await api.PostAsync($"files/{session}/upload", new { path = remote, local_path = picker.FileName });
        await LoadAsync();
        status.Text = "Upload complete.";
    }

    private async Task DownloadAsync()
    {
        if (entries.SelectedItem is not FileEntry entry || entry.Type == "directory")
        {
            status.Text = "Select a file to download.";
            return;
        }
        var picker = new SaveFileDialog { FileName = entry.Name };
        var parent = ResolveOwner();
        if (picker.ShowDialog(parent) != true) return;
        status.Text = "Downloading...";
        await api.PostAsync($"files/{session}/download", new { path = entry.Path, local_path = picker.FileName });
        status.Text = "Download complete.";
    }

    private async Task RenameAsync()
    {
        if (entries.SelectedItem is not FileEntry entry) return;
        var parent = ResolveOwner();
        var dialog = new FormDialog(parent, "Rename remote file", [new("name", "New name", entry.Name)]);
        if (dialog.ShowDialog() != true) return;
        var name = dialog.Values["name"];
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(['/', '\\']) >= 0 || name is "." or "..")
            throw new ArgumentException("Enter a filename without directory separators.");
        await api.PostAsync($"files/{session}/rename", new { path = entry.Path, new_path = RemotePath(name) });
        await LoadAsync();
    }

    private async Task DeleteAsync()
    {
        if (entries.SelectedItem is not FileEntry entry || entry.Type == "directory") return;
        var parent = ResolveOwner();
        if (MessageBox.Show(parent, "Delete remote file " + entry.Name + "?", "Delete file", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        await api.PostAsync($"files/{session}/delete", new { path = entry.Path });
        await LoadAsync();
    }
}
