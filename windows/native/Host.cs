using System.Text.Json;
using System.Text.Json.Serialization;
namespace SSHClient.Windows;
public sealed class Host
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "";
    [JsonPropertyName("host")] public string Address { get; set; } = "";
    public string User { get; set; } = "root";
    public int Port { get; set; } = 22;
    public string DefaultAuthMethod { get; set; } = "key";
    public string? IdentityFile { get; set; }
    public string? ProxyJump { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    [JsonIgnore] public string Description => $"{User}@{Address}:{Port}";
    public Host Copy() => JsonSerializer.Deserialize<Host>(JsonSerializer.Serialize(this, DesktopClient.Json), DesktopClient.Json)!;
}
