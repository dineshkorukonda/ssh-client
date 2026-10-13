using System.IO;

namespace SSHClient.Windows;

public sealed record DirectoryCrumb(string Label, string Path);

public static class DirectoryBreadcrumbs
{
    public static IReadOnlyList<DirectoryCrumb> Remote(string directory)
    {
        var current = directory.StartsWith('/') ? "/" : ".";
        var result = new List<DirectoryCrumb> { new(current, current) };
        foreach (var part in directory.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".") continue;
            current = current.TrimEnd('/') + "/" + part;
            result.Add(new(part, current));
        }
        return result;
    }

    public static IReadOnlyList<DirectoryCrumb> Local(string directory)
    {
        var full = Path.GetFullPath(directory);
        var current = Path.GetPathRoot(full)!;
        var result = new List<DirectoryCrumb> { new(current, current) };
        foreach (var part in full[current.Length..].Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            result.Add(new(part, current));
        }
        return result;
    }
}
