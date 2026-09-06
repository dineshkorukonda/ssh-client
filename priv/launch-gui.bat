@echo off
setlocal

set "PORT=4000"
set "URL=http://127.0.0.1:%PORT%/hosts"
set "USER_DATA_DIR=%APPDATA%\ssh-client\gui_profile"
set "APP_FLAGS=--app=%URL% --user-data-dir="%USER_DATA_DIR%" --window-size=1120,740 --app-id=ssh-client --no-first-run --disable-extensions --disable-features=Translate,OptimizationHints"

:: 1. Start background daemon if not already responding
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/hosts' -UseBasicParsing -TimeoutSec 1; exit 0 } catch { exit 1 }" >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    start "" /b "%~dp0ssh_client.bat" start
    powershell -NoProfile -Command "$ready = $false; for ($i=0; $i -lt 20; $i++) { try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/hosts' -UseBasicParsing -TimeoutSec 1; if ($r.StatusCode -eq 200) { $ready = $true; break } } catch { Start-Sleep -Milliseconds 300 } }; if (-not $ready) { Start-Sleep -Seconds 1 }" >nul 2>&1
)

:: 2. Locate Microsoft Edge or Google Chrome executable
set "BROWSER_EXE="
if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" (
    set "BROWSER_EXE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
) else if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" (
    set "BROWSER_EXE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
) else if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" (
    set "BROWSER_EXE=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
) else if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" (
    set "BROWSER_EXE=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
) else if exist "%LocalAppData%\Google\Chrome\Application\chrome.exe" (
    set "BROWSER_EXE=%LocalAppData%\Google\Chrome\Application\chrome.exe"
)

:: 3. Launch isolated window and monitor lifecycle
if defined BROWSER_EXE (
    start /wait "" "%BROWSER_EXE%" %APP_FLAGS%
) else (
    where msedge >nul 2>&1
    if %ERRORLEVEL% EQU 0 (
        start /wait "" msedge %APP_FLAGS%
    ) else (
        where chrome >nul 2>&1
        if %ERRORLEVEL% EQU 0 (
            start /wait "" chrome %APP_FLAGS%
        ) else (
            start "" "%URL%"
            goto :skip_stop
        )
    )
)

:: 4. Clean shutdown when GUI window is closed
call "%~dp0ssh_client.bat" stop >nul 2>&1
taskkill /F /T /IM erl.exe >nul 2>&1
taskkill /F /T /IM epmd.exe >nul 2>&1

:skip_stop
endlocal
