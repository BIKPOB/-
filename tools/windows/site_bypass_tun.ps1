param([string]$Bundle='build/windows/x64/runner/Release')
$ErrorActionPreference='Stop'
$engines=Join-Path (Resolve-Path $Bundle) 'engines'
$network=& "$engines/network.ps1" -Operation network | ConvertFrom-Json
if($network.ambiguous -or $network.vpnPresent -or !$network.physicalInterface){throw 'Direct physical interface required'}
$config=Join-Path $env:RUNNER_TEMP 'site-bypass-tun.json'
dart run tools/windows/site_bypass_tun.dart config $config
if($LASTEXITCODE -ne 0){throw 'Bypass configuration generation failed'}
$p=$null
try {
 $p=Start-Process "$engines/xray.exe" -ArgumentList @('run','-config',('"'+$config+'"')) -PassThru
 $ready=$false
 for($i=0;$i -lt 20;$i++) {
  Start-Sleep -Milliseconds 500
  $info=& "$engines/network.ps1" -Operation tunnel -Alias QuietVPN-Xray | ConvertFrom-Json
  if($info.ready){$ready=$true;break}
 }
 if(!$ready){throw 'Blackhole TUN not ready'}
 dart run tools/windows/site_bypass_tun.dart check
 if($LASTEXITCODE -ne 0){throw 'Site bypass TUN test failed'}
} finally {
 if($p -and !$p.HasExited){Stop-Process -Id $p.Id -Force;$p.WaitForExit()}
 & "$engines/network.ps1" -Operation cleanup
 Remove-Item $config -ErrorAction SilentlyContinue
}
