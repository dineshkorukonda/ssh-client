namespace SSHClient.Windows;

public sealed class FileEntry
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    public string Type { get; set; } = "";
    public long Size { get; set; }
    public string Permissions { get; set; } = "";
    public string SizeLabel => Type == "directory" ? "--" : Size < 1024 ? $"{Size} B" : Size < 1048576 ? $"{Size / 1024d:N1} KB" : $"{Size / 1048576d:N1} MB";
    public string Icon => Type == "directory" ? "DIR" : "FILE";
    public override string ToString() => $"{(Type == "directory" ? "DIR " : "FILE")}   {Name}   {Size:N0} bytes   {Permissions}";
}
