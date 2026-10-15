param([ValidateSet('network','tunnel','prepare','cleanup','check')][string]$Operation,
      [string]$Path, [ValidateSet('QuietVPN-Xray','QuietVPN-AWG')][string]$Alias='QuietVPN-Xray')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
# Local-only Hyper-V/WSL adapters do not carry the direct Internet sample.
# Unknown/malformed prefixes remain conservative and block measurement.
function Test-LocalOnlyPrefix([string]$Prefix) {
 try {
  $parts=$Prefix.Split('/')
  if($parts.Count -ne 2){ return $false }
  $ip=[Net.IPAddress]::Parse($parts[0]); $bits=[int]$parts[1]; $b=$ip.GetAddressBytes()
  if($b.Length -eq 4) {
   if($bits -lt 0 -or $bits -gt 32){return $false}
   return (($bits -ge 8 -and $b[0] -in @(0,10,127)) -or
    ($bits -ge 12 -and $b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
    ($bits -ge 16 -and (($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254))) -or
    ($bits -ge 4 -and $b[0] -ge 224 -and $b[0] -le 239) -or
    ($bits -eq 32 -and $ip.ToString() -eq '255.255.255.255'))
  }
  if($bits -lt 0 -or $bits -gt 128){return $false}
  return (($bits -ge 7 -and ($b[0] -band 254) -eq 252) -or
   ($bits -ge 10 -and $b[0] -eq 254 -and ($b[1] -band 192) -eq 128) -or
   ($bits -ge 8 -and $b[0] -eq 255) -or ($bits -eq 128 -and $ip.Equals([Net.IPAddress]::IPv6Loopback)))
 } catch { return $false }
}
function Get-CombinedMetric($Route) { return ([long]$Route.RouteMetric + [long]$Route.InterfaceMetric) }
switch ($Operation) {
 'check' {
  $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator required' }
  @{admin=$true} | ConvertTo-Json -Compress
 }
 'prepare' {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  $acl=Get-Acl -LiteralPath $Path
  $acl.SetAccessRuleProtection($true,$false)
  foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')) {
   $identity=[Security.Principal.SecurityIdentifier]::new($sid)
   $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
   $acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
 }
 'network' {
  $physical=@(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')
  $routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -in $physical.ifIndex } | Sort-Object { Get-CombinedMetric $_ })
  $a=if($routes.Count){$physical | Where-Object ifIndex -eq $routes[0].InterfaceIndex | Select-Object -First 1}else{$physical | Select-Object -First 1}
  if(!$a){ @{type='offline';session=''} | ConvertTo-Json -Compress; break }
  $medium=[int]$a.NdisPhysicalMedium
  $type=if($medium -in @(1,9)){'wifi'}elseif($medium -eq 8){'mobile'}else{'ethernet'}
  # Persist only a local hash to distinguish networks on the same adapter.
  $profile=Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
  $identity=([string]$a.InterfaceGuid)+'|'+([string]$profile.Name)
  $hash=[System.Security.Cryptography.SHA256]::Create()
  try { $session=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','') } finally { $hash.Dispose() }
  # Inspect routes, not merely the presence of an Up virtual adapter.
  $virtual=@(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and !$_.HardwareInterface })
  $external=@(Get-NetRoute -ErrorAction Stop | Where-Object { $_.InterfaceIndex -in $virtual.ifIndex -and !(Test-LocalOnlyPrefix $_.DestinationPrefix) })
  $linkMbps=[int]([double]$a.ReceiveLinkSpeed / 1000000)
  if($linkMbps -le 0){$linkMbps=$null}
  @{type=$type;session=$session;linkMbps=$linkMbps;vpnPresent=($external.Count -gt 0);ambiguous=($routes.Count -eq 0 -or ($routes.Count -gt 1 -and (Get-CombinedMetric $routes[0]) -eq (Get-CombinedMetric $routes[1])))} | ConvertTo-Json -Compress
 }
 'tunnel' {
  $a=Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
  $ip=Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq Preferred | Select-Object -First 1
  if(!$a -or !$ip -or $a.Status -ne 'Up'){ @{ready=$false} | ConvertTo-Json -Compress; break }
  $routes=@(Get-NetRoute -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | Where-Object DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1'))
  if(!$routes.Count){ @{ready=$false} | ConvertTo-Json -Compress; break }
  $s=Get-NetAdapterStatistics -Name $Alias
  @{ready=$true;address=$ip.IPAddress;received=[long]$s.ReceivedBytes;sent=[long]$s.SentBytes} | ConvertTo-Json -Compress
 }
 'cleanup' {
  # Touch only the interface owned by this application, never physical adapters.
  $a=Get-NetAdapter -Name 'QuietVPN-Xray' -ErrorAction SilentlyContinue
  if($a){ Get-NetRoute -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | Where-Object DestinationPrefix -in @('0.0.0.0/0','::/0','0.0.0.0/1','128.0.0.0/1','::/1','8000::/1') | Remove-NetRoute -Confirm:$false -ErrorAction Stop }
 }
}
