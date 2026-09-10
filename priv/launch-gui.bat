@echo off
setlocal

if defined SSH_CLIENT_PORT (
    set "PORT=%SSH_CLIENT_PORT%"
) else (
    set "PORT=4000"
)

set "URL=http://127.0.0.1:%PORT%/hosts"
set "USER_DATA_DIR=%APPDATA%\ssh-client\gui_profile"
set "APP_FLAGS=--app=%URL% --user-data-dir="%USER_DATA_DIR%" --window-size=1120,740 --app-id=ssh-client --no-first-run --disable-extensions --disable-features=Translate,OptimizationHints"

:: 1. Health check & background daemon startup
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -Uri '%URL%' -UseBasicParsing -TimeoutSec 1; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    :: Clear any stuck Erlang/OTP processes from a previous failed launch.
    :: Without this, a zombie erl.exe causes "node name in use" and blocks every
    :: subsequent start attempt, manifesting as the 20-second timeout error.
    taskkill /F /IM erl.exe /T >nul 2>&1
    taskkill /F /IM epmd.exe /T >nul 2>&1
    timeout /t 2 /nobreak >nul

    set "DAEMON_BAT="
    if exist "%~dp0ssh_client.bat" (
        set "DAEMON_BAT=%~dp0ssh_client.bat"
    ) else if exist "%~dp0..\_build\prod\rel\ssh_client\bin\ssh_client.bat" (
        set "DAEMON_BAT=%~dp0..\_build\prod\rel\ssh_client\bin\ssh_client.bat"
    )

    if defined DAEMON_BAT (
        start "" /b "%DAEMON_BAT%" start
    )

    :: Health check polling loop with timeout (40 retries * 500ms = 20s max timeout)
    powershell -NoProfile -Command "$ready = $false; for ($i = 0; $i -lt 40; $i++) { try { $r = Invoke-WebRequest -Uri '%URL%' -UseBasicParsing -TimeoutSec 1; if ($r.StatusCode -eq 200) { $ready = $true; break } } catch { Start-Sleep -Milliseconds 500 } }; if ($ready) { exit 0 } else { exit 1 }" >nul 2>&1
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] ssh-client backend failed to respond on port %PORT% within the timeout period. >&2
        powershell -NoProfile -Command "[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null; [System.Windows.Forms.MessageBox]::Show('Failed to start ssh-client backend server within the timeout period. Please check application logs.', 'ssh-client Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)" >nul 2>&1
        exit /b 1
    )
)

:: 2. Locate Microsoft Edge or Google Chrome executable (64-bit, 32-bit, LocalAppData, PATH)
set "BROWSER_EXE="

:: Check Microsoft Edge paths
if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" (
    set "BROWSER_EXE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
) else if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" (
    set "BROWSER_EXE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
) else if defined ProgramW6432 if exist "%ProgramW6432%\Microsoft\Edge\Application\msedge.exe" (
    set "BROWSER_EXE=%ProgramW6432%\Microsoft\Edge\Application\msedge.exe"
) else if exist "%LocalAppData%\Microsoft\Edge\Application\msedge.exe" (
    set "BROWSER_EXE=%LocalAppData%\Microsoft\Edge\Application\msedge.exe"
)

:: Check Google Chrome paths
if not defined BROWSER_EXE (
    if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" (
        set "BROWSER_EXE=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
    ) else if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" (
        set "BROWSER_EXE=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
    ) else if defined ProgramW6432 if exist "%ProgramW6432%\Google\Chrome\Application\chrome.exe" (
        set "BROWSER_EXE=%ProgramW6432%\Google\Chrome\Application\chrome.exe"
    ) else if exist "%LocalAppData%\Google\Chrome\Application\chrome.exe" (
        set "BROWSER_EXE=%LocalAppData%\Google\Chrome\Application\chrome.exe"
    )
)

:: Check PATH for msedge
if not defined BROWSER_EXE (
    for /f "delims=" %%i in ('where msedge.exe 2^>nul') do (
        if not defined BROWSER_EXE set "BROWSER_EXE=%%i"
    )
)

:: Check PATH for chrome
if not defined BROWSER_EXE (
    for /f "delims=" %%i in ('where chrome.exe 2^>nul') do (
        if not defined BROWSER_EXE set "BROWSER_EXE=%%i"
    )
)

:: 3. Launch isolated window or fallback to default browser
if defined BROWSER_EXE (
    start "" "%BROWSER_EXE%" %APP_FLAGS%
) else (
    start "" "%URL%"
)

endlocal
