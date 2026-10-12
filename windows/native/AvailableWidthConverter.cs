using System.Globalization;
using System.Windows.Data;

namespace SSHClient.Windows;

public sealed class AvailableWidthConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is double width ? Math.Max(60, width - 210) : 180d;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}
