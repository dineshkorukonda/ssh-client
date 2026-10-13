using System.Net;
using System.Text.RegularExpressions;

namespace SSHClient.Windows;

public static class QuickConnect
{
    public static Host Parse(string input)
    {
        var query = input.Trim();
        if (query.StartsWith("ssh://", StringComparison.OrdinalIgnoreCase)) query = query[6..];
        var match = Regex.Match(query, @"^(?:(?<user>[^@:/\s]+)@)?(?<host>\[[^\[\]\s]+\]|[^@:/\s]+)(?::(?<port>\d+))?$", RegexOptions.CultureInvariant);
        if (!match.Success) throw new ArgumentException("Use user@hostname:port or ssh://user@[IPv6]:port.");
        var address = match.Groups["host"].Value;
        if (address.StartsWith('[')) {
            address = address[1..^1];
            if (!IPAddress.TryParse(address, out var ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetworkV6)
                throw new ArgumentException("Enter a valid IPv6 address in brackets.");
        }
        var port = 22;
        if (match.Groups["port"].Success && (!int.TryParse(match.Groups["port"].Value, out port) || port is < 1 or > 65535))
            throw new ArgumentException("SSH port must be between 1 and 65535.");
        return new Host { Name = input.Trim(), Address = address, Port = port, User = match.Groups["user"].Success ? match.Groups["user"].Value : "root" };
    }
}

public sealed record PaletteEntry(string Label, Host? Host = null, string? Command = null, string? SessionId = null);
