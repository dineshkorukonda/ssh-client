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
    public string Status { get; set; } = "ready";
    public string Source { get; set; } = "saved";
    public bool CanRemove => Source == "saved";
    public bool HasPublicKey => !string.IsNullOrEmpty(PublicKey);
    public string SourceLabel => Source == "local" ? "On this computer" : "Saved in app";
    public string SelectionLabel => $"{Name} / {AlgorithmBadge} / {(Source == "local" ? "On this computer" : "Saved key")}";
    public string Details => $"{PrivateKeyPath ?? "Public key only"}\n{Fingerprint}\n{(Status == "unsupported" ? "Encrypted OpenSSH format is unsupported by the SSH engine. Choose an unencrypted OpenSSH key or encrypted PEM key." : Status == "missing" ? "File missing; choose another key." : IsPassphraseProtected ? "Encrypted; passphrase requested when connecting." : "Private key stays in this file.")}";

    public string AlgorithmBadge => Algorithm.Replace("ssh-", "", StringComparison.OrdinalIgnoreCase).ToUpperInvariant();
}
