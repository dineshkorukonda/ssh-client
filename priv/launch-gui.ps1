$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$binDir = $PSScriptRoot
if (-not $binDir) {
    $binDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$releaseRoot = Split-Path -Parent $binDir
$port = if ($env:SSH_CLIENT_PORT) { $env:SSH_CLIENT_PORT } else { "4000" }
$healthUrl = "http://127.0.0.1:$port/health"
$hostsUrl = "http://127.0.0.1:$port/hosts"
$logDir = Join-Path $env:APPDATA "ssh-client\logs"
$logFile = Join-Path $logDir "launcher.log"

function Write-LauncherLog {
    param([string]$Message)

    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$stamp] $Message"
}

function Test-BackendReady {
    foreach ($targetUrl in @($healthUrl, $hostsUrl)) {
        try {
            $request = [System.Net.WebRequest]::Create($targetUrl)
            $request.Method = "GET"
            $request.Timeout = 2000
            $request.Proxy = $null
            $response = $request.GetResponse()
            try {
                if ([int]$response.StatusCode -eq 200) {
                    return $true
                }
            } finally {
                $response.Close()
            }
        } catch {
            # Backend is not ready yet.
        }
    }

    return $false
}

function Get-DaemonBat {
    $installed = Join-Path $binDir "ssh_client.bat"
    if (Test-Path -LiteralPath $installed) {
        return $installed
    }

    $devRelease = Join-Path $binDir "..\..\_build\prod\rel\ssh_client\bin\ssh_client.bat"
    if (Test-Path -LiteralPath $devRelease) {
        return (Resolve-Path -LiteralPath $devRelease).Path
    }

    return $null
}

function Stop-OwnedErlang {
    $rootPrefix = $releaseRoot.TrimEnd("\", "/")
    Get-Process -Name erl, werl, epmd, erlexec, heart, inet_gethost -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Path -and $_.Path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        ForEach-Object {
            Write-LauncherLog "Stopping owned process $($_.Name) pid=$($_.Id)"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
}

function Start-Backend {
    $daemonBat = Get-DaemonBat
    if (-not $daemonBat) {
        throw "ssh_client.bat was not found next to the launcher."
    }

    Write-LauncherLog "Starting backend: $daemonBat"

    # Reset any inherited release environment variables so start_erl.data resolves properly
    $env:RELEASE_VSN = $null
    $env:ERTS_VSN = $null
    $env:REL_VSN_DIR = $null
    $env:RELEASE_SYS_CONFIG = $null
    $env:RELEASE_VM_ARGS = $null
    $env:RELEASE_REMOTE_VM_ARGS = $null
    $env:RELEASE_BOOT_SCRIPT = $null
    $env:RELEASE_BOOT_SCRIPT_CLEAN = $null
    $env:RELEASE_COMMAND = $null
    $env:RELEASE_PROG = $null
    $env:REL_EXEC = $null
    $env:REL_EXTRA = $null
    $env:REL_GOTO = $null

    Start-Process -FilePath $daemonBat -ArgumentList "start" -WorkingDirectory $releaseRoot -WindowStyle Hidden | Out-Null
}

function Get-BrowserExe {
    $roots = @(
        [Environment]::GetFolderPath("ProgramFiles"),
        [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"),
        [Environment]::GetFolderPath("LocalApplicationData")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $relativePaths = @(
        "Microsoft\Edge\Application\msedge.exe",
        "Google\Chrome\Application\chrome.exe",
        "BraveSoftware\Brave-Browser\Application\brave.exe"
    )

    foreach ($relativePath in $relativePaths) {
        foreach ($root in $roots) {
            $candidate = Join-Path $root $relativePath
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    foreach ($name in @("msedge.exe", "chrome.exe", "brave.exe")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            return $command.Source
        }
    }

    return $null
}

function Start-AppWindow {
    $browserExe = Get-BrowserExe
    $userDataDir = Join-Path $env:APPDATA "ssh-client\gui_profile"

    if ($browserExe) {
        Write-LauncherLog "Opening app window with $browserExe"
        $browserArgs = @(
            "--app=$hostsUrl",
            "--user-data-dir=$userDataDir",
            "--window-size=1120,740",
            "--app-id=ssh-client",
            "--no-first-run",
            "--disable-extensions",
            "--disable-features=Translate,OptimizationHints"
        )
        Start-Process -FilePath $browserExe -ArgumentList $browserArgs | Out-Null
        return
    }

    Write-LauncherLog "No Edge/Chrome/Brave found; opening $hostsUrl"
    Start-Process $hostsUrl | Out-Null
}

function Show-LaunchError {
    param([string]$Message)

    Write-LauncherLog $Message
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "$Message`r`n`r`nLog file: $logFile",
        "ssh-client Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

try {
    Write-LauncherLog "Launcher started (port=$port releaseRoot=$releaseRoot)"

    if (-not (Test-BackendReady)) {
        Stop-OwnedErlang
        Start-Sleep -Seconds 1
        Start-Backend

        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            if (Test-BackendReady) {
                $ready = $true
                break
            }

            Start-Sleep -Milliseconds 500
        }

        if (-not $ready) {
            Show-LaunchError "Failed to start ssh-client backend server within the timeout period. Please check application logs."
            exit 1
        }
    }

    Write-LauncherLog "Backend ready"
    Start-AppWindow
    exit 0
} catch {
    Show-LaunchError $_.Exception.Message
    exit 1
}
