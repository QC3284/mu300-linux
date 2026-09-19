<#
.SYNOPSIS
    MU300 / ZTE F50 Linux installer for Windows (same as install.sh on macOS/Linux).

.DESCRIPTION
    Run with the device booted in rooted Android and connected over USB (adb).
      .\install.ps1 -Check     only inspect the device; writes nothing
      .\install.ps1            install Ubuntu, OpenWrt or both from the prebuilt release images

    Needs: adb, Python 3 and the lz4 module (pip install lz4). Windows 10/11 provide tar and curl.
    The published images contain no proprietary files: the Wi-Fi/Bluetooth firmware and the Android modem/GPU
    userspace are pulled from *your* device into work\ and added during installation.
    Only the Linux region, boot_b and 32 bytes of misc are written; boot_a, the GPT and userdata stay untouched.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$Release = 'v2026.09.21',
    [string]$ReleaseUrl,
    [string]$Repo = 'dikeckaan/mu300-linux',
    [string]$Work = (Join-Path $PSScriptRoot 'work')
)

$ErrorActionPreference = 'Stop'
$T = '/data/local/tmp'
$Top = $PSScriptRoot
$MU300_IP = '192.168.77.1'

function Say($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "`nERROR: $m" -ForegroundColor Red; exit 1 }
function Ask($question, $default) {
    $a = Read-Host "$question [$default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default } else { return $a.Trim() }
}
# adb shell with root; stdin is never forwarded so prompts of this script are not eaten
function SuDo($cmd) {
    (& adb shell "su -c '$cmd'" 2>$null) -join "`n" -replace "`r", ''
}
# binary-safe: cmd.exe redirection keeps the byte stream intact (PowerShell pipelines do not)
function SuDoToFile($cmd, $path) {
    & cmd.exe /c "adb exec-out ""su -c '$cmd'"" > ""$path""" | Out-Null
}
$script:PyExe = $null
function Python { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PyArgs)
    if (-not $script:PyExe) {
        foreach ($n in 'python', 'python3', 'py') {
            $c = Get-Command $n -ErrorAction SilentlyContinue
            if ($c) { $script:PyExe = $c.Source; break }
        }
        if (-not $script:PyExe) { Die 'Python 3 not found (install it from python.org or the Microsoft Store)' }
    }
    & $script:PyExe @PyArgs
}
# GitHub's release CDN throttles single connections hard in some regions: pull large files as parallel ranges
function Fetch($url, $out) {
    $jobs = 8
    try { $len = [int64](Invoke-WebRequest $url -Method Head -UseBasicParsing).Headers['Content-Length'][0] } catch { $len = 0 }
    if ($len -lt 8MB) { Invoke-WebRequest $url -OutFile $out -UseBasicParsing; return }
    $part = [int64]($len / $jobs) + 1
    $running = @()
    for ($i = 0; $i -lt $jobs; $i++) {
        $s = $i * $part; $e = [math]::Min($s + $part - 1, $len - 1)
        $running += Start-Job -ScriptBlock {
            param($u, $f, $a, $b)
            $r = [System.Net.HttpWebRequest]::Create($u); $r.AddRange($a, $b)
            $resp = $r.GetResponse(); $fs = [IO.File]::Create($f)
            $resp.GetResponseStream().CopyTo($fs); $fs.Close(); $resp.Close()
        } -ArgumentList $url, "$out.part$i", $s, $e
    }
    $failed = $false
    foreach ($j in $running) { Wait-Job $j | Out-Null; if ($j.State -ne 'Completed') { $failed = $true }; Receive-Job $j -ErrorAction SilentlyContinue | Out-Null; Remove-Job $j }
    if (-not $failed) {
        $fs = [IO.File]::Create($out)
        for ($i = 0; $i -lt $jobs; $i++) { $b = [IO.File]::OpenRead("$out.part$i"); $b.CopyTo($fs); $b.Close(); Remove-Item "$out.part$i" }
        $fs.Close()
        if ((Get-Item $out).Length -eq $len) { return }
    }
    Get-ChildItem "$out.part*" -ErrorAction SilentlyContinue | Remove-Item -Force
    Write-Host '  parallel download failed, retrying as a single stream'
    Invoke-WebRequest $url -OutFile $out -UseBasicParsing
}
# shell scripts and config files for the device must keep Unix line endings
function WriteUnix($path, $text) { [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n")) }

Say 'Checking host tools and device'
foreach ($c in 'adb', 'tar') { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { Die "$c not found" } }
Python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'Python 3.8 or newer is required' }
if (-not $Check) {
    Python -c 'import lz4.block' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Die 'the lz4 Python module is required to build the boot image: pip install lz4' }
}
& adb start-server 2>$null | Out-Null
if ((& adb get-state 2>$null) -notmatch 'device') {
    # the device may be running MU300 Linux right now: then only SSH on the USB network answers
    $linux = Test-NetConnection -ComputerName $MU300_IP -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $linux) { Die 'no adb device (boot Android, enable USB debugging)' }
    Say 'The device is running MU300 Linux, not Android'
    Write-Host '  Installing and uninstalling happen from Android (slot a), so the device has to reboot first.'
    Write-Host '  I can ask it over SSH; you will be prompted for its password.'
    if ((Ask 'Reboot the device into Android now? (yes/no)' 'yes') -ne 'yes') { Die 'boot Android yourself (in Linux: sudo mu300-next-boot android && sudo reboot)' }
    # -t: sudo needs a terminal to ask for the device password; reboot cuts the connection, so watch the port
    foreach ($u in 'ubuntu', 'root') {
        Write-Host "  $u@$MU300_IP - enter the device password when asked (Ctrl-C to skip)"
        & ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR -o ConnectTimeout=8 "$u@$MU300_IP" `
            'if [ "$(id -u)" = 0 ]; then S=; else S=sudo; fi; $S sh -c "/opt/mu300/bin/mu300-next-boot android && sync && reboot"'
        $gone = $false
        for ($i = 0; $i -lt 8; $i++) {
            if (-not (Test-NetConnection -ComputerName $MU300_IP -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)) { $gone = $true; break }
            Start-Sleep 5
        }
        if ($gone) { Write-Host '  rebooting'; break }
    }
    Write-Host '  waiting for Android'
    for ($i = 0; $i -lt 60; $i++) {
        if ((& adb get-state 2>$null) -match 'device') { break }
        Start-Sleep 5
    }
    if ((& adb get-state 2>$null) -notmatch 'device') { Die 'the device did not come back as Android; boot it yourself (mu300-next-boot android)' }
    Write-Host '  Android is up'
}
if ((SuDo 'id -u') -ne '0') { Die 'su does not work on the device' }
$model = "$(SuDo 'getprop ro.product.model') / $(SuDo 'getprop ro.product.device')"
Write-Host "device: $model"
if ($model -notmatch 'MU300|F50|mu300') {
    if ((Ask 'This does not look like a ZTE F50/MU300. Continue anyway? (yes/no)' 'no') -ne 'yes') { exit 1 }
}
if ((SuDo 'getprop ro.boot.slot_suffix') -ne '_a') { Die 'Android must be running from slot a' }

Say 'Locating free eMMC space after the last partition'
$parts = (SuDo 'e=0; for p in /sys/block/mmcblk0/mmcblk0p*; do x=$(( $(cat $p/start) + $(cat $p/size) )); [ $x -gt $e ] && e=$x; done; echo $e $(cat /sys/block/mmcblk0/size)').Split(' ')
if ($parts.Count -ne 2) { Die 'could not read the partition table from the device (is su granted? try again)' }
[int64]$lastEnd = $parts[0]; [int64]$disk = $parts[1]
[int64]$start = [math]::Floor($lastEnd / 4096 + 1) * 4096
[int64]$end = [math]::Floor(($disk - 34) / 4096 - 1) * 4096
[int64]$OFF = $start * 512
[int64]$SIZE = ($end - $start) * 512
function Gib([int64]$b) { '{0:N1} GiB' -f ($b / 1GB) }
# What each choice needs: the installed systems measure ~320 MiB (OpenWrt) and ~580 MiB (Ubuntu), and an update
# keeps the previous one as <os>.old while the new one is unpacked, so allow for two of each plus working room.
[int64]$NEED_OPENWRT = 800MB; [int64]$NEED_UBUNTU = 1600MB; [int64]$NEED_BOTH = 2400MB
Write-Host "eMMC: $(Gib ($disk * 512)) ($disk sectors), partitions end at $(Gib ($lastEnd * 512)) (sector $lastEnd), free after them: $(Gib $SIZE)"
# Smaller eMMC variants leave less room behind userdata, and how much is needed depends on the choice further
# down - OpenWrt alone fits in a few hundred megabytes. So refuse only what cannot hold anything at all, and
# check the real requirement once the systems are known. There is nowhere else to put this region on these
# devices: userdata is metadata-encrypted (dm-default-key), so an image file inside it cannot be read from
# Linux, and the spare-looking blackbox and fulldumpdb partitions are written by the firmware itself.
if ($SIZE -lt 700MB) {
    $mib = [int64]($SIZE / 1MB)
    Die "only $mib MiB of free space after the last partition: this device has a different layout, nothing is changed.`nPlease report the numbers above (eMMC size and where the partitions end); they identify the variant."
}

