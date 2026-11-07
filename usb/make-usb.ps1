<#
phiOS USB maker for Windows. Run it in an ADMIN PowerShell.

Writes the phiOS installer (boot it and the installer starts by itself), checked against the
release's checksums, then reads every byte back to prove the write.

  .\make-usb.ps1                     # interactive
  .\make-usb.ps1 -Debian             # plain Debian live ISO instead (signature-checked)
  .\make-usb.ps1 -Iso D:\some.iso    # use an ISO you already have
  .\make-usb.ps1 -DryRun             # everything except writing (lists your USB disks)

  one-liner:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/convolutionary/phiOS/main/usb/make-usb.ps1)))

Source is plain ASCII on purpose (Windows PowerShell 5.1 reads BOM-less files as ANSI);
every non-ASCII character is built with [char] at runtime.
#>
[CmdletBinding()]
param(
    [ValidateSet('standard', 'gnome', 'kde', 'xfce')] [string]$Flavor = 'standard',
    [string]$Iso,
    [int]$Disk = -1,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Debian
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# run state lives in one table: as a one-liner this runs as a scriptblock, where $script: points
# at the caller's scope, not ours
$St = @{ Iso = $Iso; Disk = $Disk; Want = $null; Target = $null; Base = $null; Pattern = $null; Source = $(if ($Debian -or $PSBoundParameters.ContainsKey('Flavor')) { 'debian' } else { 'phios' }) }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Rel = if ($env:PHI_USB_RELEASE) { $env:PHI_USB_RELEASE } else { 'https://github.com/convolutionary/phiOS/releases/latest/download' }
$Live = if ($env:PHI_USB_LIVE) { $env:PHI_USB_LIVE } else { 'https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid' }
# Debian CD signing keys, from https://www.debian.org/CD/verify (testing-only key left out)
$Keys = @('DF9B9C49EAA9298432589D76DA87E80D6294BE9B', '10460DAD76165AD81FBC0CE9988021A964E6EA7D')
# fetched by fingerprint. where they come from doesn't matter: only these fingerprints are accepted
$KeyServers = @('https://keyring.debian.org', 'https://keyserver.ubuntu.com')
$Repo = 'https://github.com/convolutionary/phiOS'
$Cache = Join-Path $env:LOCALAPPDATA 'phios-usb'
$Chunk = 4MB
$PhiDigits = '1.6180339887498948482045868343656381177203091798057628621354486227'

# ------------------------------------------------------------------ look

$E = [char]27
$Fancy = $true
try { if (-not $Host.UI.SupportsVirtualTerminal) { $Fancy = $false } } catch { $Fancy = $false }
if ($env:PHI_PLAIN -eq '1') { $Fancy = $false }
try { if ([Console]::IsOutputRedirected) { $Fancy = $false } } catch {}
function C($r, $g, $b) { if ($Fancy) { "$E[38;2;$r;$g;${b}m" } else { '' } }
$R = if ($Fancy) { "$E[0m" } else { '' }
$GOLD = C 236 190 64; $AMBER = C 196 132 30; $DIM = C 108 108 122; $TXT = C 208 208 216
$HI = if ($Fancy) { "$E[1;38;2;246;246;250m" } else { '' }; $RED = C 236 98 98; $OK = C 132 204 150

$PHI = [char]0x03C6; $ELL = [char]0x2026
$H = [string][char]0x2500; $FULL = [string][char]0x2501; $V = [char]0x2502
$TL = [char]0x256D; $TR = [char]0x256E; $BL = [char]0x2570; $BR = [char]0x256F
$DOT = [char]0x25CF; $CHECK = [char]0x2713; $CROSS = [char]0x2717; $ARROW = [char]0x203A
$Spin = 0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F | ForEach-Object { [string][char]$_ }

function Dims {
    $global:PhiCols = try { [Console]::WindowWidth } catch { 80 }
    if ($global:PhiCols -lt 20) { $global:PhiCols = 80 }
    $global:PhiW = [Math]::Min($global:PhiCols - 4, 80)
    if ($global:PhiW -lt 30) { $global:PhiW = $global:PhiCols - 1 }
    $global:PhiPad = ' ' * [Math]::Floor(($global:PhiCols - $global:PhiW) / 2)
}
Dims

function Say($t) { Write-Host "$PhiPad$GOLD$PHI$R $TXT$t$R" }
function Warn($t) { Write-Host "$PhiPad$AMBER!$R $TXT$t$R" }
function Die($t) { Write-Host ""; Write-Host "$PhiPad$RED$CROSS $t$R"; try { [Console]::CursorVisible = $true } catch {}; exit 1 }
function Ask($q) { Write-Host -NoNewline "$PhiPad$GOLD$ARROW$R $TXT$q$R "; Read-Host }
function Human([double]$b) {
    $u = 'B', 'KiB', 'MiB', 'GiB', 'TiB'; $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b /= 1024; $i++ }
    if ($i -eq 0) { '{0} {1}' -f [int]$b, $u[$i] } else { '{0:N1} {1}' -f $b, $u[$i] }
}
function Mmss([int]$s) { '{0}:{1:D2}' -f [Math]::Floor($s / 60), ($s % 60) }
function Nap($s) { if ($env:PHI_FAST -ne '1') { Start-Sleep -Milliseconds ([int]($s * 1000)) } }

