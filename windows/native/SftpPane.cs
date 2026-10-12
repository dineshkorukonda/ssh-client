using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;
using Microsoft.Win32;

namespace SSHClient.Windows;

public sealed class SftpPane : UserControl, IDisposable
{
    private readonly DesktopClient api;
    private readonly string session;
    private readonly Window? owner;
    private readonly TextBox path = new() { Text = ".", Margin = new Thickness(0, 0, 8, 0) };
    private readonly ListView entries = new();
    private readonly TextBlock status = new() { Text = "Loading files...", FontSize = 11, Foreground = (System.Windows.Media.Brush)Application.Current.Resources["Muted"], Margin = new Thickness(0, 8, 0, 0) };
    private readonly WrapPanel toolbar = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };

    private readonly TextBox localPath = new() { Text = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) };
    private readonly ListView localEntries = new();
    private readonly ListView transferEntries = new() { MaxHeight = 130 };
    private readonly CheckBox showHidden = new() { Content = "Show hidden files", Margin = new Thickness(8) };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly CancellationTokenSource stop = new();
    private List<FileEntry> files = [];
    private bool polling, disposed;
    private string completedIds = "";

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
        AddButton("New folder", NewFolderAsync);
        AddButton("Upload selected local file", () => localEntries.SelectedItem is FileEntry { Type: not "directory" } entry ? QueueUploadsAsync([entry.Path]) : Task.CompletedTask);
        toolbar.Children.Add(showHidden);
        showHidden.Checked += async (_, _) => await GuardAsync(LoadAsync);
        showHidden.Unchecked += async (_, _) => await GuardAsync(LoadAsync);
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
        entries.Drop += async (_, e) => {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) await GuardAsync(() => QueueUploadsAsync(paths));
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

        var queuePanel = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        queuePanel.Children.Add(new TextBlock { Text = "Transfers", FontWeight = FontWeights.SemiBold });
        var txColumns = new GridView();
        foreach (var field in new[] { "Filename", "Direction", "Status", "Progress", "BytesTransferred", "Error" })
            txColumns.Columns.Add(new GridViewColumn { Header = field, DisplayMemberBinding = new Binding(field), Width = field == "Filename" ? 180 : 105 });
        transferEntries.View = txColumns;
        queuePanel.Children.Add(transferEntries);
        var txActions = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var action in new[] { "cancel", "retry" }) {
            var button = new Button { Content = action == "cancel" ? "Cancel transfer" : "Retry transfer", Margin = new Thickness(0, 6, 8, 0) };
            button.Click += async (_, _) => await GuardAsync(async () => {
                if (transferEntries.SelectedItem is not TransferEntry entry) { status.Text = "Select a transfer first."; return; }
                if (action == "retry" && entry.Status is not ("failed" or "cancelled")) { status.Text = "Only failed or cancelled transfers can be retried."; return; }
                await api.PostAsync($"transfers/{entry.Id}/{action}", new { }, stop.Token); await RefreshTransfersAsync();
            });
            txActions.Children.Add(button);
        }
        queuePanel.Children.Add(txActions); DockPanel.SetDock(queuePanel, Dock.Bottom); root.Children.Add(queuePanel);
        var localPanel = new DockPanel { Margin = new Thickness(0,0,12,0) };
        var localHeader = new TextBlock { Text = "Local", FontWeight = FontWeights.SemiBold }; DockPanel.SetDock(localHeader, Dock.Top); localPanel.Children.Add(localHeader);
        var localBar = new DockPanel { Margin = new Thickness(0,6,0,8) };
        var upLocal = new Button { Content = "Up", Margin = new Thickness(0,0,8,0) };
        upLocal.Click += (_, _) => { localPath.Text = Directory.GetParent(Path.GetFullPath(localPath.Text))?.FullName ?? localPath.Text; LoadLocal(); };
        DockPanel.SetDock(upLocal, Dock.Left); localBar.Children.Add(upLocal); localBar.Children.Add(localPath);
        localPath.KeyDown += (_, e) => { if(e.Key == System.Windows.Input.Key.Enter) { try { LoadLocal(); } catch(Exception error) { status.Text = error.Message; } } };
        DockPanel.SetDock(localBar, Dock.Top); localPanel.Children.Add(localBar);
        var localColumns = new GridView(); localColumns.Columns.Add(new GridViewColumn { Header = "Name", DisplayMemberBinding = new Binding("Name"), Width = 220 }); localColumns.Columns.Add(new GridViewColumn { Header = "Size", DisplayMemberBinding = new Binding("SizeLabel"), Width = 90 }); localEntries.View = localColumns;
        localEntries.MouseDoubleClick += (_, _) => { if(localEntries.SelectedItem is FileEntry { Type: "directory" } entry) { localPath.Text = entry.Path; LoadLocal(); } };
        localPanel.Children.Add(localEntries);
        var browsers = new Grid(); browsers.ColumnDefinitions.Add(new()); browsers.ColumnDefinitions.Add(new() { Width = new GridLength(6) }); browsers.ColumnDefinitions.Add(new());
        var splitter = new GridSplitter { Width = 6, HorizontalAlignment = HorizontalAlignment.Stretch, ResizeDirection = GridResizeDirection.Columns, ResizeBehavior = GridResizeBehavior.PreviousAndNext }; Grid.SetColumn(splitter,1); browsers.Children.Add(splitter);
        browsers.Children.Add(localPanel); Grid.SetColumn(entries,2); browsers.Children.Add(entries); root.Children.Add(browsers);
        timer.Tick += async (_, _) => { if (polling || disposed) return; polling = true; try { await RefreshTransfersAsync(); } catch (OperationCanceledException) { } catch (Exception error) { status.Text = error.Message; } finally { polling = false; } };
        Content = root;

        Loaded += async (_, _) => { if (disposed) return; timer.Start(); await GuardAsync(LoadAsync); };
    }

    private void AddButton(string title, Func<Task> action)
    {
        var button = new Button { Content = title, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(10, 5, 10, 5) };
        button.Click += async (_, _) => await GuardAsync(action);
        toolbar.Children.Add(button);
    }

    private async Task GuardAsync(Func<Task> action)
    {
        if (disposed || !toolbar.IsEnabled) return;
        toolbar.IsEnabled = false;
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception error) { status.Text = error.Message; }
        finally { toolbar.IsEnabled = true; }
    }

    public async Task LoadAsync()
    {
        var result = await api.PostAsync($"files/{session}/list", new { path = path.Text });
        files = result.Deserialize<List<FileEntry>>(DesktopClient.Json) ?? [];
        entries.ItemsSource = files.Where(file => showHidden.IsChecked == true || !file.Name.StartsWith('.')).ToArray();
        LoadLocal();
        status.Text = "Double-click folder to open. Drag files here to upload.";
    }

    private string RemotePath(string name) => path.Text.TrimEnd('/') + "/" + name;

    private Window ResolveOwner() => owner ?? Window.GetWindow(this) ?? Application.Current.MainWindow;

    private async Task UploadAsync()
    {
        var picker = new OpenFileDialog { Multiselect = true };
        if (picker.ShowDialog(ResolveOwner()) == true) await QueueUploadsAsync(picker.FileNames);
    }

    private async Task QueueUploadsAsync(IEnumerable<string> paths)
    {
        await LoadAsync();
        var count = 0;
        foreach (var file in paths) {
            if (!File.Exists(file)) { status.Text = "Folder uploads are not supported; select files."; continue; }
            var name = Path.GetFileName(file);
            if (files.Any(entry => entry.Name == name) && MessageBox.Show(ResolveOwner(), $"Replace remote file {name}?", "Upload conflict", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes) continue;
            await api.PostAsync($"transfers/{session}/upload", new { path = RemotePath(name), local_path = file }, stop.Token); count++;
        }
        status.Text = $"Queued {count} file(s). Progress is shown in Transfers.";
        await RefreshTransfersAsync();
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
        await api.PostAsync($"transfers/{session}/download", new { path = entry.Path, local_path = picker.FileName }, stop.Token);
        status.Text = "Download queued.";
        await RefreshTransfersAsync();
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
    private void LoadLocal()
    {
        localEntries.ItemsSource = new DirectoryInfo(localPath.Text).EnumerateFileSystemInfos()
            .Where(file => showHidden.IsChecked == true || (!file.Name.StartsWith('.') && (file.Attributes & FileAttributes.Hidden) == 0))
            .Select(file => new FileEntry { Name = file.Name, Path = file.FullName, Type = file is DirectoryInfo ? "directory" : "regular", Size = file is FileInfo info ? info.Length : 0 }).ToArray();
    }
    private async Task NewFolderAsync()
    {
        var dialog = new FormDialog(ResolveOwner(), "New remote folder", [new("name", "Folder name")]);
        if (dialog.ShowDialog() != true) return; var name = dialog.Values["name"];
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(['/', '\\']) >= 0 || name is "." or "..") throw new ArgumentException("Enter a folder name without directory separators.");
        await api.PostAsync($"files/{session}/mkdir", new { path = RemotePath(name) }, stop.Token); await LoadAsync();
    }
    private async Task RefreshTransfersAsync()
    {
        var selected = (transferEntries.SelectedItem as TransferEntry)?.Id;
        var list = (await api.GetAsync("transfers", stop.Token)).Deserialize<List<TransferEntry>>(DesktopClient.Json)?.Where(entry => entry.SessionId == session).ToArray() ?? [];
        transferEntries.ItemsSource = list; transferEntries.SelectedItem = list.FirstOrDefault(entry => entry.Id == selected);
        var completed = string.Join(',', list.Where(entry => entry.Status == "completed").Select(entry => entry.Id));
        if (completed != completedIds) { completedIds = completed; if (toolbar.IsEnabled) await LoadAsync(); }
    }
    public void Dispose() { if (disposed) return; disposed = true; timer.Stop(); stop.Cancel(); }

    internal async Task VerifyFilesJourneyForSmokeAsync(string localFile)
    {
        await LoadAsync();
        await QueueUploadsAsync([localFile]);
        var upload = (await api.GetAsync("transfers")).Deserialize<List<TransferEntry>>(DesktopClient.Json)!.First(entry => entry.SessionId == session && entry.Filename == Path.GetFileName(localFile));
        for (var i = 0; i < 100; i++) {
            await RefreshTransfersAsync();
            var entry = transferEntries.Items.Cast<TransferEntry>().Single(entry => entry.Id == upload.Id);
            if (entry.Status == "failed") throw new IOException(entry.Error);
            if (entry.Status == "completed") {
                await LoadAsync();
                if (!files.Any(file => file.Name == Path.GetFileName(localFile))) throw new IOException("Completed upload did not appear in the Files browser.");
                await api.PostAsync($"files/{session}/delete", new { path = RemotePath(Path.GetFileName(localFile)) });
                return;
            }
            await Task.Delay(100);
        }
        throw new IOException("File-browser queued upload did not complete.");
    }

}

public sealed class TransferEntry
{
    public string Id { get; set; } = "";
    public string SessionId { get; set; } = "";
    public string Filename { get; set; } = "";
    public string Direction { get; set; } = "";
    public string Status { get; set; } = "";
    public int Progress { get; set; }
    public long BytesTransferred { get; set; }
    public string? Error { get; set; }
}
