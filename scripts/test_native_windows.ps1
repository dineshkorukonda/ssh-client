param([string]$ReleaseRoot = "_build/prod/rel/ssh_client")
$ErrorActionPreference = "Stop"
$ReleaseRoot = (Resolve-Path -LiteralPath $ReleaseRoot).Path
$exe = Join-Path $ReleaseRoot "ssh-client.exe"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssh-client-native-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$elixir = (Get-Command elixir.bat -ErrorAction Stop).Source
$script = Join-Path $PSScriptRoot "native_smoke_fixture.exs"
$command = '/d /s /c ""' + $elixir + '" --no-halt "' + $script + '" "' + $fixtureRoot + '""'
$fixture = Start-Process -FilePath "$env:SystemRoot/System32/cmd.exe" -ArgumentList $command -WindowStyle Hidden -PassThru
$previousKnownHosts = $env:SSH_CLIENT_KNOWN_HOSTS_FILE
$previousHosts = $env:SSH_CLIENT_SERVERS_CONFIG
$previousDatabase = $env:SSH_CLIENT_DATABASE_PATH
try {
    $ready = Join-Path $fixtureRoot "port"
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $ready); $i++) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path -LiteralPath $ready)) { throw "Local SSH fixture did not start." }
    $env:SSH_CLIENT_KNOWN_HOSTS_FILE = Join-Path $fixtureRoot "known_hosts"
    $env:SSH_CLIENT_SERVERS_CONFIG = Join-Path $fixtureRoot "hosts.json"
    $env:SSH_CLIENT_DATABASE_PATH = Join-Path $fixtureRoot "workspaces.db"
    $report = Join-Path $fixtureRoot "report.json"
    $key = (Resolve-Path -LiteralPath "test/fixtures/docker/ssh-target/id_ed25519").Path
    $arguments = '--terminal-smoke "' + $report + '" ' + (Get-Content -LiteralPath $ready) + ' "' + $key + '"'
    $native = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (-not $native.WaitForExit(60000)) { Stop-Process -Id $native.Id -Force; throw "Native terminal smoke timed out." }
    $result = Get-Content -LiteralPath $report -Raw
    if ($native.ExitCode -ne 0) { throw "Native terminal smoke failed: $result" }
    $decoded = $result | ConvertFrom-Json
    if (-not ($decoded.ready -and $decoded.terminal -and $decoded.sftp)) { throw "Native terminal or SFTP validation failed." }
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
    foreach ($screen in @('hosts.png','hosts-compact.png','connection.png','host-editor.png')) { if (-not (Test-Path -LiteralPath (Join-Path $design $screen))) { throw "Missing design screen: $screen" } }
    Write-Output "Native validation passed: backend startup, WebView2 rendering, terminal input/output, SFTP, process cleanup."
    Write-Output "Artifacts: $fixtureRoot"
} finally {
    $env:SSH_CLIENT_KNOWN_HOSTS_FILE = $previousKnownHosts
    $env:SSH_CLIENT_SERVERS_CONFIG = $previousHosts
    $env:SSH_CLIENT_DATABASE_PATH = $previousDatabase
    if (-not $fixture.HasExited) { & "$env:SystemRoot/System32/taskkill.exe" /PID $fixture.Id /T /F | Out-Null }
}