function Intro {
    if (-not $Fancy) { Write-Host 'phiOS USB maker'; return }
    try { Clear-Host } catch {}
    try { [Console]::CursorVisible = $false } catch {}
    Write-Host ''
    # the phiOS swirl, drawn from its half-block rows (see tools/swirl.py)
    $rows = @(
        '          AAABBBBBBBBAA',
        '      AABBBBBBBBBBBBBBBBBA',
        '    ABBBBBBCCC      CCBBBBBA',
        '   BBBBBC              CBBBBB',
        '  BBBBC                  CBBBA',
        ' BBBC                     BBBB',
        ' BB               A       BBBB',
        'AB               B        BBBC',
        'B                CA     ABBBC',
        'B                 CBBBBBBBC'
    )
    $map = @{ 'A' = [string][char]0x2584; 'B' = [string][char]0x2588; 'C' = [string][char]0x2580 }
    $off = ' ' * [Math]::Max(0, [Math]::Floor(($PhiW - 30) / 2))
    $tall = $true
    try { if ([Console]::WindowHeight -lt 26) { $tall = $false } } catch {}
    if ($tall -and $PhiW -ge 34) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $line = -join ($rows[$i].ToCharArray() | ForEach-Object { if ($map.ContainsKey([string]$_)) { $map[[string]$_] } else { [string]$_ } })
            $shade = C (190 + $i * 6) (122 + $i * 10) (24 + $i * 7)
            Write-Host "$PhiPad$off$shade$line$R"
            Nap 0.03
        }
        Write-Host ''
    }
    $mark = 'p h i O S   u s b'
    Write-Host ("$PhiPad" + (' ' * [Math]::Floor(($PhiW - $mark.Length) / 2)) + "$HI$mark$R")
    $d = "$PHI = " + $PhiDigits.Substring(0, [Math]::Min(40, $PhiW - 10)) + $ELL
    Write-Host -NoNewline ("$PhiPad" + (' ' * [Math]::Floor(($PhiW - $d.Length) / 2)) + $DIM)
    foreach ($ch in $d.ToCharArray()) { Write-Host -NoNewline $ch; Nap 0.01 }
    Write-Host "$R"; Write-Host ''
    try { [Console]::CursorVisible = $true } catch {}
}