$existing = 'no'
foreach ($cand in @($OFF, 27762098176)) {
    $m = (SuDo "dd if=/dev/block/mmcblk0 bs=1 skip=$($cand + 1080) count=2 2>/dev/null | od -An -tx1") -replace '\s', ''
    $l = (SuDo "dd if=/dev/block/mmcblk0 bs=1 skip=$($cand + 1144) count=16 2>/dev/null") -replace '\0', ''
    if ($m -eq '53ef' -and $l.Trim() -eq 'mu300root') {
        $blocks = [int64]((SuDo "dd if=/dev/block/mmcblk0 bs=1 skip=$($cand + 1028) count=4 2>/dev/null | od -An -tu4").Trim())
        $OFF = $cand; $SIZE = $blocks * 4096; $existing = 'yes'; break
    }
}
Write-Host "Linux region: offset $OFF, $(Gib $SIZE), existing mu300root filesystem: $existing"

$dirty = 0
if ($existing -eq 'no') {
    $step = [int64]($SIZE / 1MB / 16)
    $probe = (0..15 | ForEach-Object { [int64]($OFF / 1MB) + $_ * $step }) -join ' '
    $dirty = [int](SuDo "n=0; for s in $probe; do c=`$(dd if=/dev/block/mmcblk0 bs=1048576 skip=`$s count=1 2>/dev/null | tr -d `"\000`" | wc -c); [ `$c -gt 0 ] && n=`$((n + 1)); done; echo `$n").Trim()
    Write-Host "data check: $dirty of 16 samples contain non-zero data"
}
if ($existing -eq 'yes') {
    $verdict = 'OK: a MU300 Linux installation is already present (it can be kept or replaced)'
} elseif ($dirty -gt 0) {
    $verdict = 'WARNING: the unpartitioned space is not empty; it may be used by this firmware. Installing overwrites it'
} elseif ($SIZE -ge 20GB) {
    $verdict = 'OK: free and empty, same layout as the tested device (~32 GiB after userdata on the 64 GB eMMC)'
} elseif ($SIZE -ge $NEED_BOTH) {
    $verdict = 'OK: free and empty, smaller than on the tested device but enough for both systems'
} elseif ($SIZE -ge $NEED_UBUNTU) {
    $verdict = 'OK: free and empty, but room for one system only (Ubuntu or OpenWrt, not both)'
} else {
    $verdict = 'OK: free and empty, but small: OpenWrt fits, Ubuntu does not'
}
Write-Host "result: $verdict"
if ($Check) {
    Write-Host "`nNothing was written. Android version: $(SuDo 'getprop ro.build.display.id')"
    exit 0
}
if ($dirty -gt 0 -and (Ask 'Type overwrite to use this region anyway' 'no') -ne 'overwrite') { Die 'cancelled' }

