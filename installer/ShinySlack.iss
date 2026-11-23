#ifndef MyAppVersion
  #define MyAppVersion "2.7.12"
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
SetupIconFile=..\app\ShinySlack.ico
UninstallDisplayIcon={app}\ShinySlack.ico
AppComments=Custom Slack notification sounds, routing, and visual alerts
VersionInfoDescription=ShinySlack Windows notification companion
UninstallDisplayName={#MyAppName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
RestartApplications=no

[Files]
Source: "..\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ShinySlack"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Start-ShinySlack.ps1"" -QuietLaunch"; WorkingDir: "{app}"; IconFilename: "{app}\ShinySlack.ico"; Comment: "Open ShinySlack dashboard and notification alerts"
Name: "{autodesktop}\ShinySlack"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Start-ShinySlack.ps1"" -QuietLaunch"; WorkingDir: "{app}"; IconFilename: "{app}\ShinySlack.ico"; Tasks: desktopicon; Comment: "Open ShinySlack dashboard and notification alerts"
[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Start-ShinySlack.ps1"" -QuietLaunch"; WorkingDir: "{app}"; Description: "Open ShinySlack now"; Flags: postinstall nowait skipifsilent runhidden
[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-ShinySlack.ps1"" -KeepFiles"; Flags: runhidden waituntilterminated; RunOnceId: "ShinySlackCleanup"

[UninstallDelete]
Type: files; Name: "{userstartup}\ShinySlack-Watcher.cmd"
Type: files; Name: "{userstartup}\ShinySlack-ChannelRouter.cmd"
Type: files; Name: "{userstartup}\ShinySlack-PersistentAlerts.cmd"
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