# gold bar; the head turns into phi past 61.8%, phi's digits fill in as it grows
function Bar([double]$done, [double]$total, [string]$label, [string]$extra = '') {
    if ($total -le 0) { $total = 1 }
    $pm = [Math]::Min(1000, [int]($done * 1000 / $total))
    Dims
    $bw = [Math]::Min(40, $PhiW - 2 - $label.Length - 10 - $extra.Length)
    $pct = '{0}.{1}%' -f [Math]::Floor($pm / 10), ($pm % 10)
    if (-not $Fancy -or $bw -lt 8) {
        Write-Host -NoNewline ("`r$PhiPad[$label] $pct $extra   "); return
    }
    $f = [int]($bw * $pm / 1000)
    $head = if ($pm -ge 618) { [string]$PHI } else { [string]$DOT }
    if ($f -ge $bw) { $head = '' }
    $dg = ''
    if (($PhiW - 2 - $label.Length - $bw - 10 - $extra.Length) -gt 14) { $dg = '  ' + $PhiDigits.Substring(0, 2 + [int]($pm * 10 / 1000)) }
    $empty = [Math]::Max(0, $bw - $f - $head.Length)
    Write-Host -NoNewline ("`r$E[K$PhiPad$HI$label$R $GOLD" + ($FULL * $f) + "$head$DIM" + ($H * $empty) + "$TXT " + $pct.PadLeft(6) + "$GOLD$dg$R  $DIM$extra$R")
}
function BarDone($t) { Write-Host ("`r" + $(if ($Fancy) { "$E[K" } else { '' }) + "$PhiPad$OK$CHECK$R $TXT$t$R") }

function Box([string]$title, [string[]]$lines) {
    Write-Host ("$PhiPad$DIM$TL$H $GOLD$title $DIM" + ($H * [Math]::Max(0, $PhiW - 5 - $title.Length)) + "$TR$R")
    foreach ($l in $lines) { Write-Host "$PhiPad$DIM$V$R $l" }
    Write-Host ("$PhiPad$DIM$BL" + ($H * ($PhiW - 2)) + "$BR$R")
}

# ------------------------------------------------------------------ raw disk access
# .NET Framework refuses \\.\PhysicalDriveN paths, so open it with CreateFile directly
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PhiDisk {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    public static FileStream Open(int disk, bool write) {
        uint access = write ? 0xC0000000u : 0x80000000u;          // GENERIC_READ | GENERIC_WRITE
        uint flags = write ? 0x80000000u : 0u;                     // FILE_FLAG_WRITE_THROUGH
        SafeFileHandle h = CreateFile(@"\\.\PhysicalDrive" + disk, access, 3u, IntPtr.Zero, 3u, flags, IntPtr.Zero);
        if (h.IsInvalid) throw new IOException("can't open PhysicalDrive" + disk + " (error " + Marshal.GetLastWin32Error() + ")");
        return new FileStream(h, write ? FileAccess.ReadWrite : FileAccess.Read, 4 * 1024 * 1024);
    }
}
'@

# ------------------------------------------------------------------ steps

