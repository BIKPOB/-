param([Parameter(Mandatory=$true)][string]$MsiPath)
$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $MsiPath).Path
if ([IO.Path]::GetExtension($path) -ne '.msi') { throw 'Expected official OpenVPN Community MSI.' }
$signature = Get-AuthenticodeSignature -LiteralPath $path
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'OpenVPN') {
    throw 'MSI must have a valid OpenVPN publisher signature.'
}
$process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -Verb RunAs -Wait -PassThru `
    -ArgumentList @('/i', ('"' + $path + '"'), '/passive', '/norestart')
if ($process.ExitCode -notin @(0, 3010)) { throw "Installer failed: $($process.ExitCode)" }
Write-Output 'OpenVPN runtime installed. Start Quiet VPN as Administrator.'
