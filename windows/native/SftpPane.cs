using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace SSHClient.Windows;

public sealed class SftpPane : UserControl, IDisposable
{
    private readonly DesktopClient api;
    private readonly string session;
    private readonly Window? owner;
    private readonly string? sessionTitle;
    private readonly Host? host;

    private readonly TextBox path = new() { Text = ".", Margin = new Thickness(0, 0, 8, 0), VerticalContentAlignment = VerticalAlignment.Center };
    private readonly ListView entries = new();
    private readonly TextBlock status = new() { Text = "Loading files...", FontSize = 11, Margin = new Thickness(0, 6, 0, 0) };
    private readonly WrapPanel toolbar = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };

    private readonly TextBox localPath = new() { Text = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), VerticalContentAlignment = VerticalAlignment.Center };
    private readonly ListView localEntries = new();
    private readonly ListView transferEntries = new() { MaxHeight = 120 };
    private readonly CheckBox showHidden = new() { Content = "Show hidden files", Margin = new Thickness(10, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox filterBox = new() { Width = 150, Margin = new Thickness(8, 0, 0, 0), VerticalContentAlignment = VerticalAlignment.Center };
    private readonly TextBlock filterHint = new() { Text = "Filter files...", FontSize = 11, Margin = new Thickness(18, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };

    private readonly WrapPanel remoteBreadcrumbs = new() { Margin = new Thickness(0, 0, 0, 6) };
    private readonly WrapPanel localBreadcrumbs = new() { Margin = new Thickness(0, 0, 0, 6) };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly CancellationTokenSource stop = new();
    private List<FileEntry> files = [];
    private bool polling, disposed;
    private string completedIds = "";
    private readonly TaskCompletionSource initialLoad = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public SftpPane(DesktopClient api, string session, Window? owner = null, string? sessionTitle = null, Host? host = null)
    {
        this.api = api;
        this.session = session;
        this.owner = owner;
        this.sessionTitle = sessionTitle;
        this.host = host;

        status.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        System.Windows.Automation.AutomationProperties.SetName(path, "Remote directory");
        System.Windows.Automation.AutomationProperties.SetName(localPath, "Local directory");
        System.Windows.Automation.AutomationProperties.SetName(entries, "Remote files");
        System.Windows.Automation.AutomationProperties.SetName(localEntries, "Local files");
        System.Windows.Automation.AutomationProperties.SetName(transferEntries, "Transfer queue");
        System.Windows.Automation.AutomationProperties.SetName(filterBox, "Filter files");

        filterHint.SetResourceReference(TextBlock.ForegroundProperty, "MutedSubtle");
        var root = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };

        // -------------------------------------------------------------
        // Top Action Toolbar Card
        // -------------------------------------------------------------
        var toolbarCard = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 8, 10, 8),
            Margin = new Thickness(0, 0, 0, 10)
        };
        toolbarCard.SetResourceReference(Border.BackgroundProperty, "Card");
        toolbarCard.SetResourceReference(Border.BorderBrushProperty, "Border");

        var toolbarDock = new DockPanel();

        // Right side of toolbar: Show hidden + Filter box
        var toolbarRight = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        toolbarRight.Children.Add(showHidden);
        showHidden.Checked += async (_, _) => await GuardAsync(LoadAsync);
        showHidden.Unchecked += async (_, _) => await GuardAsync(LoadAsync);

        var filterContainer = new Grid { VerticalAlignment = VerticalAlignment.Center };
        filterContainer.Children.Add(filterBox);
        filterContainer.Children.Add(filterHint);
        filterBox.TextChanged += (_, _) =>
        {
            filterHint.Visibility = string.IsNullOrEmpty(filterBox.Text) ? Visibility.Visible : Visibility.Collapsed;
            ApplyFilter();
        };
        toolbarRight.Children.Add(filterContainer);
        DockPanel.SetDock(toolbarRight, Dock.Right);
        toolbarDock.Children.Add(toolbarRight);

        // Left side of toolbar: Primary action buttons
        AddButton("Upload", UploadAsync, isPrimary: true);
        AddButton("Download", DownloadAsync);
        AddButton("New folder", NewFolderAsync);
        AddButton("Rename", RenameAsync);
        AddButton("Delete", DeleteAsync);
        AddButton("Upload selected local", () => localEntries.SelectedItem is FileEntry { Type: not "directory" } entry ? QueueUploadsAsync([entry.Path]) : Task.CompletedTask);

        toolbarDock.Children.Add(toolbar);
        toolbarCard.Child = toolbarDock;
        DockPanel.SetDock(toolbarCard, Dock.Top);
        root.Children.Add(toolbarCard);

        // -------------------------------------------------------------
        // Bottom Transfers & Queue Card
        // -------------------------------------------------------------
        var queueCard = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(12, 10, 12, 10),
            Margin = new Thickness(0, 10, 0, 0)
        };
        queueCard.SetResourceReference(Border.BackgroundProperty, "Card");
        queueCard.SetResourceReference(Border.BorderBrushProperty, "Border");

        var queuePanel = new DockPanel();
        var queueHeaderDock = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };

        var queueBadge = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(6, 2, 6, 2),
            Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        queueBadge.SetResourceReference(Border.BackgroundProperty, "CardLow");
        queueBadge.SetResourceReference(Border.BorderBrushProperty, "Border");

        var queueBadgeTitle = new TextBlock
        {
            Text = "TRANSFERS & QUEUE",
            FontSize = 10,
            FontWeight = FontWeights.Bold
        };
        queueBadgeTitle.SetResourceReference(TextBlock.FontFamilyProperty, "MonoFont");
        queueBadgeTitle.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
        queueBadge.Child = queueBadgeTitle;
        DockPanel.SetDock(queueBadge, Dock.Left);
        queueHeaderDock.Children.Add(queueBadge);

        var txActions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        foreach (var action in new[] { "cancel", "retry" })
        {
            var button = new Button
            {
                Content = action == "cancel" ? "Cancel transfer" : "Retry transfer",
                Margin = new Thickness(6, 0, 0, 0),
                Padding = new Thickness(10, 3, 10, 3),
                FontSize = 11
            };
            button.Click += async (_, _) => await GuardAsync(async () =>
            {
                if (transferEntries.SelectedItem is not TransferEntry entry) { status.Text = "Select a transfer first."; return; }
                if (action == "retry" && entry.Status is not ("failed" or "cancelled")) { status.Text = "Only failed or cancelled transfers can be retried."; return; }
                await api.PostAsync($"transfers/{entry.Id}/{action}", new { }, stop.Token);
                await RefreshTransfersAsync();
            });
            txActions.Children.Add(button);
        }
        DockPanel.SetDock(txActions, Dock.Right);
        queueHeaderDock.Children.Add(txActions);

        DockPanel.SetDock(queueHeaderDock, Dock.Top);
        queuePanel.Children.Add(queueHeaderDock);

        var txColumns = new GridView();
        foreach (var field in new[] { "Filename", "Direction", "Status", "Progress", "BytesTransferred", "Error" })
            txColumns.Columns.Add(new GridViewColumn { Header = field, DisplayMemberBinding = new Binding(field), Width = field == "Filename" ? 220 : (field == "Error" ? 180 : 100) });
        transferEntries.View = txColumns;

        DockPanel.SetDock(status, Dock.Bottom);
        queuePanel.Children.Add(status);
        queuePanel.Children.Add(transferEntries);

        queueCard.Child = queuePanel;
        DockPanel.SetDock(queueCard, Dock.Bottom);
        root.Children.Add(queueCard);

        // -------------------------------------------------------------
        // Center Dual Browsers Grid (Symmetrical Local & Remote)
        // -------------------------------------------------------------
        var browsers = new Grid();
        browsers.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        browsers.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        browsers.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        // Left Panel: Local Card
        var localCard = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10)
        };
        localCard.SetResourceReference(Border.BackgroundProperty, "Card");
        localCard.SetResourceReference(Border.BorderBrushProperty, "Border");
        var localPanel = new DockPanel();

        var localHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var localBadge = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(6, 2, 6, 2),
            Margin = new Thickness(0, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        localBadge.SetResourceReference(Border.BackgroundProperty, "CardHover");
        localBadge.SetResourceReference(Border.BorderBrushProperty, "Border");

        var localBadgeTitle = new TextBlock
        {
            Text = "LOCAL FILES",
            FontSize = 10,
            FontWeight = FontWeights.Bold
        };
        localBadgeTitle.SetResourceReference(TextBlock.FontFamilyProperty, "MonoFont");
        localBadgeTitle.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
        localBadge.Child = localBadgeTitle;
        DockPanel.SetDock(localBadge, Dock.Left);
        localHeader.Children.Add(localBadge);
        var localCaption = new TextBlock
        {
            Text = "This computer",
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center
        };
        localCaption.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        localHeader.Children.Add(localCaption);
        DockPanel.SetDock(localHeader, Dock.Top);
        localPanel.Children.Add(localHeader);

        var localBar = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var upLocal = new Button { Content = "Up", Padding = new Thickness(8, 3, 8, 3), Margin = new Thickness(0, 0, 6, 0), ToolTip = "Navigate up one folder" };
        upLocal.Click += (_, _) => GuardLocal(() => { localPath.Text = Directory.GetParent(Path.GetFullPath(localPath.Text))?.FullName ?? localPath.Text; LoadLocal(); });
        DockPanel.SetDock(upLocal, Dock.Left);
        localBar.Children.Add(upLocal);
        localBar.Children.Add(localPath);
        localPath.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) { try { LoadLocal(); } catch (Exception error) { status.Text = error.Message; } } };
        DockPanel.SetDock(localBar, Dock.Top);
        localPanel.Children.Add(localBar);

        DockPanel.SetDock(localBreadcrumbs, Dock.Top);
        localPanel.Children.Add(localBreadcrumbs);

        var localColumns = new GridView();
        localColumns.Columns.Add(new GridViewColumn { Header = "Type", DisplayMemberBinding = new Binding("Icon"), Width = 52 });
        localColumns.Columns.Add(new GridViewColumn { Header = "Name", DisplayMemberBinding = new Binding("Name"), Width = 220 });
        localColumns.Columns.Add(new GridViewColumn { Header = "Size", DisplayMemberBinding = new Binding("SizeLabel"), Width = 90 });
        localEntries.View = localColumns;
        localEntries.MouseDoubleClick += (_, _) => GuardLocal(() => { if (localEntries.SelectedItem is FileEntry { Type: "directory" } entry) { localPath.Text = entry.Path; LoadLocal(); } });
        localPanel.Children.Add(localEntries);
        localCard.Child = localPanel;
        Grid.SetColumn(localCard, 0);
        browsers.Children.Add(localCard);

        // Center Splitter
        var splitter = new GridSplitter
        {
            Width = 8,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            ResizeDirection = GridResizeDirection.Columns,
            ResizeBehavior = GridResizeBehavior.PreviousAndNext,
            Background = Brushes.Transparent
        };
        Grid.SetColumn(splitter, 1);
        browsers.Children.Add(splitter);

        // Right Panel: Remote Card
        var remoteCard = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10)
        };
        remoteCard.SetResourceReference(Border.BackgroundProperty, "Card");
        remoteCard.SetResourceReference(Border.BorderBrushProperty, "Border");
        var remotePanel = new DockPanel();

        var remoteHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var remoteBadge = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(6, 2, 6, 2),
            Margin = new Thickness(0, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        remoteBadge.SetResourceReference(Border.BackgroundProperty, "CardHover");
        remoteBadge.SetResourceReference(Border.BorderBrushProperty, "Border");

        var remoteBadgeTitle = new TextBlock
        {
            Text = "REMOTE FILES",
            FontSize = 10,
            FontWeight = FontWeights.Bold
        };
        remoteBadgeTitle.SetResourceReference(TextBlock.FontFamilyProperty, "MonoFont");
        remoteBadgeTitle.SetResourceReference(TextBlock.ForegroundProperty, "AccentCyan");
        remoteBadge.Child = remoteBadgeTitle;
        DockPanel.SetDock(remoteBadge, Dock.Left);
        remoteHeader.Children.Add(remoteBadge);

        var remoteInfo = new TextBlock
        {
            Text = !string.IsNullOrWhiteSpace(sessionTitle)
                ? (host != null ? $"{sessionTitle} ({host.Address})" : sessionTitle)
                : "SSH Filesystem",
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center
        };
        remoteInfo.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        remoteHeader.Children.Add(remoteInfo);
        DockPanel.SetDock(remoteHeader, Dock.Top);
        remotePanel.Children.Add(remoteHeader);

        var pathBar = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var upBtn = new Button { Content = "Up", Padding = new Thickness(8, 3, 8, 3), Margin = new Thickness(0, 0, 6, 0), ToolTip = "Navigate up one directory" };
        upBtn.Click += async (_, _) =>
        {
            var current = path.Text.TrimEnd('/');
            var slash = current.LastIndexOf('/');
            path.Text = slash > 0 ? current[..slash] : "/";
            await GuardAsync(LoadAsync);
        };
        DockPanel.SetDock(upBtn, Dock.Left);
        pathBar.Children.Add(upBtn);

        var refreshBtn = new Button { Content = "Refresh", Padding = new Thickness(8, 3, 8, 3), ToolTip = "Refresh folder contents" };
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
        remotePanel.Children.Add(pathBar);

        DockPanel.SetDock(remoteBreadcrumbs, Dock.Top);
        remotePanel.Children.Add(remoteBreadcrumbs);

        var columns = new GridView();
        columns.Columns.Add(new GridViewColumn { Header = "Type", DisplayMemberBinding = new Binding("Icon"), Width = 52 });
        columns.Columns.Add(new GridViewColumn { Header = "Name", DisplayMemberBinding = new Binding("Name"), Width = 220 });
        columns.Columns.Add(new GridViewColumn { Header = "Size", DisplayMemberBinding = new Binding("SizeLabel"), Width = 90 });
        columns.Columns.Add(new GridViewColumn { Header = "Permissions", DisplayMemberBinding = new Binding("Permissions"), Width = 95 });
        entries.View = columns;

        entries.AllowDrop = true;
        entries.Drop += async (_, e) =>
        {
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

        remotePanel.Children.Add(entries);
        remoteCard.Child = remotePanel;
        Grid.SetColumn(remoteCard, 2);
        browsers.Children.Add(remoteCard);

        root.Children.Add(browsers);

        timer.Tick += async (_, _) =>
        {
            if (polling || disposed) return;
            polling = true;
            try { await RefreshTransfersAsync(); }
            catch (OperationCanceledException) { }
            catch (Exception error) { status.Text = error.Message; }
            finally { polling = false; }
        };

        Content = root;

        Loaded += async (_, _) =>
        {
            if (disposed) return;
            timer.Start();
            await GuardAsync(LoadAsync);
            initialLoad.TrySetResult();
        };
    }

    private void AddButton(string title, Func<Task> action, bool isPrimary = false)
    {
        var button = new Button
        {
            Content = title,
            Margin = new Thickness(0, 0, 6, 0),
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 11
        };
        if (isPrimary && Application.Current.Resources["PrimaryButton"] is Style primaryStyle)
            button.Style = primaryStyle;
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

    private void ApplyFilter()
    {
        var query = filterBox.Text.Trim();
        entries.ItemsSource = files
            .Where(file => showHidden.IsChecked == true || !file.Name.StartsWith('.'))
            .Where(file => string.IsNullOrEmpty(query) || file.Name.Contains(query, StringComparison.OrdinalIgnoreCase))
            .ToArray();

        if (localAllFiles.Count > 0)
        {
            localEntries.ItemsSource = localAllFiles
                .Where(file => string.IsNullOrEmpty(query) || file.Name.Contains(query, StringComparison.OrdinalIgnoreCase))
                .ToArray();
        }
    }

    private List<FileEntry> localAllFiles = [];

    public async Task LoadAsync()
    {
        var result = await api.PostAsync($"files/{session}/list", new { path = path.Text });
        files = result.Deserialize<List<FileEntry>>(DesktopClient.Json) ?? [];
        ApplyFilter();
        PopulateBreadcrumbs(remoteBreadcrumbs, DirectoryBreadcrumbs.Remote(path.Text), destination => GuardAsync(async () => { path.Text = destination; await LoadAsync(); }));
        LoadLocal();
        status.Text = "Double-click folder to open. Drag files here to upload.";
    }

    private string RemotePath(string name) => path.Text.TrimEnd('/') + "/" + name;

    private void GuardLocal(Action action)
    {
        try { action(); }
        catch (Exception error) { status.Text = "Cannot open local folder: " + error.Message; }
    }

    private static void PopulateBreadcrumbs(WrapPanel panel, IReadOnlyList<DirectoryCrumb> crumbs, Func<string, Task> navigate)
    {
        panel.Children.Clear();
        foreach (var crumb in crumbs)
        {
            var button = new Button { Content = crumb.Label, ToolTip = crumb.Path, Margin = new Thickness(0, 0, 4, 4), Padding = new Thickness(6, 2, 6, 2), FontSize = 11 };
            System.Windows.Automation.AutomationProperties.SetName(button, "Open folder " + crumb.Path);
            button.Click += async (_, _) => await navigate(crumb.Path);
            panel.Children.Add(button);
        }
    }

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
        foreach (var file in paths)
        {
            if (!File.Exists(file)) { status.Text = "Folder uploads are not supported; select files."; continue; }
            var name = Path.GetFileName(file);
            if (files.Any(entry => entry.Name == name) && MessageBox.Show(ResolveOwner(), $"Replace remote file {name}?", "Upload conflict", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes) continue;
            await api.PostAsync($"transfers/{session}/upload", new { path = RemotePath(name), local_path = file }, stop.Token);
            count++;
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
        if (files.Any(file => file.Name == name && file.Path != entry.Path))
            throw new IOException("An item with this name already exists. Choose another name.");
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
        localAllFiles = new DirectoryInfo(localPath.Text).EnumerateFileSystemInfos()
            .Where(file => showHidden.IsChecked == true || (!file.Name.StartsWith('.') && (file.Attributes & FileAttributes.Hidden) == 0))
            .Select(file => new FileEntry { Name = file.Name, Path = file.FullName, Type = file is DirectoryInfo ? "directory" : "regular", Size = file is FileInfo info ? info.Length : 0 })
            .ToList();

        var query = filterBox.Text.Trim();
        localEntries.ItemsSource = localAllFiles
            .Where(file => string.IsNullOrEmpty(query) || file.Name.Contains(query, StringComparison.OrdinalIgnoreCase))
            .ToArray();

        PopulateBreadcrumbs(localBreadcrumbs, DirectoryBreadcrumbs.Local(localPath.Text), destination => { GuardLocal(() => { localPath.Text = destination; LoadLocal(); }); return Task.CompletedTask; });
    }

    private async Task NewFolderAsync()
    {
        var dialog = new FormDialog(ResolveOwner(), "New remote folder", [new("name", "Folder name")]);
        if (dialog.ShowDialog() != true) return;
        var name = dialog.Values["name"];
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(['/', '\\']) >= 0 || name is "." or "..")
            throw new ArgumentException("Enter a folder name without directory separators.");
        await api.PostAsync($"files/{session}/mkdir", new { path = RemotePath(name) }, stop.Token);
        await LoadAsync();
    }

    private async Task RefreshTransfersAsync()
    {
        var selected = (transferEntries.SelectedItem as TransferEntry)?.Id;
        var list = (await api.GetAsync("transfers", stop.Token)).Deserialize<List<TransferEntry>>(DesktopClient.Json)?.Where(entry => entry.SessionId == session).ToArray() ?? [];
        transferEntries.ItemsSource = list;
        transferEntries.SelectedItem = list.FirstOrDefault(entry => entry.Id == selected);
        var completed = string.Join(',', list.Where(entry => entry.Status == "completed").Select(entry => entry.Id));
        if (completed != completedIds) { completedIds = completed; if (toolbar.IsEnabled) await LoadAsync(); }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        timer.Stop();
        stop.Cancel();
    }

    internal async Task VerifyFilesJourneyForSmokeAsync(string localFile)
    {
        await initialLoad.Task.WaitAsync(TimeSpan.FromSeconds(10));
        for (var i = 0; i < 100 && !toolbar.IsEnabled; i++) await Task.Delay(50);
        if (!toolbar.IsEnabled) throw new IOException("Initial file-browser load did not finish.");
        await LoadAsync();
        localPath.Text = Path.GetDirectoryName(localFile)!; LoadLocal();
        if (localBreadcrumbs.Children.Count < 2 || remoteBreadcrumbs.Children.Count != 1) throw new IOException("File browser did not populate directory breadcrumbs.");
        var parent = (Button)localBreadcrumbs.Children[^2];
        var expectedParent = parent.ToolTip.ToString(); parent.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (localPath.Text != expectedParent) throw new IOException("Clicking a local breadcrumb did not navigate.");
        // Invalid paths must remain a recoverable file-browser error.
        localPath.Text = "\0"; GuardLocal(LoadLocal);
        if (!status.Text.StartsWith("Cannot open local folder:")) throw new IOException("Invalid local directory was not reported.");
        localPath.Text = Path.GetDirectoryName(localFile)!; LoadLocal();
        path.Text = "client-files"; await LoadAsync();
        if (remoteBreadcrumbs.Children.Count != 2) throw new IOException("Remote nested folder did not expose its ancestors.");
        ((Button)remoteBreadcrumbs.Children[0]).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (path.Text != ".") throw new IOException("Remote breadcrumb did not return to the session directory.");
        for (var i = 0; i < 100 && !toolbar.IsEnabled; i++) await Task.Delay(50);
        if (!toolbar.IsEnabled) throw new IOException("Remote breadcrumb navigation did not finish.");
        await LoadAsync();
        await QueueUploadsAsync([localFile]);
        var upload = (await api.GetAsync("transfers")).Deserialize<List<TransferEntry>>(DesktopClient.Json)!.First(entry => entry.SessionId == session && entry.Filename == Path.GetFileName(localFile));
        for (var i = 0; i < 100; i++)
        {
            await RefreshTransfersAsync();
            var entry = transferEntries.Items.Cast<TransferEntry>().Single(entry => entry.Id == upload.Id);
            if (entry.Status == "failed") throw new IOException(entry.Error);
            if (entry.Status == "completed")
            {
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
