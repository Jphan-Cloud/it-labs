<#
.SYNOPSIS
    Verifies a Windows device after Autopilot / Intune enrollment.

.DESCRIPTION
    Runs on-device checks for the MD-102 Lab 01 zero-touch deployment:
    Entra join, MDM enrollment, standard-user rights, BitLocker, Secure Boot,
    firewall, Defender, and required apps. Prints PASS/FAIL per check.

.PARAMETER UserName
    The signed-in user who should NOT be a local administrator.

.EXAMPLE
    .\Test-DeviceReadiness.ps1 -UserName lab.user1

.NOTES
    Run from an elevated PowerShell 5.1 session (BitLocker and Secure Boot
    checks need admin rights). Use the LAPS account to elevate.
#>
[CmdletBinding()]
param(
    [string]$UserName = $env:USERNAME
)

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Check, [bool]$Passed, [string]$Detail)
    $results.Add([pscustomobject]@{
        Check  = $Check
        Result = if ($Passed) { 'PASS' } else { 'FAIL' }
        Detail = $Detail
    })
}

# 1. Entra ID join
$dsreg = dsregcmd /status
$joined = ($dsreg | Select-String 'AzureAdJoined\s*:\s*YES') -ne $null
Add-Result 'Entra ID joined' $joined (($dsreg | Select-String 'AzureAdJoined').ToString().Trim())

# 2. Intune MDM enrollment
$mdm = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
    Get-ItemProperty -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderID -eq 'MS DM Server' }
Add-Result 'Intune MDM enrolled' ($null -ne $mdm) $(if ($mdm) { "UPN: $($mdm.UPN | Select-Object -First 1)" } else { 'No MS DM Server enrollment found' })

# 3. Device name matches template
$nameOk = $env:COMPUTERNAME -like 'LAB-*'
Add-Result 'Device name template' $nameOk $env:COMPUTERNAME

# 4. User is standard (not local admin)
$admins = (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue).Name
$isAdmin = $admins | Where-Object { $_ -match [regex]::Escape($UserName) }
Add-Result "User '$UserName' is standard" (-not $isAdmin) ("Admins: " + ($admins -join ', '))

# 5. BitLocker on OS drive
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    $blOk = $bl.ProtectionStatus -eq 'On'
    Add-Result 'BitLocker protection' $blOk "$($bl.ProtectionStatus), $($bl.EncryptionMethod), $($bl.VolumeStatus)"

    $hasRecovery = $bl.KeyProtector.KeyProtectorType -contains 'RecoveryPassword'
    Add-Result 'BitLocker recovery password exists' $hasRecovery 'Confirm escrow in Intune → device → Recovery keys'
} catch {
    Add-Result 'BitLocker protection' $false "Run elevated: $($_.Exception.Message)"
}

# 6. Secure Boot
try {
    $sb = Confirm-SecureBootUEFI -ErrorAction Stop
    Add-Result 'Secure Boot' $sb "Enabled: $sb"
} catch {
    Add-Result 'Secure Boot' $false "Run elevated or not UEFI: $($_.Exception.Message)"
}

# 7. TPM
$tpm = Get-Tpm -ErrorAction SilentlyContinue
Add-Result 'TPM ready' ([bool]$tpm.TpmReady) "Present: $($tpm.TpmPresent), Ready: $($tpm.TpmReady)"

# 8. Firewall (all profiles)
$fw = Get-NetFirewallProfile
$fwOff = $fw | Where-Object { -not $_.Enabled }
Add-Result 'Firewall enabled (all profiles)' (-not $fwOff) (($fw | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ', ')

# 9. Defender antimalware + real-time protection
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
Add-Result 'Defender antimalware' ([bool]$mp.AntivirusEnabled) "AntivirusEnabled: $($mp.AntivirusEnabled)"
Add-Result 'Defender real-time protection' ([bool]$mp.RealTimeProtectionEnabled) "RealTimeProtectionEnabled: $($mp.RealTimeProtectionEnabled)"

# 10. Required apps
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName -ErrorAction SilentlyContinue
foreach ($app in @('Microsoft 365', '7-Zip')) {
    $found = $apps | Where-Object { $_ -like "*$app*" } | Select-Object -First 1
    Add-Result "App installed: $app" ([bool]$found) $(if ($found) { $found } else { 'Not found' })
}

# Output
$results | Format-Table -AutoSize -Wrap
$failed = ($results | Where-Object Result -eq 'FAIL').Count
if ($failed -eq 0) {
    Write-Host "`nAll $($results.Count) checks passed." -ForegroundColor Green
} else {
    Write-Host "`n$failed of $($results.Count) checks failed." -ForegroundColor Yellow
}
