namespace SSHClient.Windows;

public class KeyEntry
{
    public string Id { get; set; } = Guid.NewGuid().ToString("n")[..8];
    public string Name { get; set; } = "";
    public string Algorithm { get; set; } = "ED25519";
    public string Fingerprint { get; set; } = "";
    public string PublicKey { get; set; } = "";
    public string? PrivateKeyPath { get; set; }
    public int AssociatedHostsCount { get; set; }
    public string CreatedAt { get; set; } = DateTime.UtcNow.ToString("yyyy-MM-dd");
    public bool IsPassphraseProtected { get; set; }

    public string AlgorithmBadge => Algorithm.ToUpperInvariant();
}
