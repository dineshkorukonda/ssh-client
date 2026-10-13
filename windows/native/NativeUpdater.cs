using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace SSHClient.Windows;

public sealed record UpdateAsset(string Name, string Url, long Size, string? Digest);
public sealed record NativeUpdate(string Version, UpdateAsset Asset, bool Installed);

public static class NativeUpdater
{
    private const string Repository = "dineshkorukonda/ssh-client";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(15) };

    public static async Task<NativeUpdate?> CheckAsync(string currentVersion, string root, CancellationToken cancel = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        using var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{Repository}/releases/latest");
        request.Headers.UserAgent.ParseAdd("ssh-client/" + currentVersion);
        using var response = await Http.SendAsync(request, deadline.Token);
        response.EnsureSuccessStatusCode();
        using var release = JsonDocument.Parse(await response.Content.ReadAsStringAsync(deadline.Token));
        return ParseRelease(release.RootElement, currentVersion, File.Exists(Path.Combine(root, "unins000.exe")));
    }

    public static NativeUpdate? ParseRelease(JsonElement release, string currentVersion, bool installed)
    {
        var versionText = release.GetProperty("tag_name").GetString()!.TrimStart('v');
        if (!Version.TryParse(versionText, out var version) || !Version.TryParse(currentVersion.TrimStart('v'), out var current))
            throw new IOException("The release contains an invalid version.");
        if (version <= current) return null;
        var expected = installed ? $"ssh-client-setup-v{versionText}-windows-x64.exe" : $"ssh-client-v{versionText}-windows-x64.zip";
        // Some older releases omit the v in the archive filename.
        var asset = release.GetProperty("assets").EnumerateArray().FirstOrDefault(item =>
            item.GetProperty("name").GetString() == expected || (!installed && item.GetProperty("name").GetString() == "ssh-client-windows-x64.zip") || (!installed && item.GetProperty("name").GetString() == $"ssh-client-{versionText}-windows-x64.zip"));
        if (asset.ValueKind == JsonValueKind.Undefined) throw new IOException("The Windows update package is not available yet. Try again after the release finishes.");
        var url = asset.GetProperty("browser_download_url").GetString()!;
        ValidateAssetUrl(url, versionText, asset.GetProperty("name").GetString()!);
        var size = asset.GetProperty("size").GetInt64();
        if (size <= 0) throw new IOException("The update package is empty.");
        return new NativeUpdate(versionText, new UpdateAsset(asset.GetProperty("name").GetString()!, url, size,
            asset.TryGetProperty("digest", out var digest) ? digest.GetString() : null), installed);
    }

    public static void ValidateAssetUrl(string url, string version, string filename)
    {
        var expected = $"https://github.com/{Repository}/releases/download/v{version}/{filename}";
        if (url != expected || Path.GetFileName(filename) != filename || filename.Contains('\\'))
            throw new IOException("The update must come from this app's GitHub release.");
    }

    public static async Task<string> StageAsync(NativeUpdate update, IProgress<int> progress, CancellationToken cancel = default, HttpClient? client = null, string? stagingRoot = null)
    {
        ValidateAssetUrl(update.Asset.Url, update.Version, update.Asset.Name);
        var stage = Path.Combine(stagingRoot ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ssh-client", "updates"), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        var download = Path.Combine(stage, update.Asset.Name);
        using (var response = await (client ?? Http).GetAsync(update.Asset.Url, HttpCompletionOption.ResponseHeadersRead, cancel)) {
            response.EnsureSuccessStatusCode();
            await using var input = await response.Content.ReadAsStreamAsync(cancel);
            await using var output = new FileStream(download, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var buffer = new byte[81920]; long total = 0; int count;
            while ((count = await input.ReadAsync(buffer, cancel)) != 0) {
                total += count;
                if (total > update.Asset.Size) throw new IOException("The downloaded update exceeds the expected size.");
                await output.WriteAsync(buffer.AsMemory(0, count), cancel);
                progress.Report((int)(total * 100 / update.Asset.Size));
            }
            if (total != update.Asset.Size) throw new IOException("The update download is incomplete. Try again.");
        }
        await VerifyDigestAsync(download, update.Asset.Digest, cancel);
        if (update.Installed) return download;
        var payload = Path.Combine(stage, "payload");
        await Task.Run(() => ZipFile.ExtractToDirectory(download, payload), cancel);
        if (!File.Exists(Path.Combine(payload, "ssh-client.exe"))) {
            var nested = Directory.GetDirectories(payload).SingleOrDefault(directory => File.Exists(Path.Combine(directory, "ssh-client.exe")));
            if (nested != null) payload = nested;
        }
        if (!File.Exists(Path.Combine(payload, "ssh-client.exe")) || !File.Exists(Path.Combine(payload, "bin", "ssh_client.bat")))
            throw new IOException("The archive does not contain a complete native Windows app.");
        return payload;
    }

    public static async Task VerifyDigestAsync(string path, string? digest, CancellationToken cancel = default)
    {
        if (string.IsNullOrWhiteSpace(digest)) return; // Older GitHub releases do not expose digests.
        if (!digest.StartsWith("sha256:", StringComparison.Ordinal) || digest.Length != 71)
            throw new IOException("The update has an unsupported checksum.");
        await using var file = File.OpenRead(path);
        var actual = Convert.ToHexString(await SHA256.HashDataAsync(file, cancel));
        if (!actual.Equals(digest[7..], StringComparison.OrdinalIgnoreCase)) throw new IOException("Update checksum failed. Download the update again.");
    }

    private static string Quote(string value) => "'" + value.Replace("'", "''") + "'";

    public static string BuildApplyScript(string payload, string root, bool installed, int processId)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        if (fullRoot == Path.GetPathRoot(fullRoot)?.TrimEnd(Path.DirectorySeparatorChar) || processId <= 0)
            throw new IOException("Invalid application update target.");
        var fullPayload = Path.GetFullPath(payload);
        if (fullPayload.Equals(fullRoot, StringComparison.OrdinalIgnoreCase) || fullPayload.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Update staging must be outside the installed app.");
        var stage = Path.GetDirectoryName(fullPayload)!;
        var apply = installed ? $$"""
            $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="' + $target + '" /LOG="' + (Join-Path $stage 'installer.log') + '"'
            $installer = Start-Process -FilePath $payload -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
            if ($installer.ExitCode -ne 0) { throw "Installer exited with code $($installer.ExitCode)." }
            """ : """
            $backup = Join-Path $stage 'backup'
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            $changed = @()
            try {
                foreach ($file in Get-ChildItem -LiteralPath $payload -File -Recurse) {
                    $relative = $file.FullName.Substring($payload.Length).TrimStart('\')
                    $destination = [IO.Path]::GetFullPath((Join-Path $target $relative))
                    if (-not $destination.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Update file escaped the application folder.' }
                    $original = Join-Path $backup $relative
                    $existed = Test-Path -LiteralPath $destination
                    if ($existed) {
                        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($original)) -Force | Out-Null
                        Copy-Item -LiteralPath $destination -Destination $original -Force
                    }
                    $changed += @{ Destination = $destination; Original = $original; Existed = $existed }
                    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
                    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
                }
            } catch {
                foreach ($file in $changed) {
                    if ($file.Existed) { Copy-Item -LiteralPath $file.Original -Destination $file.Destination -Force }
                    elseif (Test-Path -LiteralPath $file.Destination) { Remove-Item -LiteralPath $file.Destination -Force }
                }
                throw
            }
            """;
        return $$"""
            $ErrorActionPreference = 'Stop'
            $payload = {{Quote(fullPayload)}}
            $target = {{Quote(fullRoot)}}
            $stage = {{Quote(stage)}}
            $log = Join-Path $stage 'update.log'
            try {
                $deadline = [DateTime]::UtcNow.AddMinutes(2)
                while (Get-Process -Id {{processId}} -ErrorAction SilentlyContinue) {
                    if ([DateTime]::UtcNow -gt $deadline) { throw 'The app did not close; update was not applied.' }
                    Start-Sleep -Milliseconds 500
                }
                if (-not (Test-Path -LiteralPath (Join-Path $target 'ssh-client.exe'))) { throw 'The application folder is missing.' }
                Start-Sleep -Seconds 1
                {{apply}}
                'Update installed successfully.' | Set-Content -LiteralPath $log
                Get-ChildItem Env: | Where-Object { $_.Name.StartsWith('RELEASE_') -or $_.Name -in @('SSH_CLIENT_DESKTOP_TOKEN','SSH_CLIENT_PORT') } | ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) }
                Start-Process -FilePath (Join-Path $target 'ssh-client.exe') -WorkingDirectory $target
            } catch {
                $_.ToString() | Set-Content -LiteralPath $log
                Add-Type -AssemblyName PresentationFramework
                [System.Windows.MessageBox]::Show('The update could not finish. Your saved hosts and keys are preserved. Details: ' + $log, 'ssh-client update') | Out-Null
            }
            """;
    }

    public static void LaunchApply(string payload, string root, bool installed)
    {
        var script = BuildApplyScript(payload, root, installed, Environment.ProcessId);
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("Could not start the update helper.");
    }
}
