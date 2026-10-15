param([ValidateSet('network','tunnel','prepare','cleanup','check')][string]$Operation,
      [string]$Path, [ValidateSet('QuietVPN-Xray','QuietVPN-AWG')][string]$Alias='QuietVPN-Xray')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
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
  $routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -in $physical.ifIndex } | Sort-Object RouteMetric)
  $a=if($routes.Count){$physical | Where-Object ifIndex -eq $routes[0].InterfaceIndex | Select-Object -First 1}else{$physical | Select-Object -First 1}
  if(!$a){ @{type='offline';session=''} | ConvertTo-Json -Compress; break }
  $medium=[int]$a.NdisPhysicalMedium
  $type=if($medium -in @(1,9)){'wifi'}elseif($medium -eq 8){'mobile'}else{'ethernet'}
  # Persist only a local hash to distinguish networks on the same adapter.
  $profile=Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
  $identity=([string]$a.InterfaceGuid)+'|'+([string]$profile.Name)
  $hash=[System.Security.Cryptography.SHA256]::Create()
  try { $session=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','') } finally { $hash.Dispose() }
  # Be conservative: an active virtual adapter may route the speed sample through another VPN.
  $virtual=@(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and !$_.HardwareInterface })
  @{type=$type;session=$session;vpnPresent=($virtual.Count -gt 0);ambiguous=($routes.Count -gt 1 -and $routes[0].RouteMetric -eq $routes[1].RouteMetric)} | ConvertTo-Json -Compress
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
