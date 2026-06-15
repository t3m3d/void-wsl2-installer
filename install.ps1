[CmdletBinding()]
param(
    [string]$DistroName = 'Void',
    [string]$InstallPath = 'C:\WSL\void',
    [string]$DownloadDir = 'C:\WSL\downloads',
    [string]$Username = $env:USERNAME.ToLower(),
    [string]$Hostname = "$env:COMPUTERNAME-void".ToLower(),
    [string]$Timezone = 'America/New_York',
    # Void ships two ROOTFS variants -- glibc (default, most software just
    # works) and musl (smaller, stricter, fewer pre-built packages). Pick
    # via -Libc glibc | musl.
    [ValidateSet('glibc','musl')]
    [string]$Libc = 'glibc',
    [string]$RootfsBase = 'https://repo-default.voidlinux.org/live/current',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$msg) { Write-Host "[void-wsl2] $msg" -ForegroundColor Cyan }
function OK ([string]$msg) { Write-Host "[OK] $msg"        -ForegroundColor Green }
function Warn([string]$msg) { Write-Host "[WARN] $msg"     -ForegroundColor Yellow }
function Fail([string]$msg) { Write-Host "[FAIL] $msg"     -ForegroundColor Red; exit 1 }

$WSL = "$env:WINDIR\System32\wsl.exe"

# ---- 1. preflight ----
Say "preflight"

function Install-WSL-IfMissing {
    $wslOk = $false
    if (Test-Path $WSL) {
        try {
            $null = & $WSL --version 2>&1
            if ($LASTEXITCODE -eq 0) { $wslOk = $true }
        } catch { }
    }
    if ($wslOk) { return }

    Warn "WSL2 doesn't look usable on this machine (wsl.exe missing or feature not enabled)."
    Write-Host ""
    Write-Host "  To install WSL2 we need to run, as ADMINISTRATOR:" -ForegroundColor Yellow
    Write-Host "      wsl --install --no-distribution"
    Write-Host ""
    Write-Host "  This enables the WSL Windows feature, downloads the WSL2 kernel,"
    Write-Host "  and may require a REBOOT before this installer can proceed."
    Write-Host ""
    $resp = Read-Host "Run it now with elevation? (y/N)"
    if ($resp -ne 'y') {
        Fail "Aborting. Install WSL manually (wsl --install) then re-run this script."
    }
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile','-Command','wsl --install --no-distribution; Write-Host ""; Read-Host "Press Enter to close"' `
        -Verb RunAs -Wait
    OK "WSL2 install requested. If Windows needs a reboot, do that and re-run this script."
    exit 0
}
Install-WSL-IfMissing
OK "wsl available"

$existing = (& $WSL --list --quiet 2>&1) -replace "`0", '' | Where-Object { $_ -match $DistroName }
if ($existing -and -not $Force) {
    Warn "distro '$DistroName' is already registered."
    $resp = Read-Host "Unregister and reinstall? (y/N)"
    if ($resp -ne 'y') { Say "aborting (use -Force to skip this prompt)"; exit 0 }
    & $WSL --unregister $DistroName 2>&1 | Out-Null
    OK "old '$DistroName' unregistered"
}

# ---- 1b. interactive username + password ----
# Default username = Windows username lower-cased, but let the user override.
Write-Host ""
Say "user setup"
$usernameInput = Read-Host "Linux username [$Username]"
if (-not [string]::IsNullOrWhiteSpace($usernameInput)) {
    $Username = $usernameInput
}
if ($Username -notmatch '^[a-z][a-z0-9_-]{0,31}$') {
    Fail "Username '$Username' is invalid (lowercase letter start, then [a-z0-9_-], <=32 chars)"
}

function Read-PlaintextPassword([string]$prompt) {
    while ($true) {
        $sec1 = Read-Host -Prompt $prompt -AsSecureString
        $sec2 = Read-Host -Prompt "  re-enter to confirm" -AsSecureString
        $b1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec1)
        $b2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2)
        try {
            $p1 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
            $p2 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
        }
        if ($p1 -ne $p2)            { Warn "passwords don't match; try again";                       continue }
        if ($p1.Length -lt 8)       { Warn "password must be at least 8 chars; try again";          continue }
        if ($p1 -match "[`r`n']")   { Warn "password can't contain newlines or single quotes; try again"; continue }
        return $p1
    }
}

$UserPassword = Read-PlaintextPassword "Password for '$Username'"
$useSamePw = Read-Host "Use the same password for root? (Y/n)"
if ($useSamePw -eq 'n' -or $useSamePw -eq 'N') {
    $RootPassword = Read-PlaintextPassword "Password for root"
} else {
    $RootPassword = $UserPassword
}
OK "credentials captured"

