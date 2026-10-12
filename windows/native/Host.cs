using System.Text.Json;
using System.Text.Json.Serialization;

namespace SSHClient.Windows;

public sealed class Host
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "";
    [JsonPropertyName("host")]
    public string Address { get; set; } = "";
    public int Port { get; set; } = 22;
    public string User { get; set; } = "";
    public string DefaultAuthMethod { get; set; } = "key";
    public string? IdentityFile { get; set; }
    public string? ProxyJump { get; set; }
    public string[] Tags { get; set; } = [];
    public string Notes { get; set; } = "";
    public bool Favorite { get; set; }
    public string? LastConnectedAt { get; set; }
    public string Description => $"{User}@{Address}:{Port}";

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }

    [JsonIgnore]
    public string OsBadge
    {
        get
        {
            var combined = (Name + " " + Address + " " + string.Join(" ", Tags)).ToLowerInvariant();
            if (combined.Contains("ubuntu")) return "UBUNTU";
            if (combined.Contains("debian")) return "DEBIAN";
            if (combined.Contains("redhat") || combined.Contains("rhel") || combined.Contains("centos") || combined.Contains("fedora")) return "REDHAT";
            if (combined.Contains("alpine")) return "ALPINE";
            if (combined.Contains("arch")) return "ARCH";
            if (combined.Contains("bsd")) return "BSD";
            if (combined.Contains("windows") || combined.Contains("win")) return "WINDOWS";
            if (combined.Contains("mac") || combined.Contains("darwin") || combined.Contains("apple")) return "MACOS";
            if (combined.Contains("k8s") || combined.Contains("kube")) return "K8S";
            return "SSH";
        }
    }

    [JsonIgnore]
    public string OsColor => "#E4E4E7";

    [JsonIgnore]
    public string TagSummary
    {
        get
        {
            if (Tags.Length == 0) return "No tags";
            return string.Join("  •  ", Tags);
        }
    }

    [JsonIgnore]
    public string PortBadge => Port == 22 ? ":22" : $":{Port}";

    public Host Copy() => new()
    {
        Id = Id,
        Name = Name,
        Address = Address,
        Port = Port,
        User = User,
        DefaultAuthMethod = DefaultAuthMethod,
        IdentityFile = IdentityFile,
        ProxyJump = ProxyJump,
        Tags = (string[])Tags.Clone(),
        Notes = Notes,
        Favorite = Favorite,
        LastConnectedAt = LastConnectedAt,
        Extra = Extra != null ? new Dictionary<string, JsonElement>(Extra) : null
    };
}
