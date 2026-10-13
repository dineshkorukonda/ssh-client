using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using SSHClient.Windows;

internal static class NativeUpdaterRegression
{
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static string AssetUrl(string name) => "https://github.com/dineshkorukonda/ssh-client/releases/download/v0.0.69/" + name;
    private static JsonElement Release(string filename, string? url = null) => JsonSerializer.SerializeToElement(new {
        tag_name = "v0.0.69", assets = new[] { new { name = filename, browser_download_url = url ?? AssetUrl(filename), size = 4, digest = (string?)null } }
    });

    public static async Task RunAsync()
    {
        Require(NativeUpdater.ParseRelease(Release("ssh-client-setup-v0.0.69-windows-x64.exe"), "0.0.68", true)?.Installed == true, "Installed app must upgrade through its installer.");
        Require(NativeUpdater.ParseRelease(Release("ssh-client-windows-x64.zip"), "0.0.68", false)?.Installed == false, "Portable app must select the published ZIP name.");
        Require(NativeUpdater.ParseRelease(Release("ssh-client-windows-x64.zip"), "0.0.69", false) == null, "Current versions must not downgrade or reinstall.");
        foreach (var invalid in new[] { "https://example.com/update.exe", "http://github.com/dineshkorukonda/ssh-client/releases/download/v0.0.69/ssh-client-windows-x64.zip" }) {
            try { NativeUpdater.ParseRelease(Release("ssh-client-windows-x64.zip", invalid), "0.0.68", false); throw new InvalidOperationException("Accepted foreign update source."); }
            catch (IOException) { }
        }
        try { NativeUpdater.ParseRelease(Release("linux.tar.gz"), "0.0.68", true); throw new InvalidOperationException("Accepted a missing installer."); }
        catch (IOException) { }
        var root = Path.Combine(Path.GetTempPath(), "ssh-client-updater-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try {
            var archive = Path.Combine(root, "package.zip");
            using (var zip = ZipFile.Open(archive, ZipArchiveMode.Create)) {
                foreach (var name in new[] { "ssh-client.exe", "bin/ssh_client.bat", "terminal/index.html" }) {
                    using var writer = new StreamWriter(zip.CreateEntry("ssh-client/" + name).Open()); writer.Write("fixture");
                }
            }
            var bytes = await File.ReadAllBytesAsync(archive);
            var digest = "sha256:" + Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
            using var http = new HttpClient(new FixtureHandler(bytes));
            var update = new NativeUpdate("0.0.69", new UpdateAsset("ssh-client-windows-x64.zip", AssetUrl("ssh-client-windows-x64.zip"), bytes.Length, digest), false);
            var progress = new List<int>();
            var payload = await NativeUpdater.StageAsync(update, new InlineProgress(progress), client: http, stagingRoot: root);
            Require(File.Exists(Path.Combine(payload, "bin", "ssh_client.bat")), "Nested archives must stage a complete app.");
            Require(progress.Last() == 100, "Download progress must reach 100%.");
            foreach (var broken in new[] { update with { Asset = update.Asset with { Size = bytes.Length + 1 } }, update with { Asset = update.Asset with { Digest = "sha256:" + new string('0', 64) } } }) {
                try { await NativeUpdater.StageAsync(broken, new InlineProgress([]), client: http, stagingRoot: root); throw new InvalidOperationException("Accepted incomplete or corrupt update."); }
                catch (IOException) { }
            }
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            try { await NativeUpdater.StageAsync(update, new InlineProgress([]), cancelled.Token, http, root); throw new InvalidOperationException("Ignored cancellation."); }
            catch (OperationCanceledException) { }
            var target = Path.Combine(root, "installation with spaces"); Directory.CreateDirectory(target);
            try { NativeUpdater.BuildApplyScript(target, target, false, 123); throw new InvalidOperationException("Allowed staging over installed files."); }
            catch (IOException) { }
            var script = NativeUpdater.BuildApplyScript(payload, target, false, 2147483647);
            Require(!script.Contains("taskkill") && !script.Contains("/IM"), "Updater must never terminate unrelated processes.");
            Require(script.Contains("Copy-Item -LiteralPath") && script.Contains("Remove-Item -LiteralPath"), "Update and rollback must use literal paths.");
            if (OperatingSystem.IsWindows()) await VerifyFileTransactionsAsync(root, payload, target);
        } finally { Directory.Delete(root, true); }
        Console.WriteLine("Native updater regressions passed: asset selection, trusted URLs, checksums, staging, cancellation and rollback.");
    }