Say 'What should be installed?'
Write-Host '  1) Ubuntu 24.04 LTS (full distribution, apt, ~500 MiB RAM in use)'
Write-Host "  2) OpenWrt (router, LuCI web UI, ~140 MiB RAM in use)"
Write-Host '  3) both (switch later with: mu300-os ubuntu|openwrt)'
if ($SIZE -lt $NEED_BOTH) {
    $fits = if ($SIZE -ge $NEED_UBUNTU) { 'one system fits, not both' } else { 'only OpenWrt fits' }
    Write-Host "  (this device has $(Gib $SIZE): $fits)"
}
switch (Ask 'Choice' '3') {
    '1' { $OSES = @('ubuntu') }
    '2' { $OSES = @('openwrt') }
    '3' { $OSES = @('ubuntu', 'openwrt') }
    default { Die 'invalid choice' }
}
$need = if ($OSES.Count -eq 2) { $NEED_BOTH } elseif ($OSES[0] -eq 'ubuntu') { $NEED_UBUNTU } else { $NEED_OPENWRT }
if ($SIZE -lt $need) {
    $needMib = [int64]($need / 1MB); $haveMib = [int64]($SIZE / 1MB)
    Die "that choice needs about $needMib MiB and this device has $haveMib MiB of free space"
}
$BOOT_OS = $OSES[0]
if ($OSES.Count -eq 2) {
    $BOOT_OS = Ask 'Which one should boot (ubuntu/openwrt)' 'ubuntu'
    if ($BOOT_OS -notin @('ubuntu', 'openwrt')) { Die 'invalid system' }
}
$DEFAULT_LINUX = if ((Ask 'Boot Linux by default instead of Android (falls back to Android if Linux fails)? (yes/no)' 'yes') -eq 'yes') { 1 } else { 0 }
$IMPORT_HOTSPOT = if ((Ask "Copy Android's hotspot name and password to Linux? (yes/no)" 'yes') -eq 'yes') { 1 } else { 0 }
$gpu = Ask 'Include the Mali GPU (OpenCL) userspace (~90 MiB)? (yes/no)' 'yes'
$FORMAT = 0; $WIPE_LEGACY = 0; $UPDATE = 0
if ($existing -eq 'no') {
    $FORMAT = 1
} else {
    Write-Host ''
    Write-Host '  A MU300 Linux installation is already on this device.'
    Write-Host '    update  reinstall the systems and keep settings and data (/etc/mu300, users and home directories,'
    Write-Host '            /usr/local, SSH host keys, OpenWrt UCI config, services you enabled yourself)'
    Write-Host '    wipe    erase the Linux filesystem and install from scratch'
    switch (Ask 'update or wipe' 'update') {
        'update' { $UPDATE = 1 }
        'wipe' { $FORMAT = 1 }
        default { Die 'invalid choice' }
    }
    if ($FORMAT -eq 0 -and $OSES -contains 'ubuntu') { $WIPE_LEGACY = 1 }
}
$pw1 = Read-Host -AsSecureString 'Password for the "ubuntu" user (Ubuntu) and "root" (OpenWrt)'
$pw2 = Read-Host -AsSecureString 'Repeat'
$p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
$p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))
if ($p1 -ne $p2 -or $p1.Length -lt 6) { Die 'passwords differ or are shorter than 6 characters' }

