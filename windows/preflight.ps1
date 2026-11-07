# phiOS Windows preflight. Run in an admin PowerShell BEFORE booting the installer.
#
#   .\preflight.ps1         report only, changes nothing
#   .\preflight.ps1 -Fix    also offers two fixes, each asks first:
#                           - turn off Fast Startup
#                           - keep the hardware clock in UTC (stops Linux/Windows clock drift)
#
# It never touches partitions, boot entries or BitLocker.
param([switch]$Fix)
$ErrorActionPreference = 'Stop'

function Gold($t) { Write-Host $t -ForegroundColor Yellow }
function Ok($t)   { Write-Host "  ok    $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  warn  $t" -ForegroundColor Magenta }
function Bad($t)  { Write-Host "  stop  $t" -ForegroundColor Red }
function Info($t) { Write-Host "        $t" -ForegroundColor DarkGray }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Bad "run this from an admin PowerShell"; exit 1 }

Gold "`n  phiOS preflight`n"
$blockers = 0

# ---------------------------------------------------------------- firmware
if ($env:firmware_type -eq 'UEFI') { Ok "UEFI firmware" } else { Bad "legacy BIOS boot. phiOS needs UEFI"; $blockers++ }
try {
    if (Confirm-SecureBootUEFI) { Ok "Secure Boot on (phiOS keeps it on)" }
    else { Warn "Secure Boot off. phiOS works either way; turning it on later is supported" }
} catch { Warn "couldn't read Secure Boot state" }

# ---------------------------------------------------------------- BitLocker
try {
    $vols = Get-BitLockerVolume
    foreach ($v in $vols) {
        if ($v.ProtectionStatus -eq 'On') {
            $rp = $v.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword'
            if ($rp) {
                Warn "BitLocker on $($v.MountPoint). Make sure its recovery key is saved off this PC"
                Info "show it: manage-bde -protectors -get $($v.MountPoint)   (or account.microsoft.com/devices/recoverykey)"
            } else {
                Bad "BitLocker on $($v.MountPoint) has no recovery password protector. Add one before continuing"
                Info "manage-bde -protectors -add $($v.MountPoint) -RecoveryPassword"
                $blockers++
            }
        }
    }
    if (-not ($vols | Where-Object ProtectionStatus -eq 'On')) { Ok "no BitLocker-protected volumes" }
} catch { Warn "couldn't query BitLocker: $($_.Exception.Message)" }
Info "if BitLocker is on: boot Windows from the firmware boot menu, not GRUB's Windows entry,"
Info "or it may ask for the recovery key once. The installer can also keep Windows first in boot order."

# ---------------------------------------------------------------- fast startup, clock
$pwr = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$fast = (Get-ItemProperty $pwr -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
if ($fast -eq 1) { Warn "Fast Startup on. It leaves disks and devices half-asleep when you switch to Linux" }
else { Ok "Fast Startup off" }

$tz = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
$utc = (Get-ItemProperty $tz -Name RealTimeIsUniversal -ErrorAction SilentlyContinue).RealTimeIsUniversal
if ($utc -eq 1) { Ok "hardware clock in UTC" }
else { Warn "Windows keeps the hardware clock in local time; Linux uses UTC, so clocks will jump when switching" }

# ---------------------------------------------------------------- disks
Gold "`n  disks"
foreach ($d in Get-Disk | Sort-Object Number) {
    $parts = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue
    $hasWin = $false
    foreach ($p in $parts | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }) {
        $path = $null
        try {
            $guid = $p.AccessPaths | Where-Object { $_ -like '\\?\Volume*' } | Select-Object -First 1
            if ($guid -and (Test-Path "$($guid)EFI\Microsoft\Boot\bootmgfw.efi")) { $hasWin = $true }
        } catch {}
    }
    $linux = $parts | Where-Object { $_.GptType -eq '{0fc63daf-8483-4772-8e79-3d69d8477de4}' }
    $tag = if ($hasWin) { "WINDOWS DISK, the installer refuses it" } elseif ($linux) { "has a Linux partition, install target" } else { "" }
    $gb = [math]::Round($d.Size / 1GB)
    Write-Host ("  disk {0}  {1,-30} {2,6} GB  {3}" -f $d.Number, $d.FriendlyName, $gb, $tag) -ForegroundColor $(if ($hasWin) { 'Cyan' } elseif ($linux) { 'Yellow' } else { 'Gray' })
    foreach ($p in $parts) {
        $sz = [math]::Round($p.Size / 1GB, 1)
        $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { "  " }
        Info ("  part {0}  {1}  {2,8} GB  {3}" -f $p.PartitionNumber, $letter, $sz, $p.Type)
    }
}
Info "in the Debian live system NVMe disks are /dev/nvme0n1, /dev/nvme1n1...; match them by size/model with: lsblk -o NAME,SIZE,MODEL"

# ---------------------------------------------------------------- fixes
if ($Fix) {
    Gold "`n  fixes"
    if ($fast -eq 1) {
        if ((Read-Host "  turn off Fast Startup? [y/N]") -match '^[yY]') {
            Set-ItemProperty $pwr -Name HiberbootEnabled -Value 0 -Type DWord
            Ok "Fast Startup off"
        }
    }
    if ($utc -ne 1) {
        if ((Read-Host "  keep the hardware clock in UTC? [y/N]") -match '^[yY]') {
            New-ItemProperty $tz -Name RealTimeIsUniversal -Value 1 -PropertyType QWord -Force | Out-Null
            Ok "hardware clock in UTC from the next boot"
        }
    }
}

Write-Host ""
if ($blockers) { Bad "$blockers blocker(s) above. Fix those first."; exit 2 }
Gold "  ready. Next: boot the Debian live USB in UEFI mode and run install.sh`n"