# ---- 2. discover the latest ROOTFS tarball ----
Say "discovering latest void-x86_64-$Libc-ROOTFS from $RootfsBase"
$sumsUrl = "$RootfsBase/sha256sum.txt"
try {
    $sums = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing -TimeoutSec 30).Content
} catch { Fail "couldn't fetch sha256sum.txt at $sumsUrl : $_" }

# Void's sha256sum.txt lines look like:
#   SHA256 (void-x86_64-ROOTFS-20250202.tar.xz) = <hex>
#   SHA256 (void-x86_64-musl-ROOTFS-20250202.tar.xz) = <hex>
# We pick the x86_64 line matching the requested libc.
if ($Libc -eq 'glibc') {
    $needle = '^SHA256 \(void-x86_64-ROOTFS-(\d+)\.tar\.xz\) = ([0-9a-f]{64})$'
} else {
    $needle = '^SHA256 \(void-x86_64-musl-ROOTFS-(\d+)\.tar\.xz\) = ([0-9a-f]{64})$'
}
$match = $null
foreach ($line in ($sums -split "`r?`n")) {
    if ($line -match $needle) { $match = $matches; break }
}
if (-not $match) { Fail "couldn't find $Libc x86_64 ROOTFS line in sha256sum.txt" }
$stageDate = $match[1]
$expectedSha256 = $match[2]
if ($Libc -eq 'glibc') {
    $stageFilename = "void-x86_64-ROOTFS-$stageDate.tar.xz"
} else {
    $stageFilename = "void-x86_64-musl-ROOTFS-$stageDate.tar.xz"
}
$stageUrl = "$RootfsBase/$stageFilename"
OK "latest: $stageFilename"

# ---- 3. preparing dirs ----
Say "preparing dirs"
New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
if ((Get-ChildItem $InstallPath -Force -ErrorAction SilentlyContinue).Count -gt 0 -and -not $Force) {
    Fail "$InstallPath is not empty. Use -Force or pick a different -InstallPath."
}

$stageFile = Join-Path $DownloadDir $stageFilename

function Get-Sha256Hex([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $bytes = $sha.ComputeHash($fs)
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($bytes) -replace '-','').ToLower()
}

# Reuse a cached tarball iff its hash matches the upstream sha256sum.txt
# entry we just parsed.  Otherwise re-download.
$needDownload = $true
if (Test-Path $stageFile) {
    Say "checking cached tarball at $stageFile"
    $cachedHash = Get-Sha256Hex $stageFile
    if ($cachedHash -eq $expectedSha256.ToLower()) {
        $mb = [math]::Round((Get-Item $stageFile).Length / 1MB, 1)
        OK "cached tarball matches upstream hash ($mb MB) -- skipping download"
        $needDownload = $false
    } else {
        Warn "cached tarball hash mismatch -- redownloading"
    }
}

if ($needDownload) {
    Say "downloading $stageFilename (~120 MB)"
    $swDl = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri $stageUrl -OutFile $stageFile -UseBasicParsing
    $swDl.Stop()
    $mb = [math]::Round((Get-Item $stageFile).Length / 1MB, 1)
    OK "downloaded $mb MB in $([math]::Round($swDl.Elapsed.TotalSeconds,1))s"
}

Say "verifying sha256"
$actual = Get-Sha256Hex $stageFile
if ($expectedSha256.ToLower() -ne $actual) {
    Fail "SHA256 MISMATCH. Expected $expectedSha256, got $actual. Delete $stageFile and retry."
}
OK "sha256 verified ($actual)"

# ---- 4. wsl import ----
Say "wsl --import $DistroName"
$swImport = [System.Diagnostics.Stopwatch]::StartNew()
& $WSL --import $DistroName $InstallPath $stageFile --version 2 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "wsl --import failed (rc=$LASTEXITCODE)" }
$swImport.Stop()
OK "imported in $([math]::Round($swImport.Elapsed.TotalSeconds,1))s"

# ---- 5. first-boot setup inside the distro ----
Say "writing /etc/wsl.conf, creating user '$Username', xbps update + base install"

# The setup script that runs INSIDE the distro as root.
# Variables interpolated from PowerShell:
#   $u   -- username
#   $h   -- hostname
#   $tz  -- timezone
#   $rpw -- root password (captured interactively)
#   $upw -- user password (captured interactively)
$u   = $Username
$h   = $Hostname
$tz  = $Timezone
$rpw = $RootPassword
$upw = $UserPassword

$setupScript = @"
set -e

# /etc/wsl.conf
cat > /etc/wsl.conf << 'EOF'
[boot]
systemd=false

[user]
default=$u

[network]
generateHosts=true
generateResolvConf=true

[interop]
# enabled=true keeps explorer.exe / code.exe / etc. callable when you
# explicitly want to cross over to Windows.
enabled=true
# but appendWindowsPath=false stops Windows PATH from being unionised
# into the Linux PATH -- so `kcc` resolves to the Linux install, never
# to C:\Users\...\kcc.exe.
appendWindowsPath=false

