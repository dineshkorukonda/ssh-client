using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
namespace SSHClient.Windows;

public sealed class TerminalView : Grid, IDisposable
{
    private readonly DesktopClient api;
    private readonly Window owner;
    private readonly Action<string> status;
    private readonly Action<string>? stateChanged;
    public bool IsDisposed { get; private set; }
    private readonly WebView2 web = new();
    private readonly CancellationTokenSource stop = new();
    private long cursor;
    private bool ready;
    private bool initializing;
    private readonly Queue<string> pendingInput = new();
    private bool sending;
    private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task Ready => completion.Task;
    public string SessionId { get; }
    internal Func<string, bool>? ConfirmHostKeyForSmoke { get; set; }
    public TerminalView(DesktopClient api, string id, Window owner, Action<string> status, Action<string>? stateChanged = null)
    {
        this.api = api; SessionId = id; this.owner = owner; this.status = status; this.stateChanged = stateChanged;
        Children.Add(web);
        Loaded += async (_, _) =>
        {
            if (initializing) return; initializing = true;
            try
            {
                await EnsureRuntimeAsync();
                if (stop.IsCancellationRequested) return;
                var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ssh-client", "webview");
                var environment = await CoreWebView2Environment.CreateAsync(null, profile);
                await web.EnsureCoreWebView2Async(environment);
                web.CoreWebView2.SetVirtualHostNameToFolderMapping("terminal.ssh-client.local", Path.Combine(AppContext.BaseDirectory, "terminal"), CoreWebView2HostResourceAccessKind.DenyCors);
                web.CoreWebView2.Settings.AreDevToolsEnabled = false;
                web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
                web.CoreWebView2.Settings.IsStatusBarEnabled = false;
                web.CoreWebView2.NewWindowRequested += (_, args) => args.Handled = true;
                web.CoreWebView2.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
                web.CoreWebView2.NavigationStarting += (_, args) => { if (!args.Uri.StartsWith("https://terminal.ssh-client.local/", StringComparison.Ordinal)) args.Cancel = true; };
                web.CoreWebView2.WebMessageReceived += MessageReceived;
                web.CoreWebView2.NavigationCompleted += async (_, args) =>
                {
                    if (!args.IsSuccess) completion.TrySetException(new IOException("Terminal page failed to load: " + args.WebErrorStatus));
                    else if (!ready)
                    {
                        var diagnostic = await web.CoreWebView2.ExecuteScriptAsync("({terminal:typeof Terminal,fit:typeof FitAddon,bridge:typeof chrome.webview,url:location.href,errors:window.terminalError||null})");
                        status("Terminal initialization: " + diagnostic);
                    }
                };
                await web.CoreWebView2.CallDevToolsProtocolMethodAsync("Runtime.enable", "{}");
                web.CoreWebView2.GetDevToolsProtocolEventReceiver("Runtime.exceptionThrown").DevToolsProtocolEventReceived += (_, args) => completion.TrySetException(new IOException("Terminal JavaScript failed: " + args.ParameterObjectAsJson));
                web.Source = new Uri("https://terminal.ssh-client.local/index.html");
            }
            catch (Exception error) { completion.TrySetException(error); status(error.Message); }
        };
    }

    private static async Task EnsureRuntimeAsync()
    {
        try { CoreWebView2Environment.GetAvailableBrowserVersionString(); return; }
        catch (WebView2RuntimeNotFoundException) { }
        var installer = Path.Combine(AppContext.BaseDirectory, "WebView2RuntimeInstaller.exe");
        if (!File.Exists(installer)) throw new IOException("WebView2 Runtime is missing. Run the bundled runtime installer or reinstall ssh-client.");
        using var process = Process.Start(new ProcessStartInfo(installer, "/silent /install") { UseShellExecute = false, CreateNoWindow = true });
        if (process == null) throw new IOException("Cannot start the bundled WebView2 installer.");
        await process.WaitForExitAsync();
        if (process.ExitCode != 0) throw new IOException("WebView2 installation failed. Run WebView2RuntimeInstaller.exe and try again.");
        CoreWebView2Environment.GetAvailableBrowserVersionString();
    }