    private static async Task VerifyFileTransactionsAsync(string root, string payload, string target)
    {
        await File.WriteAllTextAsync(Path.Combine(target, "ssh-client.exe"), "old-executable");
        await File.WriteAllTextAsync(Path.Combine(target, "user-notes.txt"), "preserved-user-file");
        var script = NativeUpdater.BuildApplyScript(payload, target, false, 2147483647);
        // Mock process launch only. File copy and rollback execute the real generated helper.
        await RunScriptAsync(root, "function Start-Process { param($FilePath, $WorkingDirectory) }\n" + script);
        Require(await File.ReadAllTextAsync(Path.Combine(target, "ssh-client.exe")) == "fixture", "Portable update must replace installed binaries.");
        Require(await File.ReadAllTextAsync(Path.Combine(target, "user-notes.txt")) == "preserved-user-file", "Portable update must preserve unrelated user files.");
        await File.WriteAllTextAsync(Path.Combine(target, "ssh-client.exe"), "rollback-original");
        await File.WriteAllTextAsync(Path.Combine(payload, "new-file.txt"), "new-content");
        await File.WriteAllTextAsync(Path.Combine(payload, "zz-failure.txt"), "fail-content");
        var inject = """
            function Start-Process { param($FilePath, $WorkingDirectory) }
            function Copy-Item {
                param($LiteralPath, $Destination, [switch]$Force)
                if ($LiteralPath.EndsWith('zz-failure.txt')) { throw 'Injected copy failure' }
                Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force
            }
            """;
        var failureScript = script.Replace("Add-Type -AssemblyName PresentationFramework", "# Suppress test dialog").Replace("[System.Windows.MessageBox]::Show('The update could not finish. Your saved hosts and keys are preserved. Details: ' + $log, 'ssh-client update') | Out-Null", "# Failure recorded in update.log");
        await RunScriptAsync(root, inject + "\n" + failureScript);
        Require(await File.ReadAllTextAsync(Path.Combine(target, "ssh-client.exe")) == "rollback-original", "Failed update must restore the original executable.");
        Require(!File.Exists(Path.Combine(target, "new-file.txt")), "Rollback must remove files introduced by the failed update.");
        Require(await File.ReadAllTextAsync(Path.Combine(target, "user-notes.txt")) == "preserved-user-file", "Rollback must preserve user data.");
        var log = await File.ReadAllTextAsync(Path.Combine(Path.GetDirectoryName(payload)!, "update.log"));
        Require(log.Contains("Injected copy failure"), "Failed updates must retain actionable diagnostics.");
        var installer = Path.Combine(root, "installer.exe"); await File.WriteAllTextAsync(installer, "fixture");
        var marker = Path.Combine(root, "installer-arguments.txt").Replace("'", "''");
        var installScript = NativeUpdater.BuildApplyScript(installer, target, true, 2147483647);
        var mockInstaller = $$"""
            function Start-Process {
                param($FilePath, $ArgumentList, [switch]$PassThru, [switch]$Wait, $WindowStyle, $WorkingDirectory)
                if ($PassThru) { $ArgumentList | Set-Content -LiteralPath '{{marker}}'; return @{ ExitCode = 0 } }
            }
            """;
        await RunScriptAsync(root, mockInstaller + "\n" + installScript);
        var arguments = await File.ReadAllTextAsync(Path.Combine(root, "installer-arguments.txt"));
        Require(arguments.Contains("/VERYSILENT") && arguments.Contains("/DIR=\"" + target + "\""), "Installer update must reuse the existing installation without an uninstall.");
    }

    private static async Task RunScriptAsync(string root, string script)
    {
        var file = Path.Combine(root, "apply-test.ps1"); await File.WriteAllTextAsync(file, script);
        var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-File", file }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
        Require(process.ExitCode == 0, "Update helper failed: " + await output + await error);
    }

    private sealed class FixtureHandler(byte[] body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        { cancel.ThrowIfCancellationRequested(); return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) }); }
    }
    private sealed class InlineProgress(List<int> values) : IProgress<int> { public void Report(int value) => values.Add(value); }
}
