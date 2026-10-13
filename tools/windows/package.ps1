param([string]$Bundle='build/windows/x64/runner/Release')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$dest=Join-Path (Resolve-Path $Bundle) 'engines'
New-Item -ItemType Directory -Force $dest | Out-Null
New-Item -ItemType Directory -Force 'windows-deps' | Out-Null
function Download-Checked($Url,$File,$Hash) {
 Invoke-WebRequest $Url -OutFile $File
 if((Get-FileHash $File -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash){throw "Checksum mismatch: $File"}
}
Download-Checked 'https://github.com/amnezia-vpn/amneziawg-windows-client/releases/download/3.1.0/amneziawg-amd64-3.1.0.msi' 'windows-deps/awg.msi' 'a1b48ea8699cd347832a3691d832004574ef8ad65bcf887611ac8acb99b7de8b'
$msi=(Resolve-Path 'windows-deps/awg.msi').Path
$extract=Join-Path (Resolve-Path 'windows-deps') 'awg'
$p=Start-Process msiexec.exe -ArgumentList @('/a', ('"'+$msi+'"'),'/qn',('TARGETDIR="'+$extract+'"')) -Wait -PassThru
if($p.ExitCode -notin @(0,3010)){throw "MSI extraction failed: $($p.ExitCode)"}
$awg=Get-ChildItem $extract -Recurse -Filter amneziawg.exe | Select-Object -First 1
if(!$awg){throw 'AmneziaWG executable missing'}
Copy-Item $awg.FullName (Join-Path $dest 'amneziawg.exe')
Download-Checked 'https://www.wintun.net/builds/wintun-0.14.1.zip' 'windows-deps/wintun.zip' '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'
Expand-Archive 'windows-deps/wintun.zip' 'windows-deps/wintun' -Force
Copy-Item 'windows-deps/wintun/wintun/bin/amd64/wintun.dll' $dest
Copy-Item 'xray-source/xray.exe' $dest
Copy-Item 'platform_templates/windows/network.ps1' $dest
New-Item -ItemType Directory -Force (Join-Path $Bundle 'licenses') | Out-Null
Copy-Item 'windows-deps/wintun/wintun/LICENSE.txt' (Join-Path $Bundle 'licenses/Wintun.txt')
Copy-Item 'xray-source/LICENSE' (Join-Path $Bundle 'licenses/Xray.txt')
Invoke-WebRequest 'https://raw.githubusercontent.com/amnezia-vpn/amneziawg-windows-client/3.1.0/COPYING' -OutFile (Join-Path $Bundle 'licenses/AmneziaWG.txt')
Copy-Item 'docs/windows-install.txt' (Join-Path $Bundle 'README-Windows.txt')
Copy-Item 'docs/windows-third-party.txt' (Join-Path $Bundle 'licenses/SOURCES.txt')
# Runtime browser dependency is installed by Microsoft Edge on most systems.
# Ship Microsoft's signed bootstrapper for machines where it is absent.
Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile (Join-Path $dest 'MicrosoftEdgeWebview2Setup.exe')
$sig=Get-AuthenticodeSignature (Join-Path $dest 'MicrosoftEdgeWebview2Setup.exe')
if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation'){throw 'Invalid WebView2 bootstrapper signature'}
Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile (Join-Path $dest 'vc_redist.x64.exe')
$sig=Get-AuthenticodeSignature (Join-Path $dest 'vc_redist.x64.exe')
if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation'){throw 'Invalid Visual C++ runtime signature'}
$hashes=[ordered]@{}
Get-ChildItem $dest -File | ForEach-Object {$hashes[$_.Name]=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
$hashes | ConvertTo-Json | Set-Content (Join-Path $dest 'SHA256.json') -Encoding utf8