New-Item -ItemType Directory -Force -Path "$Work\dumps", "$Work\firmware" | Out-Null
Say "Pulling device data into $Work (stays on this computer)"
SuDoToFile 'cat /dev/block/by-name/boot_a' "$Work\dumps\boot_a.img"
SuDoToFile 'dd if=/dev/block/by-name/misc bs=4096 count=1 2>/dev/null' "$Work\dumps\misc-head.bin"
if ((Get-Item "$Work\dumps\boot_a.img").Length -lt 1MB) { Die 'pulling boot_a failed' }
if (-not (Test-Path "$Work\android-subset")) { Python "$Top\android-vendor\extract_subset.py" "$Work\android-subset" }
foreach ($f in 'wcnmodem.bin', 'gnssmodem.bin', 'wifi_board_config.ini', 'wifi_board_config_ab.ini', 'bt_configure_pskey.ini', 'bt_configure_rf.ini') {
    foreach ($d in '/odm/firmware', '/vendor/firmware', '/vendor/etc') {
        if ((SuDo "[ -f $d/$f ] && echo y") -eq 'y') { SuDoToFile "cat $d/$f" "$Work\firmware\$f"; break }
    }
}
if ($gpu -eq 'yes' -and -not (Test-Path "$Work\android-gpu-subset")) {
    $env:MU300_CLOSURE_ROOT = "$Work\android-gpu-subset"
    Python "$Top\android-vendor\pull_closure.py" /vendor/lib64/libOpenCL.so /vendor/lib64/egl/libGLES_mali.so /vendor/lib64/hw/vulkan.ums9620.so
}

