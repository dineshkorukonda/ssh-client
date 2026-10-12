; ssh-client — Inno Setup Script
; Produces a single-file .exe installer for Windows x64

#define AppName "ssh-client"
#define AppVersion "0.0.64"
#define AppPublisher "Dinesh Korukonda"
#define AppURL "https://github.com/dineshkorukonda/ssh-client"
#define AppExeName "ssh-client.exe"

[Setup]
AppId={{8F3C4A2B-1D6E-4F9A-B7C5-0E2D8A3F1C4B}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={localappdata}\Programs\{#AppName}
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
CloseApplications=yes
RestartApplications=no
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
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#AppExeName}"; Parameters: "--shutdown"; RunOnceId: "StopApplication"; Flags: runhidden waituntilterminated skipifdoesntexist

[Code]
// Request shutdown from this user's ssh-client instance; Restart Manager handles remaining file locks.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ErrorCode: Integer;
  AppPath: String;
begin
  Result := '';
  AppPath := ExpandConstant('{app}\{#AppExeName}');
  if FileExists(AppPath) then
    Exec(AppPath, '--shutdown', '', SW_HIDE, ewWaitUntilTerminated, ErrorCode);
end;
