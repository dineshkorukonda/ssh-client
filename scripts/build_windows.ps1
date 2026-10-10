param([switch]$SkipRuntimeDownload)
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $releaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '_build/prod/rel/ssh_client'))
    if (-not $releaseRoot.StartsWith($repoRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Release output escaped the repository.' }
    if (Test-Path -LiteralPath $releaseRoot) { Remove-Item -LiteralPath $releaseRoot -Recurse -Force }
    $env:MIX_ENV = "prod"
    mix release ssh_client --overwrite
    if ($LASTEXITCODE -ne 0) { throw "OTP release build failed." }
    $version = python scripts/sync_release.py --get-current
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the release version.' }
    dotnet publish windows/native/SSHClient.Windows.csproj -c Release -o _build/prod/rel/ssh_client --warnaserror "-p:Version=$version" "-p:AssemblyVersion=$version.0" "-p:FileVersion=$version.0"
    if ($LASTEXITCODE -ne 0) { throw "Native Windows build failed." }
    Copy-Item -LiteralPath windows/app.ico -Destination _build/prod/rel/ssh_client/app.ico
    if (-not $SkipRuntimeDownload) {
        $runtimeDir = Join-Path $repoRoot "windows/runtime"
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
        $runtime = Join-Path $runtimeDir "WebView2RuntimeInstaller.exe"
        if (-not (Test-Path -LiteralPath $runtime)) {
            Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2124701' -OutFile $runtime
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $runtime
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            throw "WebView2 offline installer signature validation failed."
        }
        Copy-Item -LiteralPath $runtime -Destination _build/prod/rel/ssh_client/WebView2RuntimeInstaller.exe
    }
    $required = @('ssh-client.exe','bin/ssh_client.bat','terminal/index.html','terminal/terminal.js','terminal/xterm.min.js','terminal/xterm-addon-fit.min.js','terminal/xterm.min.css')
    foreach ($file in $required) { if (-not (Test-Path -LiteralPath (Join-Path '_build/prod/rel/ssh_client' $file))) { throw "Missing packaged file: $file" } }
    Write-Output "Native Windows package assembled."
} finally { Pop-Location }
