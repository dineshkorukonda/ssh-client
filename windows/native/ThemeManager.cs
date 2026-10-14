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

        if (theme == AppTheme.Dark)
        {
            // Plain Black Theme (Pure Pitch Black with Dark Grey Cards & White Primary Buttons)
            SetBrush(res, "Surface", Color.FromRgb(0, 0, 0));             // #000000 (Plain Black)
            SetBrush(res, "Sidebar", Color.FromRgb(9, 9, 11));            // #09090b
            SetBrush(res, "Card", Color.FromRgb(14, 14, 17));             // #0e0e11 (Dark Grey Box)
            SetBrush(res, "CardHover", Color.FromRgb(24, 24, 27));        // #18181b
            SetBrush(res, "CardLow", Color.FromRgb(6, 6, 8));             // #060608
            SetBrush(res, "Border", Color.FromRgb(39, 39, 42));           // #27272a
            SetBrush(res, "BorderHover", Color.FromRgb(63, 63, 70));      // #3f3f46
            SetBrush(res, "Text", Color.FromRgb(250, 250, 250));          // #fafafa (Pure White Text)
            SetBrush(res, "Muted", Color.FromRgb(161, 161, 170));         // #a1a1aa
            SetBrush(res, "MutedSubtle", Color.FromRgb(140, 140, 150));   // Accessible muted labels
            SetBrush(res, "Accent", Color.FromRgb(255, 255, 255));        // #ffffff (White Button)
            SetBrush(res, "AccentFg", Color.FromRgb(0, 0, 0));            // #000000 (Black Button Text)
            SetBrush(res, "AccentCyan", Color.FromRgb(56, 189, 248));     // #38bdf8
            SetBrush(res, "AccentYellow", Color.FromRgb(251, 191, 36));   // #fbbf24
            SetBrush(res, "TagBg", Color.FromRgb(24, 24, 27));            // #18181b
            SetBrush(res, "Selection", Color.FromRgb(255, 255, 255));

            SetBrush(res, "NavActiveBg", Color.FromRgb(24, 24, 27));      // #18181b (soft subtle pill)
            SetBrush(res, "NavActiveBorder", Colors.Transparent);         // Seamless borderless nav
            SetBrush(res, "NavActiveFg", Color.FromRgb(250, 250, 250));   // #fafafa (Pure White)
        }
        else
        {
            // Plain White Theme (Pure White with Crisp Grey Borders & Black Primary Buttons)
            SetBrush(res, "Surface", Color.FromRgb(255, 255, 255));       // #ffffff (Plain White)
            SetBrush(res, "Sidebar", Color.FromRgb(248, 249, 250));       // #f8f9fa
            SetBrush(res, "Card", Color.FromRgb(255, 255, 255));          // #ffffff (White Box)
            SetBrush(res, "CardHover", Color.FromRgb(244, 244, 245));     // #f4f4f5
            SetBrush(res, "CardLow", Color.FromRgb(250, 250, 250));       // #fafafa
            SetBrush(res, "Border", Color.FromRgb(228, 228, 231));        // #e4e4e7
            SetBrush(res, "BorderHover", Color.FromRgb(212, 212, 216));   // #d4d4d8
            SetBrush(res, "Text", Color.FromRgb(9, 9, 11));               // #09090b (Dark Text)
            SetBrush(res, "Muted", Color.FromRgb(113, 113, 122));         // #71717a
            SetBrush(res, "MutedSubtle", Color.FromRgb(105, 105, 115));   // #696973
            SetBrush(res, "Accent", Color.FromRgb(9, 9, 11));             // #09090b (Black Button)
            SetBrush(res, "AccentFg", Color.FromRgb(255, 255, 255));      // #ffffff (White Button Text)
            SetBrush(res, "AccentCyan", Color.FromRgb(3, 105, 161));      // #0284c7
            SetBrush(res, "AccentYellow", Color.FromRgb(146, 64, 14));    // #d97706
            SetBrush(res, "TagBg", Color.FromRgb(244, 244, 245));         // #f4f4f5
            SetBrush(res, "Selection", Color.FromRgb(9, 9, 11));

            SetBrush(res, "NavActiveBg", Color.FromRgb(235, 236, 240));   // #ebecf0 (soft subtle pill)
            SetBrush(res, "NavActiveBorder", Colors.Transparent);         // Seamless borderless nav
            SetBrush(res, "NavActiveFg", Color.FromRgb(9, 9, 11));        // #09090b (Dark Text)
        }
        if (SystemParameters.HighContrast) {
            foreach (var key in new[] { "Surface", "Sidebar", "Card", "CardHover", "CardLow", "TagBg" }) SetBrush(res, key, SystemColors.WindowColor);
            foreach (var key in new[] { "Text", "Muted", "MutedSubtle", "Border", "BorderHover" }) SetBrush(res, key, SystemColors.WindowTextColor);
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