function Get-Sums {
    New-Item -ItemType Directory -Force $Cache | Out-Null
    if ($St.Source -eq 'phios') {
        Say "fetching the phiOS installer's checksums"
        try {
            Invoke-WebRequest -UseBasicParsing "$Rel/SHA256SUMS" -OutFile "$Cache\SHA256SUMS"
            if (Select-String -Quiet -Path "$Cache\SHA256SUMS" -Pattern ' phios-installer-\S*\.iso$') {
                $St.Base = $Rel; $St.Pattern = '^phios-installer-.*\.iso$'
                BarDone 'checksums from the phiOS release on GitHub'
                return
            }
        } catch {}
        Warn "no phiOS installer release yet, so this writes Debian's live ISO. You'll start the installer by hand"
        $St.Source = 'debian'
    }
    $St.Base = $Live; $St.Pattern = "^debian-live-[0-9.]+-amd64-$Flavor\.iso$"
    Say "fetching Debian's signed checksums"
    try {
        Invoke-WebRequest -UseBasicParsing "$Live/SHA256SUMS" -OutFile "$Cache\SHA256SUMS"
        Invoke-WebRequest -UseBasicParsing "$Live/SHA256SUMS.sign" -OutFile "$Cache\SHA256SUMS.sign"
    } catch { Die "can't reach cdimage.debian.org: $($_.Exception.Message)" }
    $gpg = Get-Command gpg -ErrorAction SilentlyContinue
    if (-not $gpg) { Warn 'gpg not installed: trusting the checksums because they came over HTTPS from debian.org'; return }
    $gh = Join-Path ([IO.Path]::GetTempPath()) ("phios-gpg-" + [guid]::NewGuid())
    New-Item -ItemType Directory $gh | Out-Null
    $env:GNUPGHOME = $gh
    # Windows PowerShell 5.1 turns any native stderr into a terminating error under 'Stop',
    # and gpg chats on stderr. the fingerprint check below is what decides
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        foreach ($fp in $Keys) {
            foreach ($s in $KeyServers) {
                try {
                    $k = (Invoke-WebRequest -UseBasicParsing "$s/pks/lookup?op=get&options=mr&search=0x$fp").Content
                    $k | & gpg -q --batch --import 2>$null | Out-Null
                    break
                } catch {}
            }
        }
        $out = & gpg --batch --status-fd 1 --verify "$Cache\SHA256SUMS.sign" "$Cache\SHA256SUMS" 2>$null
    } finally {
        $ErrorActionPreference = $eap
        Remove-Item Env:\GNUPGHOME; Remove-Item -Recurse -Force $gh -ErrorAction SilentlyContinue
    }
    $fpr = ($out | Where-Object { $_ -match 'VALIDSIG' } | Select-Object -First 1) -split ' ' | Select-Object -Last 1
    if ($Keys -notcontains $fpr) { Die "SHA256SUMS signature didn't verify against Debian's CD signing key" }
    BarDone ("checksums signed by Debian CD key " + $fpr.Substring(32))
}

function Get-Iso {
    $sums = Get-Content "$Cache\SHA256SUMS" | ForEach-Object { $p = $_ -split '\s+', 2; [pscustomobject]@{ Hash = $p[0]; Name = $p[1] } }
    if ($St.Iso) {
        if (-not (Test-Path $St.Iso)) { Die "$($St.Iso) doesn't exist" }
        $hit = $sums | Where-Object Name -eq (Split-Path $St.Iso -Leaf)
        if (-not $hit) { Warn "$(Split-Path $St.Iso -Leaf) isn't in the current checksum list, can't verify it"; $St.Want = $null }
        else { $St.Want = $hit.Hash }
        return
    }
    $hit = $sums | Where-Object { $_.Name -match $St.Pattern } | Select-Object -First 1
    if (-not $hit) { Die "no matching image in $($St.Base)" }
    $St.Want = $hit.Hash
    $St.Iso = Join-Path $Cache $hit.Name
    $url = "$($St.Base)/$($hit.Name)"

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $head = $client.SendAsync((New-Object System.Net.Http.HttpRequestMessage 'HEAD', $url)).Result
    $total = [long]$head.Content.Headers.ContentLength
    if ($total -le 0) { Die "can't get the size of $url" }
    $have = if (Test-Path $St.Iso) { (Get-Item $St.Iso).Length } else { 0 }
    if ($have -eq $total) { Say "found $($hit.Name) in the cache"; return }
    if ($have -gt $total) { Remove-Item $St.Iso; $have = 0 }

    Say ("downloading {0} ({1})" -f $hit.Name, (Human $total))
    $req = New-Object System.Net.Http.HttpRequestMessage 'GET', $url
    if ($have -gt 0) { $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue $have, $null }
    $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    if (-not $resp.IsSuccessStatusCode) { Die "download failed: $($resp.StatusCode)" }
    $in = $resp.Content.ReadAsStreamAsync().Result
    $out = [IO.File]::Open($St.Iso, [IO.FileMode]::Append, [IO.FileAccess]::Write)
    $buf = New-Object byte[] (1MB)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = 0; $start = $have
    try { [Console]::CursorVisible = $false } catch {}
    try {
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $have += $n
            if ($sw.ElapsedMilliseconds - $last -ge 250) {
                $last = $sw.ElapsedMilliseconds
                $rate = ($have - $start) / [Math]::Max(1, $sw.Elapsed.TotalSeconds)
                Bar $have $total 'download' ("{0}/s {1}" -f (Human $rate), (Mmss (($total - $have) / [Math]::Max(1, $rate))))
            }
        }
    } finally { $out.Close(); $in.Close(); try { [Console]::CursorVisible = $true } catch {} }
    if ($have -ne $total) { Die 'download incomplete, run again to resume' }
    BarDone ("downloaded {0} in {1}" -f (Human $total), (Mmss $sw.Elapsed.TotalSeconds))
}

