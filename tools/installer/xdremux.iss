; XDRemux Windows installer (Inno Setup 6)
;
; Build: flutter build windows --release
;        iscc tools\installer\xdremux.iss
;
; Produces: apps\flutter\build\installer\XDRemuxSetup-<version>.exe

#define AppName "XDRemux"
#ifndef AppVersion
#define AppVersion "0.1.9"
#endif
#define AppPublisher "BeetMan"
#define AppURL "https://github.com/BeetMan/XDRemux-Flutter"
#define AppExeName "xdremux.exe"
#define BuildDir "..\..\apps\flutter\build\windows\x64\runner\Release"
#define OutDir "..\..\apps\flutter\build\installer"

[Setup]
AppId={{7E9F2A41-3B6D-4E8A-9C2F-1D5B8A0E6F3C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutDir}
OutputBaseFilename=XDRemuxSetup-{#AppVersion}
SetupIconFile=..\..\apps\flutter\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#AppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; AppUserModelId is required for WinRT toast notifications to display.
; It must match the appUserModelId in notification_service.dart.
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; AppUserModelID: "BeetMan.XDRemux"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon; AppUserModelID: "BeetMan.XDRemux"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
