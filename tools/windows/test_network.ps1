$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../platform_templates/windows/network.ps1"
foreach($prefix in @('10.0.0.0/8','172.16.0.0/12','192.168.1.0/24','169.254.0.0/16','224.0.0.0/4','255.255.255.255/32','fe80::/64','fc00::/7','ff00::/8','::1/128')) {
 if(!(Test-LocalOnlyPrefix $prefix)){throw "Local route blocked: $prefix"}
}
foreach($prefix in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','104.16.0.0/13','192.168.0.0/15','::/0','::/1','2001:db8::/32','invalid')) {
 if(Test-LocalOnlyPrefix $prefix){throw "External or unknown route allowed: $prefix"}
}
$routes=@([pscustomobject]@{RouteMetric=0;InterfaceMetric=50},[pscustomobject]@{RouteMetric=10;InterfaceMetric=5})
$best=$routes | Sort-Object { Get-CombinedMetric $_ } | Select-Object -First 1
if((Get-CombinedMetric $best) -ne 15){throw 'Combined route metric is incorrect'}
'Network classification and combined metrics passed.'
