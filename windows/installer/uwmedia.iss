; The Windows installer (Inno Setup 6), made from a built release folder
; (build\windows\x64\runner\Release with the tools in bin, after
; tool/bundle_tools.sh). The install paths are spec §13.2's: for the user
; alone in %LOCALAPPDATA%\Programs\uwmedia (the default, no admin rights),
; for every user in %ProgramFiles%\Christersson\uwmedia. The settings and
; data folders of §13.3 are outside it and stay when the app is removed.
;
;   ISCC.exe /DAppVersion=1.0.0 /DFileVersion=1.0.0.42
;     /DSourceDir=<release folder> /DOutputDir=dist
;     /DOutputName=UWMedia-windows-x64-setup windows\installer\uwmedia.iss

#ifndef AppVersion
  #error Pass /DAppVersion=<version>
#endif
#ifndef FileVersion
  #define FileVersion "0.0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#ifndef OutputName
  #define OutputName "UWMedia-windows-x64-setup"
#endif

[Setup]
; The same id for every version, so a newer one installs over the older.
AppId={{DA1BEFDA-8413-49EB-BF91-3CC454720259}
AppName=UWMedia
AppVersion={#AppVersion}
AppPublisher=Christersson
AppCopyright=Copyright (C) 2025 Mikael Christersson. MIT License.
VersionInfoVersion={#FileVersion}
VersionInfoCompany=Christersson
VersionInfoProductName=UWMedia
DefaultDirName={code:InstallDir}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\uwmedia.exe
UninstallDisplayName=UWMedia
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; What the build before left that this one may not have.
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\bin"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\UWMedia"; Filename: "{app}\uwmedia.exe"
Name: "{autodesktop}\UWMedia"; Filename: "{app}\uwmedia.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\uwmedia.exe"; Description: "{cm:LaunchProgram,UWMedia}"; Flags: nowait postinstall skipifsilent

[Code]
// Spec §13.2: per user without the vendor folder, for every user with it.
function InstallDir(Param: String): String;
begin
  if IsAdminInstallMode then
    Result := ExpandConstant('{commonpf64}\Christersson\uwmedia')
  else
    Result := ExpandConstant('{userpf}\uwmedia');
end;