[automount]
enabled=true
# noexec on /mnt/c blocks executing Windows binaries from inside WSL even
# if you call them by full path -- prevents accidentally running a stray
# Windows kcc.exe / etc.exe when you meant the Linux native version.
# Read + list still work, so cd /mnt/c/... is fine for inspection.
options="metadata,umask=22,fmask=11,noexec"
EOF

# hostname + timezone
echo '$h' > /etc/hostname
ln -sf /usr/share/zoneinfo/$tz /etc/localtime 2>/dev/null || true
echo '$tz' > /etc/timezone 2>/dev/null || true

# Void ships without /var/spool/mail in the base ROOTFS, which makes
# useradd warn 'Creating mailbox file: No such file or directory' on
# stderr.  Pre-create so the install runs silently.
mkdir -p /var/spool/mail
chmod 0775 /var/spool/mail

# Update xbps first (Void's strong recommendation -- xbps-install -Syu
# can refuse to proceed if xbps itself is older than what the repos
# expect).  Then full system update, then base tools.
echo '--- xbps-install -Sy xbps ---'
xbps-install -Sy xbps 2>&1 | tail -5
echo '--- xbps-install -Syu ---'
xbps-install -Syu 2>&1 | tail -5
echo '--- install base tools ---'
xbps-install -Sy sudo nano 2>&1 | tail -5

# Passwords captured interactively on the Windows side.  PAM in Void
# enforces a minimum length so the installer's prompt loop already
# filters short inputs.
echo 'root:$rpw' | chpasswd
useradd -m -G wheel,users -s /bin/bash $u
echo "${u}:$upw" | chpasswd

# wheel sudo (Void's default sudoers ships with the line commented).
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo '--- setup done ---'
"@

$tmpScript = Join-Path $env:TEMP "void-setup-$([Guid]::NewGuid().ToString('N').Substring(0,8)).sh"
# Set-Content -Encoding UTF8 in PS 5.1 prepends a BOM which bash chokes on,
# and the PowerShell here-string uses Windows CRLF line endings which bash
# also chokes on (sees `set -e\r` -> `-e\r` as an invalid flag). Normalise
# both before writing.
$setupScript = $setupScript -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($tmpScript, $setupScript, [System.Text.UTF8Encoding]::new($false))

# Convert Windows path -> WSL path via the distro's wslpath
$wslPath = (& $WSL -d $DistroName -u root -e wslpath -u "$tmpScript" 2>&1).Trim()
if ([string]::IsNullOrWhiteSpace($wslPath)) { Fail "wslpath returned empty for $tmpScript" }

& $WSL -d $DistroName -u root -- bash "$wslPath" 2>&1 | Tee-Object -Variable setupOut | Out-Host
if ($LASTEXITCODE -ne 0) { Fail "in-distro setup failed (rc=$LASTEXITCODE)" }
Remove-Item -Path $tmpScript -Force -ErrorAction SilentlyContinue
OK "in-distro setup complete"

# ---- 6. bounce + verify ----
Say "bouncing distro so default user takes effect"
& $WSL --terminate $DistroName 2>&1 | Out-Null
Start-Sleep -Seconds 2

Say "smoke test"
try {
    & $WSL -d $DistroName -- bash -c 'echo "user=$(whoami) uid=$(id -u)"; echo "xbps:"; xbps-query --version 2>&1 | head -1; echo "kernel:"; uname -r' 2>&1 | Out-Host
} catch {
    Warn "smoke test threw: $_  (distro is probably fine - manually verify with: wsl -d $DistroName)"
}

# ---- 7. summary ----
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Void installed and ready"                  -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Distro:    $DistroName"
Write-Host "  Path:      $InstallPath"
Write-Host "  Libc:      $Libc  (passed via -Libc)"
Write-Host "  Stage:     $stageFilename"
Write-Host "  User:      $Username (password you set during install)"
Write-Host "  Root:      password you set during install"
Write-Host "  Hostname:  $h"
Write-Host ""
Write-Host "  To change passwords later:" -ForegroundColor Yellow
Write-Host "    wsl -d $DistroName -- passwd"
Write-Host "    wsl -d $DistroName -u root -- passwd"
Write-Host ""
Write-Host "  Run with:  wsl -d $DistroName"
Write-Host ""
Write-Host "  Useful xbps commands:"
Write-Host "    xbps-query -Rs <term>     search packages"
Write-Host "    xbps-query -R <pkg>       show package info"
Write-Host "    sudo xbps-install <pkg>   install"
Write-Host "    sudo xbps-install -Syu    update everything"
Write-Host "    sudo xbps-remove <pkg>    remove"
Write-Host ""