Say "Downloading release $Release"
$REL = "$Work\release\$Release"
New-Item -ItemType Directory -Force -Path $REL | Out-Null
$base = if ($ReleaseUrl) { $ReleaseUrl } else { "https://github.com/$Repo/releases/download/$Release" }
Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$REL\SHA256SUMS" -UseBasicParsing
$sums = @{}
foreach ($line in Get-Content "$REL\SHA256SUMS") {
    $p = $line -split '\s+', 2
    if ($p.Count -eq 2) { $sums[$p[1].TrimStart('*')] = $p[0] }
}
$files = @('mu300-kernel.tar.gz') + ($OSES | ForEach-Object { "mu300-$_-rootfs.tar.gz" })
foreach ($f in $files) {
    if (-not $sums.ContainsKey($f)) { Die "$f is not part of release $Release" }
    $have = if (Test-Path "$REL\$f") { (Get-FileHash "$REL\$f" -Algorithm SHA256).Hash.ToLower() } else { '' }
    if ($have -ne $sums[$f]) {
        Write-Host "  $f"
        Fetch "$base/$f" "$REL\$f.part"
        if ((Get-FileHash "$REL\$f.part" -Algorithm SHA256).Hash.ToLower() -ne $sums[$f]) { Die "checksum mismatch for $f" }
        Move-Item -Force "$REL\$f.part" "$REL\$f"
    }
}
Remove-Item -Recurse -Force "$REL\kernel" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$REL\kernel" | Out-Null
& tar -xzf "$REL\mu300-kernel.tar.gz" -C "$REL\kernel"

Say 'Adding the vendor files from your device to the images'
foreach ($os in $OSES) {
    $argv = @("$Top\tools\vendor-overlay.py", '--os', $os, '--firmware', "$Work\firmware",
        '--android-subset', "$Work\android-subset", '--out', "$Work\mu300-vendor-$os.tar.gz")
    if ($gpu -eq 'yes' -and (Test-Path "$Work\android-gpu-subset")) { $argv += @('--gpu-subset', "$Work\android-gpu-subset") }
    Python @argv
}
$PWHASH = ($p1 | Python "$Top\tools\sha512crypt.py").Trim()

Say 'Building the boot image'
WriteUnix "$Work\init" (((Get-Content -Raw "$Top\boot\init") -replace '(?m)^ROOT_OFFSET=[0-9]*', "ROOT_OFFSET=$OFF"))
Python "$Top\boot\build-boot-image.py" --stock-boot "$Work\dumps\boot_a.img" --misc-head "$Work\dumps\misc-head.bin" `
    --kernel "$REL\kernel\Image" --modules "$REL\kernel\modules" --init "$Work\init" --busybox "$REL\kernel\busybox" `
    --logdw "$REL\kernel\logdw" --ueventd-perms "$Top\android-vendor\ueventd-perms.sh" `
    --android-subset "$Work\android-subset" --out "$Work\boot-linux-slotb.img" | Out-Null

Say 'Ready to install'
Write-Host "  source:         prebuilt release $Release + vendor files from this device"
Write-Host "  systems:        $($OSES -join ' ') (boots: $BOOT_OS)"
Write-Host "  default boot:   $(if ($DEFAULT_LINUX -eq 1) { 'Linux' } else { 'Android, Linux on demand' })"
Write-Host "  filesystem:     $(if ($FORMAT -eq 1) { 'CREATE new ext4 (erases the Linux region)' } else { 'keep existing' })"
if ($UPDATE -eq 1) { Write-Host '  update:         settings and user data of the chosen systems are kept, everything else is replaced' }
Write-Host "  writes:         Linux region at offset $OFF, boot_b, 32 bytes of misc (boot_a, GPT and userdata are not touched)"
if ((Ask 'Type INSTALL to continue' 'no') -ne 'INSTALL') { Die 'cancelled' }

Say 'Copying to the device'
& adb push "$Top\tools\android-mount-mu300root.sh" "$Top\tools\android-install.sh" "$T/" | Out-Null
foreach ($os in $OSES) {
    & adb push "$REL\mu300-$os-rootfs.tar.gz" "$T/mu300-$os.tar.gz" | Out-Null
    & adb push "$Work\mu300-vendor-$os.tar.gz" "$T/mu300-vendor-$os.tar.gz" | Out-Null
}
$envFile = "$Work\mu300-install.env"
$lines = @("OFF=$OFF", "SIZE=$SIZE", "OFF_S=$($OFF / 512)", "SIZE_S=$($SIZE / 512)", "FORMAT=$FORMAT",
    "OSES=`"$($OSES -join ' ')`"", "WIPE_LEGACY=$WIPE_LEGACY", "UPDATE=$UPDATE", "BOOT_OS=$BOOT_OS", "DEFAULT_LINUX=$DEFAULT_LINUX",
    "IMPORT_HOTSPOT=$IMPORT_HOTSPOT", "PWHASH='$PWHASH'")