    private async void MessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (stop.IsCancellationRequested || args.Source != "https://terminal.ssh-client.local/index.html") return;
        try
        {
            var message = JsonSerializer.Deserialize<JsonElement>(args.WebMessageAsJson);
            switch (message.GetProperty("type").GetString())
            {
                case "palette":
                    (owner as MainWindow)?.OpenCommandPalette();
                    break;
                case "ready":
                    if (!ready) { ready = true; await ApplySettingsAsync(); _ = PollAsync(); completion.TrySetResult(); }
                    break;
                case "input":
                    pendingInput.Enqueue(message.GetProperty("data").GetString()!);
                    if (!sending) await SendInputsAsync();
                    break;
                case "resize":
                    await api.PostAsync($"sessions/{SessionId}/resize", new { cols = message.GetProperty("cols").GetInt32(), rows = message.GetProperty("rows").GetInt32() }, stop.Token);
                    break;
            }
        }
        catch (Exception error) when (error is not OperationCanceledException) { status(error.Message); }
        catch (OperationCanceledException) { }
    }

    private async Task SendInputsAsync()
    {
        sending = true;
        try { while (pendingInput.TryDequeue(out var data)) await api.PostAsync($"sessions/{SessionId}/input", new { data }, stop.Token); }
        finally { sending = false; }
    }

    public async Task ApplySettingsAsync()
    {
        if (!ready) return;
        var settings = await api.GetAsync("settings", stop.Token);
        web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new { type = "settings", settings }));
    }

    private async Task PollAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            try
            {
                var snapshot = await api.GetAsync($"sessions/{SessionId}?since={cursor}", stop.Token);
                web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new { type = "output", snapshot }));
                cursor = snapshot.GetProperty("cursor").GetInt64();
                var state = snapshot.GetProperty("status").GetString();
                stateChanged?.Invoke(state switch { "connected" => "Connected", "connecting" => "Connecting", "error" => "Failed", "disconnected" => "Disconnected", _ => state ?? "Unknown" });
                status(state == "error" ? snapshot.GetProperty("error").GetString() ?? "Connection failed" : state ?? "");
                if (snapshot.TryGetProperty("host_key_prompt", out var prompt) && prompt.ValueKind == JsonValueKind.Object)
                {
                    stateChanged?.Invoke("Awaiting host approval");
                    var details = prompt.GetProperty("details");
                    var changed = prompt.GetProperty("type").GetString() == "host_key_changed";
                    var fingerprint = details.GetProperty(changed ? "new_fingerprint" : "fingerprint").GetString();
                    var text = $"{details.GetProperty("host").GetString()}:{details.GetProperty("port").GetInt32()}\n\n";
                    if (changed) text += "The saved host key has changed. Verify this with the server administrator.\nPrevious: " + details.GetProperty("old_fingerprint").GetString() + "\n";
                    text += "Fingerprint: " + fingerprint + "\n\nTrust this server?";
                    var accept = ConfirmHostKeyForSmoke?.Invoke(text) ?? (MessageBox.Show(owner, text, "Verify SSH host key", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes);
                    await api.PostAsync($"sessions/{SessionId}/{(accept ? "trust" : "disconnect")}", new { }, stop.Token);
                }
                if (snapshot.TryGetProperty("auth_prompt", out var auth) && auth.ValueKind == JsonValueKind.Object)
                {
                    stateChanged?.Invoke("Awaiting authentication");
                    var prompts = auth.GetProperty("prompts").EnumerateArray().ToArray();
                    var fields = prompts.Select((p, i) => new Field(i.ToString(), p.GetProperty("text").GetString()!, Secret: !p.GetProperty("echo").GetBoolean()));
                    var dialog = new FormDialog(owner, "SSH authentication", fields, "Continue", auth.GetProperty("instruction").GetString());
                    if (dialog.ShowDialog() == true)
                        await api.PostAsync($"sessions/{SessionId}/answer", new { challenge = auth.GetProperty("challenge").GetString(), answers = Enumerable.Range(0, prompts.Length).Select(i => dialog.Values[i.ToString()]).ToArray() }, stop.Token);
                    else await api.PostAsync($"sessions/{SessionId}/disconnect", new { }, stop.Token);
                }
            }
            catch (OperationCanceledException) { break; }
            catch (Exception error) { stateChanged?.Invoke("Backend unavailable"); status(error.Message); }
            try { await Task.Delay(100, stop.Token); } catch (OperationCanceledException) { break; }
        }
    }

    public void Dispose() { if (IsDisposed) return; IsDisposed = true; stop.Cancel(); completion.TrySetCanceled(); web.Dispose(); }

    internal Task<string> SendSmokeInputAsync(string input) => web.CoreWebView2.ExecuteScriptAsync("window.chrome.webview.postMessage(" + JsonSerializer.Serialize(new { type = "input", data = input }) + ");");
    internal async Task<string> ReadScreenAsync()
    {
        var text = await web.CoreWebView2.ExecuteScriptAsync("Array.from({length:terminal.buffer.active.length},(_,i)=>terminal.buffer.active.getLine(i).translateToString(true)).join('\\n')");
        return JsonSerializer.Deserialize<string>(text) ?? "";
    }
}
