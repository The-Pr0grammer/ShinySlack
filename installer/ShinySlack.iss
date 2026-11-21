#ifndef MyAppVersion
  #define MyAppVersion "0.1.0-beta"
#endif

#define MyAppName "ShinySlack"
#define MyAppPublisher "ShinySlack"
#define MyAppExe "Start-ShinySlack.cmd"

[Setup]
AppId={{6D65B1E8-3DF2-4A54-9A6E-7EDB4A63A2F1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\ShinySlack
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=ShinySlackSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
UninstallDisplayName={#MyAppName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
RestartApplications=no

[Files]
Source: "..\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ShinySlack"; Filename: "{app}\{#MyAppExe}"; WorkingDir: "{app}"; Comment: "Open ShinySlack"
Name: "{autoprograms}\ShinySlack Background"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Start-ShinySlack-Background.ps1"""; WorkingDir: "{app}"; Comment: "Start ShinySlack notification routing without opening the dashboard"
Name: "{autodesktop}\ShinySlack"; Filename: "{app}\{#MyAppExe}"; WorkingDir: "{app}"; Tasks: desktopicon; Comment: "Open ShinySlack"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Run]
Filename: "{app}\{#MyAppExe}"; WorkingDir: "{app}"; Description: "Launch ShinySlack"; Flags: postinstall nowait skipifsilent shellexec

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-ShinySlack.ps1"" -KeepFiles"; Flags: runhidden waituntilterminated; RunOnceId: "ShinySlackCleanup"

[UninstallDelete]
Type: files; Name: "{userstartup}\ShinySlack-Watcher.cmd"
Type: files; Name: "{userstartup}\ShinySlack-ChannelRouter.cmd"
Type: filesandordirs; Name: "{app}\channel-sounds"
Type: filesandordirs; Name: "{app}\wave-cache"
Type: files; Name: "{app}\*.log"
Type: files; Name: "{app}\*.json"
Type: files; Name: "{app}\*.pid"
Type: files; Name: "{app}\*.lock"
Type: files; Name: "{app}\*.mp3"
Type: files; Name: "{app}\stock_url.txt"
Type: files; Name: "{app}\agent.version"
Type: filesandordirs; Name: "{app}\backups"

