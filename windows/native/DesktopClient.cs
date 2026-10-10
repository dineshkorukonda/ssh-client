using System.Net.Http;
using System.IO;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace SSHClient.Windows;

public sealed class DesktopClient : IDisposable
{
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, PropertyNameCaseInsensitive = true };
    private readonly HttpClient http;
    public DesktopClient(int port, string token)
    {
        http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}/desktop/v1/"), Timeout = TimeSpan.FromMinutes(30) };
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
    }
    public async Task<JsonElement> RequestAsync(HttpMethod method, string route, object? data = null, CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(method, route);
        if (data != null) request.Content = JsonContent.Create(data, options: Json);
        using var response = await http.SendAsync(request, cancel);
        var result = await response.Content.ReadFromJsonAsync<JsonElement>(Json, cancel);
        if (!response.IsSuccessStatusCode) throw new IOException(result.TryGetProperty("error", out var error) ? error.GetString() : "Desktop request failed");
        return result;
    }
    public Task<JsonElement> GetAsync(string route, CancellationToken cancel = default) => RequestAsync(HttpMethod.Get, route, null, cancel);
    public Task<JsonElement> PostAsync(string route, object data, CancellationToken cancel = default) => RequestAsync(HttpMethod.Post, route, data, cancel);
    public void Dispose() => http.Dispose();
}
