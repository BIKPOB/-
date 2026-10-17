#define AppVersion "0.10.0"
[Setup]
AppId={{58DF1A93-00CD-4EAE-80B7-870198C92D37}
AppName=Quiet VPN
AppVersion={#AppVersion}
DefaultDirName={autopf}\Quiet VPN
DefaultGroupName=Quiet VPN
OutputDir=dist-windows
OutputBaseFilename=quiet-vpn-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
MinVersion=10.0
WizardStyle=modern
CloseApplications=yes
SetupMutex=QuietVPNInstaller
[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Quiet VPN"; Filename: "{app}\quiet_vpn.exe"
Name: "{autodesktop}\Quiet VPN"; Filename: "{app}\quiet_vpn.exe"; Tasks: desktopicon
[Tasks]
Name: desktopicon; Description: "Создать ярлык на рабочем столе"; Flags: unchecked
Name: webview; Description: "Установить/обновить Microsoft Edge WebView2 для встроенного браузера (нужен интернет)"; Flags: unchecked
[Run]
Filename: "{app}\engines\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Установка Microsoft Visual C++ Runtime…"; Flags: waituntilterminated
Filename: "{app}\engines\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; Tasks: webview; Flags: waituntilterminated
Filename: "{app}\quiet_vpn.exe"; Description: "Запустить Quiet VPN"; Flags: nowait postinstall skipifsilent
[UninstallRun]
Filename: "{app}\engines\amneziawg.exe"; Parameters: "/uninstalltunnelservice QuietVPN-AWG"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveOwnedTunnel"; Check: HasOwnedTunnel

[Code]
function HasOwnedTunnel: Boolean;
begin
  Result := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\AmneziaWGTunnel$QuietVPN-AWG');
end;
