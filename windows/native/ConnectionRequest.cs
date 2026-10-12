using System.Text.Json;

namespace SSHClient.Windows;

public static class ConnectionRequest
{
    public static Dictionary<string, object?> Build(Host host, IReadOnlyDictionary<string, string> values)
    {
        var attrs = JsonSerializer.SerializeToElement(host, DesktopClient.Json)
            .Deserialize<Dictionary<string, object?>>()!;
        foreach (var key in new[] { "user", "password", "passphrase" })
            if (values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)) attrs[key] = value;
        var jump = new Dictionary<string, string>();
        foreach (var key in new[] { "user", "password", "identity_file", "passphrase" })
            if (values.TryGetValue("jump_" + key, out var value) && !string.IsNullOrWhiteSpace(value)) jump[key] = value;
        if (jump.Count > 0) attrs["jump_credentials"] = jump;
        return attrs;
    }
}