function Test-IsoHash {
    if (-not $St.Want) { return }
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($St.Iso); $buf = New-Object byte[] (4MB); $done = 0; $total = $fs.Length
    try {
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0); $done += $n
            Bar $done $total 'sha256  '
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
    } finally { $fs.Close() }
    $got = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
    if ($got -ne $St.Want) { Remove-Item $St.Iso; Die 'SHA256 mismatch, deleted the download. Run again' }
    if ($St.Source -eq 'phios') {
        BarDone "SHA256 matches the release's checksum list"
        # GitHub build attestation: proves the ISO came out of this repo's release workflow
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            & gh attestation verify $St.Iso -R convolutionary/phiOS *> $null
            $ok = $LASTEXITCODE -eq 0; $ErrorActionPreference = $eap
            if ($ok) { BarDone "GitHub attestation: built by phiOS's release workflow" }
        }
    } else {
        BarDone "SHA256 matches Debian's signed list"
    }
}

function Select-Stick {
    $usb = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem })
    if ($usb.Count -eq 0) { Die 'no USB stick found. Plug one in and run again' }
    Write-Host ''
    Box 'USB disks' ($usb | ForEach-Object { "$GOLD{0}$R  $TXT{1,-30} {2,10}$R" -f $_.Number, $_.FriendlyName, (Human $_.Size) })
    Write-Host ''
    if ($DryRun) { Say 'dry run: stopping before anything gets written'; exit 0 }
    if ($St.Disk -lt 0) { $St.Disk = [int](Ask 'disk number to ERASE:') }
    $St.Target = $usb | Where-Object Number -eq $St.Disk
    if (-not $St.Target) { Die "disk $St.Disk isn't one of the USB disks above" }
    if ($St.Target.Size -lt (Get-Item $St.Iso).Length) { Die 'that stick is smaller than the image' }
    if (-not $Yes) {
        Warn ("everything on disk {0} ({1}) gets erased" -f $St.Disk, $St.Target.FriendlyName)
        if ((Ask "type $($St.Disk) again to confirm:") -ne "$($St.Disk)") { Die 'aborted, nothing written' }
    }
}

