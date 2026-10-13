param([string]$Bundle='build/windows/x64/runner/Release')
$ErrorActionPreference='Stop'
$engines=Join-Path (Resolve-Path $Bundle) 'engines'
$probe=Join-Path $engines 'network.ps1'
& $probe -Operation check
& $probe -Operation network
$config=Join-Path $env:RUNNER_TEMP 'quiet-xray-smoke.json'
# Test fixture only: direct outbound validates the Windows TUN plumbing, not a VPN provider.
@{
 log=@{loglevel='warning'}
 inbounds=@(@{tag='tun';protocol='tun';settings=@{
  name='QuietVPN-Xray';mtu=1280;gateway=@('172.29.211.1/30','fd7a:115c:a1e0::1/126');dns=@('1.1.1.1');
  autoSystemRoutingTable=@('0.0.0.0/0','::/0');autoOutboundsInterface='auto';autoSystemWfpBlockLeak=@('dns','misconfigtun')
 }})
 outbounds=@(@{tag='proxy';protocol='freedom';settings=@{}})
} | ConvertTo-Json -Depth 12 | Set-Content $config -Encoding utf8
& "$engines/xray.exe" run -test -config $config
if($LASTEXITCODE -ne 0){throw 'Xray fixture config invalid'}
$p=$null
try {
 $p=Start-Process "$engines/xray.exe" -ArgumentList @('run','-config',('"'+$config+'"')) -WorkingDirectory $engines -PassThru -RedirectStandardError "$env:RUNNER_TEMP/xray-error.txt" -RedirectStandardOutput "$env:RUNNER_TEMP/xray-output.txt"
 $ready=$false
 for($i=0;$i -lt 20;$i++) {
  Start-Sleep -Milliseconds 500
  if($p.HasExited){ Get-Content "$env:RUNNER_TEMP/xray-error.txt"; throw 'Xray exited during smoke test' }
  $info=(& $probe -Operation tunnel -Alias QuietVPN-Xray | ConvertFrom-Json)
  if($info.ready){$ready=$true;break}
 }
 if(!$ready){throw 'Xray TUN interface/routes not ready'}
 $env:QUIET_TUNNEL_ADDRESS=$info.address
 dart run tools/windows/live_probe.dart
 if($LASTEXITCODE -ne 0){throw 'Bound DNS/HTTPS probe test failed'}
} finally {
 if($p -and !$p.HasExited){Stop-Process -Id $p.Id -Force; $p.WaitForExit()}
 & $probe -Operation cleanup
 Remove-Item $config -ErrorAction SilentlyContinue
 Remove-Item Env:QUIET_TUNNEL_ADDRESS -ErrorAction SilentlyContinue
}
# No real server credentials in CI: exercise the owned AWG service lifecycle only.
$private=Join-Path $env:RUNNER_TEMP 'quiet-awg-smoke'
& $probe -Operation prepare -Path $private
$config=Join-Path $private 'QuietVPN-AWG.conf'
$key=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$peer=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
@"
[Interface]
PrivateKey = $key
Address = 10.211.29.2/32
DNS = 1.1.1.1
[Peer]
PublicKey = $peer
Endpoint = 192.0.2.1:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
"@ | Set-Content $config -Encoding ascii
try {
 $install=Start-Process "$engines/amneziawg.exe" -ArgumentList @('/installtunnelservice', ('"'+$config+'"')) -Wait -PassThru
 if($install.ExitCode -ne 0){throw 'AWG service installation failed'}
 Start-Sleep -Seconds 3
 $service=Get-Service -Name 'AmneziaWGTunnel$QuietVPN-AWG'
 try { if($service.Status -ne 'Running'){throw 'AWG service not running'} } finally { $service.Dispose() }
} finally {
 $uninstall=Start-Process "$engines/amneziawg.exe" -ArgumentList @('/uninstalltunnelservice','QuietVPN-AWG') -Wait -PassThru
 if($uninstall.ExitCode -ne 0){throw 'AWG service removal failed'}
 Remove-Item $config -ErrorAction SilentlyContinue
}
$removed=$false
for($i=0;$i -lt 40;$i++) {
 & "$env:SystemRoot/System32/sc.exe" query 'AmneziaWGTunnel$QuietVPN-AWG' | Out-Null
 if($LASTEXITCODE -eq 1060){$removed=$true;break}
 Start-Sleep -Milliseconds 250
}
if(!$removed){throw 'Owned AWG service was not removed'}
# sc.exe returns 1060 for the expected absent service; do not propagate it as script failure.
$global:LASTEXITCODE=0
'Windows TUN, bound DNS/HTTPS, and AWG lifecycle passed.'