WriteUnix $envFile (($lines -join "`n") + "`n")
& adb push $envFile "$T/mu300-install.env" | Out-Null
Remove-Item $envFile
$log = SuDo "sh $T/android-install.sh"
Write-Host $log
if ($log -notmatch 'MU300-INSTALL-OK') { Die 'installation on the device failed; boot_b and misc were not changed' }

Say 'Writing boot_b and arming slot b'
$EXP = (Get-Content "$Work\boot-linux-slotb.json" | ConvertFrom-Json).sha256
& adb push "$Work\boot-linux-slotb.img" "$T/mu300-boot.img" | Out-Null
& adb push "$Work\boot-linux-slotb.misc-slot-b-trial.bin" "$T/mu300-bc-b.bin" | Out-Null
if ((SuDo "sha256sum $T/mu300-boot.img").Split(' ')[0] -ne $EXP) { Die 'pushed boot image hash mismatch' }
SuDo "dd if=$T/mu300-boot.img of=/dev/block/by-name/boot_b bs=4M && sync" | Out-Null
if ((SuDo 'sha256sum /dev/block/by-name/boot_b').Split(' ')[0] -ne $EXP) { Die 'boot_b verify failed (slot a still active, Android keeps booting)' }
SuDo "dd if=$T/mu300-bc-b.bin of=/dev/block/by-name/misc bs=1 seek=2048 conv=notrunc && sync && rm $T/mu300-boot.img $T/mu300-bc-b.bin" | Out-Null

# on-device switch for later: one command in Android instead of plugging into a computer (needs Magisk)
Say 'Installing the on-device switch (Magisk module)'
$ModSrc = Join-Path $Top 'android\magisk\mu300-linux-switch'
$Mod = '/data/adb/modules/mu300_linux_switch'
$MTmp = "$T/mu300-magisk"
if ((SuDo 'magisk -v')) {
    & adb shell "rm -rf $MTmp" 2>$null | Out-Null
    & adb shell "mkdir -p $MTmp/system/bin" 2>$null | Out-Null
    foreach ($f in 'module.prop', 'switch.sh', 'action.sh') {
        & adb push (Join-Path $ModSrc $f) "$MTmp/$f" 2>$null | Out-Null
    }
    & adb push (Join-Path $ModSrc 'system\bin\mu300-linux') "$MTmp/system/bin/mu300-linux" 2>$null | Out-Null
    SuDo "rm -rf $Mod && mkdir -p $Mod/system/bin && cp -a $MTmp/module.prop $MTmp/switch.sh $MTmp/action.sh $Mod/ && cp -a $MTmp/system/bin/mu300-linux $Mod/system/bin/ && chown -R 0:0 $Mod && chmod 755 $Mod/switch.sh $Mod/action.sh $Mod/system/bin/mu300-linux && chmod 644 $Mod/module.prop && rm -rf $MTmp && sync" | Out-Null
    if ((SuDo "[ -x $Mod/switch.sh ] && echo yes") -eq 'yes') {
        Write-Host "  installed: 'su -c mu300-linux' on the device starts Linux after the next Android boot"
    } else {
        Write-Host '  could not install it; ./install.ps1 keeps working either way'
    }
} else {
    Write-Host '  no Magisk (or no root) on this device - skipped'
}

Say "Done. Rebooting into $BOOT_OS"
Write-Host "  USB network: 192.168.77.1   SSH: $(if ($BOOT_OS -eq 'ubuntu') { 'ubuntu@192.168.77.1' } else { 'root@192.168.77.1, LuCI http://192.168.77.1' })"
Write-Host '  switch systems: mu300-os ubuntu|openwrt   back to Android: mu300-next-boot android'
Write-Host '  back to Linux from Android (with Magisk): su -c mu300-linux'
& adb reboot | Out-Null