function Write-Stick {
    $n = $St.Disk
    $size = (Get-Item $St.Iso).Length
    # wipe the table first: Windows mounts partitions the moment it sees them and then blocks raw
    # writes into them. so: clear, write everything after the first MiB, write the first MiB last
    Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    $iso = [IO.File]::OpenRead($St.Iso)
    $dev = [PhiDisk]::Open($n, $true)
    $buf = New-Object byte[] $Chunk
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { [Console]::CursorVisible = $false } catch {}
    try {
        # $len, never $r: PowerShell names are case-insensitive, so $r IS $R (the colour reset)
        # and the bar printed the chunk size wherever it meant to reset colour
        $iso.Position = 1MB; $dev.Position = 1MB; $done = 1MB
        while (($len = $iso.Read($buf, 0, $buf.Length)) -gt 0) {
            if ($len % 512) { [Array]::Clear($buf, $len, 512 - $len % 512); $len += 512 - $len % 512 }
            $dev.Write($buf, 0, $len); $done += $len
            $rate = $done / [Math]::Max(1, $sw.Elapsed.TotalSeconds)
            Bar ([Math]::Min($done, $size)) $size 'write   ' ("{0}/s {1}" -f (Human $rate), (Mmss (($size - $done) / [Math]::Max(1, $rate))))
        }
        $first = New-Object byte[] (1MB)
        $iso.Position = 0; [void]$iso.Read($first, 0, $first.Length)
        $dev.Position = 0; $dev.Write($first, 0, $first.Length)
        $dev.Flush()
    } finally { $dev.Close(); $iso.Close(); try { [Console]::CursorVisible = $true } catch {} }
    BarDone ("wrote {0} in {1}" -f (Human $size), (Mmss $sw.Elapsed.TotalSeconds))

    # read every byte back from the device and hash both sides with .NET's native SHA256.
    # (a per-byte PowerShell loop would be ~2 billion interpreted iterations for one ISO)
    $iso = [IO.File]::OpenRead($St.Iso); $dev = [PhiDisk]::Open($n, $false)
    $ha = [Security.Cryptography.SHA256]::Create(); $hb = [Security.Cryptography.SHA256]::Create()
    $a = New-Object byte[] $Chunk; $b = New-Object byte[] $Chunk; $done = 0
    try {
        while (($len = $iso.Read($a, 0, $a.Length)) -gt 0) {
            $want = $len; if ($want % 512) { $want += 512 - $want % 512 }
            $got = 0; while ($got -lt $want) { $k = $dev.Read($b, $got, $want - $got); if ($k -le 0) { break }; $got += $k }
            if ($got -lt $len) { Die ("the stick ended early at {0}" -f (Human ($done + $got))) }
            [void]$ha.TransformBlock($a, 0, $len, $null, 0)
            [void]$hb.TransformBlock($b, 0, $len, $null, 0)
            $done += $len
            Bar $done $size 'verify  '
        }
        [void]$ha.TransformFinalBlock($a, 0, 0); [void]$hb.TransformFinalBlock($b, 0, 0)
    } finally { $dev.Close(); $iso.Close() }
    if ([Convert]::ToBase64String($ha.Hash) -ne [Convert]::ToBase64String($hb.Hash)) {
        Die 'read-back mismatch: the stick does not match the ISO. It may be failing'
    }
    BarDone 'read back every byte, the stick matches the ISO'
    Update-Disk -Number $n -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ main

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Intro
if (-not $admin -and -not $DryRun) { Die 'run this from an admin PowerShell (it writes to a raw disk)' }
Get-Sums
Get-Iso
Test-IsoHash
Select-Stick
Write-Stick
Write-Host ''
if ($St.Source -eq 'phios') {
    Box 'stick ready' @(
        "${GOLD}1$R  boot it in UEFI mode (F8/F11/F12 boot menu)",
        "${GOLD}2$R  ${HI}Install phiOS$R is the default, the installer starts by itself",
        "${GOLD}3$R  no ethernet? it opens a Wi-Fi picker first"
    )
    Write-Host ''
    return
}
Box 'stick ready' @(
    "${GOLD}1$R  boot it in UEFI mode (F8/F11/F12 boot menu)",
    "${GOLD}2$R  connect to the network (ethernet)",
    "${GOLD}3$R  get phiOS and run it:"
)
# outside the box and never wrapped, so they copy-paste as one line
Write-Host ''
Write-Host "  ${HI}wget -qO- $Repo/archive/main.tar.gz | tar xz$R"
Write-Host "  ${HI}sudo phiOS-main/install.sh$R"
Write-Host ''
