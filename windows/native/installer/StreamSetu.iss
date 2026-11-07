; Installer for StreamSetu for Windows. Built by Scripts\package.ps1 with Inno Setup 6 (https://jrsoftware.org/isinfo.php).
; The version comes from the environment so the installer, the program and the release notes always agree.
#define AppVersion GetEnv("STREAMSETU_VERSION")
#if AppVersion == ""
  #error STREAMSETU_VERSION is not set. Run Scripts\package.ps1, which sets it.
#endif

[Setup]
AppId={{6F1B3C2E-8D47-4A59-B0E1-3C9A7D5E2F84}
AppName=StreamSetu
AppVersion={#AppVersion}
AppPublisher=StreamSetu
DefaultDirName={autopf}\StreamSetu
DefaultGroupName=StreamSetu
OutputDir=..\dist
OutputBaseFilename=StreamSetu-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
; Installed for the person using it: no administrator rights are asked for.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64
; An update replaces a running copy: the installer closes it and starts it again.
CloseApplications=yes
RestartApplications=yes
UninstallDisplayIcon={app}\StreamSetu.exe
WizardStyle=modern
DisableProgramGroupPage=yes

[Files]
Source: "{#GetEnv('STREAMSETU_PAYLOAD')}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs

[Icons]
Name: "{group}\StreamSetu"; Filename: "{app}\StreamSetu.exe"
Name: "{autodesktop}\StreamSetu"; Filename: "{app}\StreamSetu.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "A shortcut on the desktop"; Flags: unchecked

[Run]
Filename: "{app}\StreamSetu.exe"; Description: "Open StreamSetu"; Flags: nowait postinstall skipifsilent
