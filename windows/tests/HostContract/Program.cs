using System.Text.Json;
using SSHClient.Windows;

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

// Fresh editor and ad-hoc connection models must use the backend's required field.
var created = new Host { Address = "created.example", User = "deploy", Port = 2222 };
var document = JsonSerializer.SerializeToElement(created, DesktopClient.Json);
Require(document.TryGetProperty("host", out var address) && address.GetString() == created.Address,
    "New hosts must serialize their address as host.");
Require(!document.TryGetProperty("address", out _), "Do not send a second address field.");
Require(document.GetProperty("port").GetInt32() == 2222, "Preserve the SSH port.");

var saved = JsonSerializer.Deserialize<Host>("""
    {"id":"saved","name":"Saved host","host":"before.example","user":"deploy",
     "port":2222,"default_auth_method":"password","favorite":true,
     "tags":["production"],"checks":[{"type":"systemctl","name":"sshd"}],
     "last_connected_at":"2026-10-12T00:00:00Z"}
    """, DesktopClient.Json)!;
Require(saved.Address == "before.example", "Load the backend host field into the editor address.");
Require(saved.Extra is not null && !saved.Extra.ContainsKey("host"),
    "The endpoint must not be captured as opaque extension data.");

// Edit copies must replace the destination while retaining unrelated backend metadata.
var edited = saved.Copy();
edited.Address = "after.example";
edited.Tags[0] = "staging";
var editedJson = JsonSerializer.Serialize(edited, DesktopClient.Json);
var editedDocument = JsonSerializer.Deserialize<JsonElement>(editedJson);
Require(editedDocument.GetProperty("host").GetString() == "after.example", "Send the edited destination.");
Require(editedDocument.EnumerateObject().Count(p => p.Name == "host") == 1,
    "Never serialize duplicate endpoint fields.");
Require(editedDocument.GetProperty("checks")[0].GetProperty("name").GetString() == "sshd",
    "Preserve monitoring checks during address edits.");
Require(editedDocument.GetProperty("last_connected_at").GetString() == "2026-10-12T00:00:00Z",
    "Preserve connection history metadata.");
Require(saved.Address == "before.example" && saved.Tags[0] == "production",
    "Canceling an edit must leave the original host unchanged.");
Require(editedDocument.GetProperty("default_auth_method").GetString() == "password",
    "Preserve authentication preferences.");
var reloaded = JsonSerializer.Deserialize<Host>(editedJson, DesktopClient.Json)!;
Require(reloaded.Address == "after.example" && reloaded.Description == "deploy@after.example:2222",
    "Reloaded hosts and connection labels must use the edited destination.");
Console.WriteLine("Host contract regression checks passed: create, load, copy/edit, metadata and reload.");
