; ssh-client — Inno Setup Script
; Produces a single-file .exe installer for Windows x64

#define AppName "ssh-client"
#define AppVersion "0.0.10"
#define AppPublisher "Dinesh Korukonda"
#define AppURL "https://github.com/dineshkorukonda/ssh-client"
#define AppExeName "ssh_client.bat"

[Setup]
AppId={{8F3C4A2B-1D6E-4F9A-B7C5-0E2D8A3F1C4B}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
LicenseFile=..\LICENSE
OutputDir=..\installer
OutputBaseFilename=ssh-client-setup-v{#AppVersion}-windows-x64
SetupIconFile=app.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\app.ico

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Ship the entire OTP release tree
Source: "..\_build\prod\rel\ssh_client\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "app.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "wscript.exe"; Parameters: """{app}\bin\launch-gui.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#AppName}"; Filename: "wscript.exe"; Parameters: """{app}\bin\launch-gui.vbs"""; Tasks: desktopicon; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"

[Run]
Filename: "{app}\bin\launch-gui.vbs"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: shellexec nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\bin\{#AppExeName}"; Parameters: "stop"; RunOnceId: "StopService"; Flags: nowait

[Code]
// Close any running daemon instances before installation begins to prevent locked file errors
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ErrorCode: Integer;
begin
  Result := '';
  Exec('taskkill.exe', '/F /IM erl.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ErrorCode);
  Exec('taskkill.exe', '/F /IM werl.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ErrorCode);
  Exec('taskkill.exe', '/F /IM beam.smp /T', '', SW_HIDE, ewWaitUntilTerminated, ErrorCode);
  Exec('taskkill.exe', '/F /IM epmd.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ErrorCode);
end;
