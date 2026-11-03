param([string]$Bundle='build/windows/x64/runner/Release')
$ErrorActionPreference='Stop'
$engines=Join-Path (Resolve-Path $Bundle) 'engines'
$network=& "$engines/network.ps1" -Operation network | ConvertFrom-Json
if($network.ambiguous -or $network.vpnPresent -or !$network.physicalInterface){throw 'Direct physical interface required'}
$config=Join-Path $env:RUNNER_TEMP 'reserve-blackhole.json'
@{
 log=@{loglevel='warning'}
 inbounds=@(@{tag='tun';protocol='tun';settings=@{
  name='QuietVPN-Xray';mtu=1280;gateway=@('172.29.211.1/30','fd7a:115c:a1e0::1/126')
  dns=@('1.1.1.1');autoSystemRoutingTable=@('0.0.0.0/0','::/0');autoOutboundsInterface='auto'
 }})
 outbounds=@(@{protocol='blackhole';settings=@{}})
} | ConvertTo-Json -Depth 12 | Set-Content $config -Encoding utf8
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
 dart run tools/windows/reserve_smoke.dart "$engines/xray.exe" "$($network.physicalInterface)"
 if($LASTEXITCODE -ne 0){throw 'Reserve physical route test failed'}
} finally {
 if($p -and !$p.HasExited){Stop-Process -Id $p.Id -Force;$p.WaitForExit()}
 & "$engines/network.ps1" -Operation cleanup
 Remove-Item $config -ErrorAction SilentlyContinue
}
