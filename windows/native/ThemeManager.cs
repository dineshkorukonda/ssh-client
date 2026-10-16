using System.Windows;
using System.Windows.Media;

namespace SSHClient.Windows;

public enum AppTheme
{
    Dark,
    Light
}

public static class ThemeManager
{
    static ThemeManager()
    {
        SystemParameters.StaticPropertyChanged += (_, args) => {
            if (args.PropertyName == nameof(SystemParameters.HighContrast) && Application.Current != null)
                Application.Current.Dispatcher.Invoke(() => ApplyTheme(CurrentTheme));
        };
    }

    public static AppTheme CurrentTheme { get; private set; } = AppTheme.Dark;

    public static void ApplyTheme(AppTheme theme)
    {
        CurrentTheme = theme;
        var res = Application.Current.Resources;

        var palette = theme == AppTheme.Dark
            ? new Dictionary<string, string> {
                ["Surface"] = "#0B0D11",
                ["Sidebar"] = "#101217",
                ["Card"] = "#171A21",
                ["CardHover"] = "#20242C",
                ["CardLow"] = "#0E1116",
                ["Border"] = "#2B3039",
                ["BorderHover"] = "#465063",
                ["Text"] = "#F1F3F7",
                ["Muted"] = "#A4ADBD",
                ["MutedSubtle"] = "#98A2B3",
                ["Accent"] = "#4DA3FF",
                ["AccentFg"] = "#08131F",
                ["AccentCyan"] = "#77B8FF",
                ["AccentYellow"] = "#E6B45C",
                ["TagBg"] = "#222A36",
                ["Selection"] = "#4DA3FF",
                ["NavActiveBg"] = "#1C2B40",
                ["NavActiveBorder"] = "#4DA3FF",
                ["NavActiveFg"] = "#D9EAFF",
                ["StatusOnline"] = "#42C990",
                ["StatusError"] = "#F07070"
            }
            : new Dictionary<string, string> {
                ["Surface"] = "#F6F8FB",
                ["Sidebar"] = "#EDF1F6",
                ["Card"] = "#FFFFFF",
                ["CardHover"] = "#E5EBF3",
                ["CardLow"] = "#F1F4F8",
                ["Border"] = "#CCD4E0",
                ["BorderHover"] = "#8996AA",
                ["Text"] = "#172133",
                ["Muted"] = "#526176",
                ["MutedSubtle"] = "#5C687A",
                ["Accent"] = "#1769C2",
                ["AccentFg"] = "#FFFFFF",
                ["AccentCyan"] = "#1769C2",
                ["AccentYellow"] = "#855616",
                ["TagBg"] = "#E3EAF3",
                ["Selection"] = "#1769C2",
                ["NavActiveBg"] = "#D9E8FA",
                ["NavActiveBorder"] = "#1769C2",
                ["NavActiveFg"] = "#164879",
                ["StatusOnline"] = "#13794C",
                ["StatusError"] = "#B73340"
            };
        foreach (var (key, value) in palette)
            SetBrush(res, key, (Color)ColorConverter.ConvertFromString(value));

        if (SystemParameters.HighContrast) {
            foreach (var key in new[] { "Surface", "Sidebar", "Card", "CardHover", "CardLow", "TagBg" }) SetBrush(res, key, SystemColors.WindowColor);
            foreach (var key in new[] { "Text", "Muted", "MutedSubtle", "Border", "BorderHover", "StatusOnline", "StatusError" }) SetBrush(res, key, SystemColors.WindowTextColor);
            foreach (var key in new[] { "Accent", "AccentCyan", "AccentYellow", "NavActiveBg", "Selection" }) SetBrush(res, key, SystemColors.HighlightColor);
            foreach (var key in new[] { "AccentFg", "NavActiveFg" }) SetBrush(res, key, SystemColors.HighlightTextColor);
        }
    }

    private static void SetBrush(ResourceDictionary res, string key, Color color)
    {
        if (res[key] is SolidColorBrush brush)
        {
            if (brush.IsFrozen)
                res[key] = new SolidColorBrush(color);
            else
                brush.Color = color;
        }
        else
        {
            res[key] = new SolidColorBrush(color);
        }
    }
}
