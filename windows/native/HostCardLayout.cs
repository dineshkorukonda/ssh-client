namespace SSHClient.Windows;

public static class HostCardLayout
{
    public static double Width(double available, bool grid)
    {
        var width = Math.Max(1, available - 22);
        if (!grid) return width;
        var columns = Math.Max(1, Math.Floor(width / 260));
        return Math.Max(1, width / columns - 8);
    }
}
