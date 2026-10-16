param([string]$ReleaseRoot = "_build/prod/rel/ssh_client")
$ErrorActionPreference = "Stop"
$ReleaseRoot = (Resolve-Path -LiteralPath $ReleaseRoot).Path
$exe = Join-Path $ReleaseRoot "ssh-client.exe"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssh-client-native-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
if ($env:GITHUB_OUTPUT) { "artifact_dir=$fixtureRoot" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
$elixir = (Get-Command elixir.bat -ErrorAction Stop).Source
$script = Join-Path $PSScriptRoot "native_smoke_fixture.exs"
$command = '/d /s /c ""' + $elixir + '" --no-halt "' + $script + '" "' + $fixtureRoot + '""'
$fixture = Start-Process -FilePath "$env:SystemRoot/System32/cmd.exe" -ArgumentList $command -WindowStyle Hidden -PassThru
$previousKnownHosts = $env:SSH_CLIENT_KNOWN_HOSTS_FILE
$previousHosts = $env:SSH_CLIENT_SERVERS_CONFIG
$previousDatabase = $env:SSH_CLIENT_DATABASE_PATH
$previousSshHome = $env:SSH_CLIENT_SSH_HOME
try {
    $ready = Join-Path $fixtureRoot "port"
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $ready); $i++) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path -LiteralPath $ready)) { throw "Local SSH fixture did not start." }
    $env:SSH_CLIENT_KNOWN_HOSTS_FILE = Join-Path $fixtureRoot "known_hosts"
    $env:SSH_CLIENT_SERVERS_CONFIG = Join-Path $fixtureRoot "hosts.json"
    $env:SSH_CLIENT_DATABASE_PATH = Join-Path $fixtureRoot "workspaces.db"
    $env:SSH_CLIENT_SSH_HOME = $fixtureRoot
    $report = Join-Path $fixtureRoot "report.json"
    $key = (Resolve-Path -LiteralPath "test/fixtures/docker/ssh-target/id_ed25519").Path
    $sshDirectory = Join-Path $fixtureRoot '.ssh'
    New-Item -ItemType Directory -Path $sshDirectory | Out-Null
    Copy-Item -LiteralPath $key -Destination (Join-Path $sshDirectory 'id_ed25519')
    $arguments = '--terminal-smoke "' + $report + '" ' + (Get-Content -LiteralPath $ready) + ' "' + $key + '"'
    $native = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (-not $native.WaitForExit(120000)) {
        $progress = if (Test-Path -LiteralPath ($report + '.progress')) { Get-Content -LiteralPath ($report + '.progress') } else { 'startup' }
        Stop-Process -Id $native.Id -Force
        throw "Native journey smoke timed out during: $progress. Artifacts: $fixtureRoot"
    }
    if (-not (Test-Path -LiteralPath $report)) { throw "Native process exited with code $($native.ExitCode) without a report. Artifacts: $fixtureRoot" }
    $result = Get-Content -LiteralPath $report -Raw
    if ($native.ExitCode -ne 0) { throw "Native terminal smoke failed: $result" }
    $decoded = $result | ConvertFrom-Json
    foreach ($journey in @('ready','terminal','sftp','files_page','workbench_layout','session_lifecycle','host_editor','host_key_flow','update_controls','preferences','palette','accessible_names','connection_dialog','host_trust_rejection')) { if (-not $decoded.$journey) { throw "Native journey validation failed: $journey" } }
    Start-Sleep -Milliseconds 500
    $prefix = $ReleaseRoot.TrimEnd('\') + '\'
    $orphans = Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
    if ($orphans) { throw "Native exit left owned release processes running." }
    $screenshot = Join-Path $fixtureRoot "native-window.png"
    $render = Start-Process -FilePath $exe -ArgumentList ('--smoke-test "' + $screenshot + '"') -WindowStyle Hidden -PassThru
    if (-not $render.WaitForExit(15000)) { Stop-Process -Id $render.Id -Force; throw "Native render timed out." }
    if ($render.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $screenshot)) { throw "Native window render failed." }
    $design = Join-Path $fixtureRoot "design"
    $render = Start-Process -FilePath $exe -ArgumentList ('--design-smoke "' + $design + '"') -WindowStyle Hidden -PassThru
    if (-not $render.WaitForExit(15000)) { Stop-Process -Id $render.Id -Force; throw "Native design render timed out." }
    if ($render.ExitCode -ne 0) { throw "Native dialog theme validation failed." }
    foreach ($screen in @('hosts.png','hosts-compact.png','hosts-minimum.png','hosts-150dpi.png','connection.png','connection-stage.png','connection-failed.png','host-editor.png','add-host-page.png','hosts_light.png','sftp_dark.png','keys_dark.png')) { if (-not (Test-Path -LiteralPath (Join-Path $design $screen))) { throw "Missing design screen: $screen" } }
    foreach ($width in @(1536,1280,1024,720)) {
        foreach ($page in @('dashboard','hosts','keys','settings','sftp','session')) {
            if (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot "workbench/$page-$width.png"))) { throw "Missing connected layout capture: $page-$width" }
        }
    }
    Write-Output "Native validation passed: backend startup, WebView2 rendering, terminal input/output, SFTP, process cleanup."
    Write-Output "Artifacts: $fixtureRoot"
} finally {
    $env:SSH_CLIENT_KNOWN_HOSTS_FILE = $previousKnownHosts
    $env:SSH_CLIENT_SERVERS_CONFIG = $previousHosts
    $env:SSH_CLIENT_DATABASE_PATH = $previousDatabase
    $env:SSH_CLIENT_SSH_HOME = $previousSshHome
    if (-not $fixture.HasExited) { & "$env:SystemRoot/System32/taskkill.exe" /PID $fixture.Id /T /F | Out-Null }
}
