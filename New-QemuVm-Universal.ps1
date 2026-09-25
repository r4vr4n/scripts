<#
.SYNOPSIS
    New-GpuVm.ps1 v3.2 - GPU-accelerated Omarchy/Ubuntu QEMU VM builder for
    Windows x86_64 hosts (WHPX), with a safe-exit design.

.DESCRIPTION
    Probes every external fact (QEMU build, WHPX, GPU device, firmware,
    ports) before acting; never overwrites disks or NVRAM; backs up
    launchers before regenerating them; logs every decision to
    <VmDir>\setup-log.txt; exits with a distinct code on failure.

    Generated launcher: <distro>-launch.ps1 (+ double-clickable .cmd shim)
      -BootInstaller   boot the ISO (first install / rescue)
      -FullScreen      start fullscreen (Ctrl+Alt+F toggles any time)

.PARAMETER IsoPath          Path to the Omarchy or Ubuntu .iso (asked if omitted)
.PARAMETER VmDir            Target directory (asked if omitted, created if missing)
.PARAMETER Vcpus            vCPU count (default 8)
.PARAMETER RamGB            Guest RAM in GB (default 8)
.PARAMETER DiskGB           Sparse qcow2 size in GB (default 60)
.PARAMETER ExpectedSha256   Optional: fail unless the ISO SHA256 matches
.PARAMETER Unattended       Never prompt; decisions resolve to the safe default
.PARAMETER SkipProbes       Skip WHPX/GPU launch probes (assume from help output)
.PARAMETER NoPause          Do not pause before closing on error
.PARAMETER LaunchNow        Boot the installer immediately after setup

.EXAMPLE
    .\New-GpuVm.ps1 -Verbose
.EXAMPLE
    .\New-GpuVm.ps1 -IsoPath D:\isos\omarchy.iso -VmDir D:\vms\omarchy -LaunchNow

.NOTES
    Exit codes:
      0  success
      1  unexpected error
      2  aborted at a prompt / reboot-required state reached
      3  virtualization / accelerator failure
      4  input or validation failure (ISO, paths, hash)
      5  tooling failure (qemu-img, OVMF firmware, launcher generation)

    Requires Windows PowerShell 5.1+ (works on PS 7). Admin needed only to
    enable the Hypervisor Platform feature.
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$VmDir,
    [ValidateRange(2, 64)]  [int]$Vcpus = 8,
    [ValidateRange(1, 256)] [int]$RamGB = 8,
    [ValidateRange(8, 1024)][int]$DiskGB = 60,
    [string]$ExpectedSha256,
    [switch]$Unattended,
    [switch]$SkipProbes,
    [switch]$NoPause,
    [switch]$LaunchNow
)

# ------------------------------------------------------------- state & helpers
$script:exitCode = 0
$script:Warns = 0
$script:vmDir = $null
$script:qemuExe = $null
$script:LogPath = $null
$script:LogBuf = New-Object System.Collections.Generic.List[string]
$script:ProbePids = New-Object System.Collections.Generic.List[int]

function Log {
    param([string]$m)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    $script:LogBuf.Add($line); Write-Verbose $m
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
}
function Set-LogTarget {
    param([string]$dir)
    $script:LogPath = Join-Path $dir 'setup-log.txt'
    if ($script:LogBuf.Count) { Add-Content -LiteralPath $script:LogPath -Value $script:LogBuf -Encoding UTF8 -ErrorAction SilentlyContinue }
}
function Warn {
    param([string]$m)
    $script:Warns++; Write-Warning $m; Log "WARN: $m"
}
function Fail { param([string]$Kind, [string]$Message) throw ('{0}|{1}' -f $Kind, $Message) }

function Ask {
    # prompts; in Unattended mode returns the safe default instead
    param([string]$Prompt, [string[]]$Valid, [string]$Default, [string]$UnattendedDefault = 'n')
    if ($Unattended) { Log ("UNATTENDED: auto-answer '{0}' -> {1}" -f $UnattendedDefault, $Prompt); return $UnattendedDefault }
    while ($true) {
        $hint = $Valid -join '/'; if ($Default) { $hint += " [$Default]" }
        $ans = (Read-Host -Prompt "$Prompt ($hint)").Trim().ToLower()
        if (-not $ans -and $Default) { $ans = $Default.ToLower() }
        if ($Valid -contains $ans) { return $ans }
        Write-Host "  Please answer one of: $($Valid -join ', ')"
    }
}
function Confirm-OrAbort {
    param([string]$Message)   # attention gate: continue explicitly, else safe-exit
    $a = Ask -Prompt "$Message - continue anyway?" -Valid 'y', 'n' -Default 'n' -UnattendedDefault 'n'
    if ($a -ne 'y') { Fail 'ABORT' $Message }
}

# Native output, stdout+stderr merged. PS 5.1 + EAP='Stop' + '2>&1' throws
# NativeCommandError on the first stderr line, so EAP is relaxed here only.
function Get-NativeOutput {
    param([string]$FilePath, [string[]]$ArgumentList)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { (& $FilePath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine }
    finally { $ErrorActionPreference = $prev }
}
function Invoke-Native {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$What)  # throws on nonzero exit
    $out = Get-NativeOutput -FilePath $FilePath -ArgumentList $ArgumentList
    if ($LASTEXITCODE -ne 0) { Fail 'TOOL' ("{0} failed (exit {1}): {2}" -f $What, $LASTEXITCODE, ($out -replace '\s+', ' ').Trim()) }
    return $out
}
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Launches a throwaway paused VM (-S: CPUs never execute) to exercise init
# paths. WHPX + device realize still run, so real failures surface HERE,
# not at first VM boot. Success = process still alive after N seconds.
function Test-QemuLaunch {
    param([string[]]$QemuArgs, [string]$Tag, [int]$Seconds = 4)
    $safeTag = ($Tag -replace '[^a-zA-Z0-9_-]', '_')
    $errFile = Join-Path $script:vmDir ("probe-{0}.err" -f $safeTag)
    $argList = @('-name', "probe-$safeTag", '-machine', 'q35', '-nodefaults', '-display', 'none', '-monitor', 'none', '-S') + $QemuArgs
    $p = $null; $ok = $false; $detail = ''
    try {
        $sp = @{
            FilePath              = $script:qemuExe
            ArgumentList          = $argList
            NoNewWindow           = $true
            PassThru              = $true
            RedirectStandardError = $errFile
        }
        $p = Start-Process @sp
        $script:ProbePids.Add($p.Id) | Out-Null
        Start-Sleep -Seconds $Seconds
        $ok = -not $p.HasExited
    }
    catch { $detail = $_.Exception.Message }
    finally { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    if (Test-Path $errFile) {
        $t = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        if ($t) { $detail = ($detail + ' ' + ($t -replace '\s+', ' ').Trim()).Trim() }
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ OK = $ok; Detail = $detail }
}

function Save-FirmwareFile {
    param([string]$Url, [string]$Dest, [long]$MinBytes)
    if (Test-Path $Dest) { return }
    $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # 5.1 IWR progress is very slow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072   # TLS 1.2
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
        if ((Get-Item $Dest).Length -lt $MinBytes) { throw "downloaded file is suspiciously small ($((Get-Item $Dest).Length) bytes)" }
    }
    catch {
        Remove-Item $Dest -Force -ErrorAction SilentlyContinue
        Fail 'TOOL' ("Firmware download failed: {0}. Manual fix: place the file at '{1}' and re-run." -f $_.Exception.Message, $Dest)
    }
    finally { $ProgressPreference = $prev }
}

# ============================================================== MAIN
try {
    Write-Host '=== New-GpuVm v3.2 - Omarchy/Ubuntu QEMU builder (safe-exit) ===' -ForegroundColor Cyan
    Log 'Setup started (New-GpuVm v3.2).'

    # ---------------------------------------------------- [1/9] inputs
    if (-not $IsoPath) { $IsoPath = Read-Host 'Path to the Omarchy/Ubuntu ISO' }
    if (-not $VmDir) { $VmDir = Read-Host 'VM target directory' }
    $IsoPath = $IsoPath.Trim().Trim('"').Trim("'")    # tolerate pasted quoted paths
    $VmDir = $VmDir.Trim().Trim('"').Trim("'")

    if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { Fail 'ENV' 'This script targets x86_64 hosts. On Windows-on-ARM use qemu-system-aarch64 (see QEMU WHPX docs).' }
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { Fail 'INPUT' "ISO not found: '$IsoPath'" }
    if ($IsoPath -like '*OneDrive*') { Warn 'ISO is inside OneDrive - reading a multi-GB file may force a cloud download.' }
    if ([io.path]::GetExtension($IsoPath) -ne '.iso') { Warn 'ISO path does not end in .iso - verify this is the right file.' }
    $isoLen = (Get-Item -LiteralPath $IsoPath).Length
    if ($isoLen -lt 500MB) { Warn ('ISO is only {0:N0} MB - suspiciously small for a desktop ISO; verify the download.' -f ($isoLen / 1MB)) }
    $IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path

    if (-not (Test-Path -LiteralPath $VmDir -PathType Container)) { New-Item -ItemType Directory -Path $VmDir -Force | Out-Null }
    $script:vmDir = (Resolve-Path -LiteralPath $VmDir).Path
    Set-LogTarget $script:vmDir
    try {
        $rw = Join-Path $script:vmDir ".rwtest-$PID"
        [io.file]::WriteAllText($rw, 'ok'); Remove-Item $rw -Force
    }
    catch { Fail 'INPUT' "VM directory is not writable: '$($script:vmDir)' ($($_.Exception.Message))" }
    if ($script:vmDir -like '*OneDrive*') { Warn 'Target is inside OneDrive: a growing qcow2 will be re-synced constantly. Use a local drive.' }

    if ($ExpectedSha256) {
        $want = $ExpectedSha256.Trim().ToUpper() -replace '\s', ''
        $got = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash
        if ($got -ne $want) { Fail 'INPUT' "ISO SHA256 mismatch: expected $want, got $got" }
        Log 'ISO SHA256 verified.'
    }

    # ---------------------------------------------------- [2/9] QEMU health
    $qemuCmd = Get-Command qemu-system-x86_64.exe -ErrorAction SilentlyContinue
    if (-not $qemuCmd) { Fail 'INPUT' 'qemu-system-x86_64.exe is not on PATH. Install QEMU or add its bin folder to PATH.' }
    $script:qemuExe = $qemuCmd.Source
    $qemuDir = Split-Path -Parent $script:qemuExe

    $verOut = Get-NativeOutput $script:qemuExe @('--version')
    if ($LASTEXITCODE -ne 0 -or -not $verOut) {
        Fail 'INPUT' ("QEMU at '{0}' failed to run (exit {1}). Usual cause: the exe was copied out of its folder without its DLLs - reinstall or fix PATH." -f $script:qemuExe, $LASTEXITCODE)
    }
    $verLine = ($verOut -split [Environment]::NewLine)[0]
    $qVer = [version]'0.0'
    if ($verLine -match 'version\s+(\d+)\.(\d+)(?:\.(\d+))?') {
        $patch = if ($Matches[3]) { $Matches[3] } else { '0' }
        $qVer = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $patch)
    }
    Log "QEMU: $verLine"
    if ($qVer -lt [version]'9.2.0') { Warn "QEMU $qVer < 9.2: Venus (Vulkan) unavailable; VirGL OpenGL may still work." }

    # which virtio display devices does this binary actually ship?
    $devHelp = Get-NativeOutput $script:qemuExe @('-device', 'help')
    $needsVgaNone = $false    # non-VGA virtio variants do NOT suppress default VGA (dual-display trap)
    if ($devHelp -match 'virtio-vga-gl') { $gpuDev = 'virtio-vga-gl'; $gpuKind = 'gl' }
    elseif ($devHelp -match 'virtio-gpu-gl') { $gpuDev = 'virtio-gpu-gl'; $gpuKind = 'gl'; $needsVgaNone = $true }
    elseif ($devHelp -match 'virtio-vga') { $gpuDev = 'virtio-vga'; $gpuKind = '2d' }
    elseif ($devHelp -match 'virtio-gpu') { $gpuDev = 'virtio-gpu'; $gpuKind = '2d'; $needsVgaNone = $true }
    else { $gpuDev = 'VGA'; $gpuKind = 'none' }
    Log "GPU device detection: $gpuDev (kind=$gpuKind, vga-none=$needsVgaNone)"

    # display backend must exist, or the launcher would fail on every boot
    $dispHelp = Get-NativeOutput $script:qemuExe @('-display', 'help')
    if ($dispHelp -match '\bsdl\b') { $display = 'sdl,gl=on' }
    elseif ($dispHelp -match '\bgtk\b') { $display = 'gtk,gl=on,show-cursor=on' }
    else {
        Confirm-OrAbort 'No SDL/GTK display backend in this build - the VM would be HEADLESS (no window).'
        $display = 'none'; Warn 'Display=none: 3D will not be visible even if the GPU device initializes.'
    }
    Log "Display backend: $display"

    # audio backend: degrade gracefully instead of shipping a launcher that cannot boot
    $audioOK = [bool](Get-NativeOutput $script:qemuExe @('-audiodev', 'help') -match '\bdsound\b')
    if (-not $audioOK) { Warn 'No dsound audio backend in this build - VM will run without audio.' }

    # ---------------------------------------------------- [3/9] host sizing
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $logical = (Get-CimInstance Win32_Processor | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    $ramHostGB = [int][math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $freeMemGB = [int][math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB)
    Write-Verbose "Host: $($cpu.Name) | $logical logical cores | $ramHostGB GB RAM ($freeMemGB GB free)"
    if ($Vcpus -gt ($logical - 2)) { Warn "$Vcpus vCPUs of $logical logical cores starves Windows; consider $($logical - 4)." }
    if ($cpu.Name -match '12th|13th|14th Gen|Core Ultra') { Warn 'Hybrid Intel CPU: vCPUs cannot be pinned to P-cores under WHPX; expect some jitter.' }
    if (($RamGB + 4) -gt $ramHostGB) { Warn "$RamGB GB guest + Windows on $ramHostGB GB is tight; consider $($ramHostGB - 6) GB." }
    elseif (($RamGB + 2) -gt $freeMemGB) { Warn "Only $freeMemGB GB memory currently FREE - close apps or lower -RamGB to avoid host swapping." }
    if ($script:vmDir -match '^([A-Za-z]):') {
        $psd = Get-PSDrive $Matches[1] -ErrorAction SilentlyContinue
        if ($psd -and (($DiskGB + 2) -gt [math]::Round($psd.Free / 1GB))) {
            Warn ('Drive {0}: has {1} GB free; the qcow2 may grow to {2} GB.' -f $Matches[1], [math]::Round($psd.Free / 1GB), $DiskGB)
        }
    }
    if ($env:SESSIONNAME -like 'RDP*') { Warn 'RDP session detected: host OpenGL (gl=on) often fails over RDP. Test on the physical console.' }

    # ---------------------------------------------------- [4/9] distro
    $isoName = Split-Path -Leaf $IsoPath
    if ($isoName -match 'omarchy') { $isOma = $true }
    elseif ($isoName -match 'ubuntu') { $isOma = $false }
    else {
        if ($Unattended) { Fail 'INPUT' "Cannot determine distro from ISO name '$isoName' in unattended mode - use a clearly named ISO." }
        Write-Warning "ISO name '$isoName' doesn't reveal the distro."
        $a = Ask '(o)marchy or (u)buntu?' 'o', 'u' $null 'x'
        $isOma = ($a -eq 'o')
    }
    $distro = if ($isOma) { 'omarchy' } else { 'ubuntu' }
    Log "Distro: $distro"

    # ---------------------------------------------------- [5/9] accelerator
    $hypPresent = $false
    try { $hypPresent = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch {}
    $whpxCompiled = [bool](Get-NativeOutput $script:qemuExe @('-accel', 'help') -match '\bwhpx\b')

    if (-not $whpxCompiled) {
        Warn 'This QEMU build has no WHPX accelerator compiled in - use a Windows build (stock qemu.org, MSYS2, WINQ-EMU).'
        Confirm-OrAbort 'Without WHPX only TCG (pure emulation) is possible - a desktop will be unusably slow.'
        $accel = 'tcg'
    }
    else {
        # attention flow: offer to enable the feature (the #1 root cause) before failing
        if (-not $hypPresent -and -not $SkipProbes) {
            $featState = $null
            try { $featState = (Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction Stop).State } catch {}
            if ($featState -and $featState -ne 'Enabled') {
                $a = Ask 'Windows Hypervisor Platform is NOT enabled. Enable it now? (needs admin; REBOOT afterwards)' 'y', 'n' 'n' 'n'
                if ($a -eq 'y') {
                    if (-not (Test-Admin)) { Fail 'ENV' 'Enabling Hypervisor Platform requires an elevated (Run as Administrator) PowerShell.' }
                    $d = Start-Process dism.exe -ArgumentList '/online', '/Enable-Feature', '/FeatureName:HypervisorPlatform', '/All', '/NoRestart' -Wait -PassThru
                    # 0 = success, 3010 = success + reboot required
                    if ($d.ExitCode -ne 0 -and $d.ExitCode -ne 3010) {
                        Fail 'ENV' "DISM failed (exit $($d.ExitCode)). Enable manually: optionalfeatures.exe -> Windows Hypervisor Platform."
                    }
                    Fail 'ABORT' 'Windows Hypervisor Platform enabled. REBOOT now, then re-run this script.'
                }
            }
            elseif (-not $featState -and -not $hypPresent) {
                Warn 'Hyper-V hypervisor not running and feature state unknown. If the probe fails: enable "Windows Hypervisor Platform" (optionalfeatures.exe) + firmware virtualization, reboot.'
            }
        }
        if ($SkipProbes) {
            $accel = 'whpx'; Write-Verbose 'Probes skipped: assuming WHPX works.'
        }
        else {
            Write-Host 'Probing WHPX (~4 s)...'
            $accel = $null; $lastDetail = ''
            $candidates = @('whpx'); if ($hypPresent) { $candidates += 'whpx,kernel-irqchip=off' }   # documented wedge workaround, 2nd chance
            foreach ($cand in $candidates) {
                $r = Test-QemuLaunch -QemuArgs @('-accel', $cand) -Tag ('accel-' + $cand)
                if ($r.OK) { $accel = $cand; Log "WHPX probe OK ($cand)"; break }
                $lastDetail = $r.Detail; Log "WHPX probe FAILED ($cand): $($r.Detail)"
            }
            if (-not $accel) {
                $remedy = if (-not $hypPresent) { "Enable 'Windows Hypervisor Platform' (optionalfeatures.exe) + virtualization in firmware, REBOOT, re-run." }
                else { "WHPX init failed even with kernel-irqchip=off. Check QEMU build sanity / hypervisorlaunchtype, or try another Windows QEMU build." }
                Confirm-OrAbort "WHPX failed to start ($lastDetail). TCG fallback = unusably slow desktop. $remedy"
                $accel = 'tcg'
            }
        }
    }
    if ($accel -eq 'tcg') { Warn 'Running under TCG (pure emulation): expect an unusably slow desktop. Fix WHPX and re-run before real use.' }
    $cpuModel = if ($accel -eq 'whpx') { 'host' } else { 'max' }   # -cpu host is invalid under TCG

    # ---------------------------------------------------- [6/9] GPU
    if ($gpuKind -eq 'gl') {
        $hostmemGB = [math]::Max(1, [math]::Min(4, [int][math]::Floor($RamGB / 2)))
        $gpuArg = '{0},hostmem={1}G,blob=true' -f $gpuDev, $hostmemGB
        if ($isOma -and $qVer -ge [version]'9.2.0') { $gpuArg += ',venus=true' }   # Hyprland: Vulkan via Venus
    }
    else {
        $gpuArg = $gpuDev
    }
    if ($gpuKind -ne 'none' -and -not $SkipProbes) {
        Write-Host 'Probing GPU device init (~4 s)...'
        $r = Test-QemuLaunch -QemuArgs @('-accel', $accel, '-device', $gpuArg) -Tag 'gpu'
        if (-not $r.OK) {
            Warn "GPU '$gpuArg' failed to initialize: $($r.Detail)"
            $alt = if ($devHelp -match 'virtio-vga') { 'virtio-vga' } elseif ($devHelp -match 'virtio-gpu') { 'virtio-gpu' } else { 'VGA' }
            $needsVgaNone = ($alt -eq 'virtio-gpu')
            Log "GPU fallback -> $alt"
            $gpuKind = if ($alt -in 'virtio-vga', 'virtio-gpu') { '2d' } else { 'none' }
            $gpuArg = $alt
        }
    }
    if ($gpuKind -ne 'gl') {
        Confirm-OrAbort ('No working VirGL 3D path detected - the guest will SOFTWARE-render (llvmpipe). Better: install a virgl-capable Windows QEMU build (WINQ-EMU / qemu-virgl-whpx) and re-run.')
    }

    # ---------------------------------------------------- [7/9] firmware (OVMF)
    $code = $null; $varsTpl = $null
    $fwDirs = @($qemuDir, (Join-Path $qemuDir 'share'), (Join-Path $qemuDir 'share\qemu'), (Join-Path $qemuDir 'pc-bios'), (Join-Path $qemuDir '..\share\qemu'))
    foreach ($d in $fwDirs) { if (-not $code) { $c = Join-Path $d 'edk2-x86_64-code.fd'; if (Test-Path $c) { $code = $c } } }
    foreach ($d in $fwDirs) { if (-not $varsTpl) { $v = Join-Path $d 'edk2-i386-vars.fd'; if (Test-Path $v) { $varsTpl = $v } } }
    if (-not $code) {
        Write-Warning 'OVMF code image not found next to QEMU - downloading (qemu v9.2.0).'
        $code = Join-Path $script:vmDir 'edk2-x86_64-code.fd'
        Save-FirmwareFile 'https://raw.githubusercontent.com/qemu/qemu/v9.2.0/pc-bios/edk2-x86_64-code.fd' $code 1MB
    }
    if (-not $varsTpl) {
        Write-Warning 'OVMF vars template not found - downloading.'
        $varsTpl = Join-Path $script:vmDir 'edk2-i386-vars.fd'
        Save-FirmwareFile 'https://raw.githubusercontent.com/qemu/qemu/v9.2.0/pc-bios/edk2-i386-vars.fd' $varsTpl 100KB
    }
    Log "Firmware: code=$code vars-template=$varsTpl"

    $vars = Join-Path $script:vmDir "${distro}-VARS.fd"
    if (Test-Path $vars) { Log 'NVRAM preserved (idempotent re-run).' }
    else { Copy-Item $varsTpl $vars; Log 'NVRAM created from template.' }

    # ---------------------------------------------------- [8/9] disk + port
    $qemuImg = Join-Path $qemuDir 'qemu-img.exe'
    if (-not (Test-Path $qemuImg)) {
        $qi = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
        if (-not $qi) { Fail 'TOOL' 'qemu-img.exe not found next to QEMU nor on PATH - cannot create the disk.' }
        $qemuImg = $qi.Source
    }
    $disk = Join-Path $script:vmDir "${distro}.qcow2"
    if (Test-Path $disk) {
        Write-Warning "Disk already exists and will NOT be overwritten: $disk"
        $a = Ask 'Existing disk: (r)euse, create (n)ew numbered disk, (a)bort?' 'r', 'n', 'a' 'r' 'r'
        if ($a -eq 'a') { Fail 'ABORT' 'User chose not to proceed with an existing disk.' }
        if ($a -eq 'n') {
            $i = 1; while (Test-Path (Join-Path $script:vmDir ('{0}-{1}.qcow2' -f $distro, $i))) { $i++ }
            $disk = Join-Path $script:vmDir ('{0}-{1}.qcow2' -f $distro, $i)
            Invoke-Native $qemuImg @('create', '-f', 'qcow2', $disk, ('{0}G' -f $DiskGB)) 'qemu-img create' | Out-Null
        }
    }
    else {
        Invoke-Native $qemuImg @('create', '-f', 'qcow2', $disk, ('{0}G' -f $DiskGB)) 'qemu-img create' | Out-Null
        Log "Disk created: $disk (${DiskGB}G, sparse)"
    }

    $port = if ($isOma) { 2222 } else { 2223 }; $tries = 0
    while ($tries -lt 25) {
        $busy = $false
        try { $busy = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) } catch {}
        if (-not $busy) { break }
        Log "Port $port in use; trying next."; $port++; $tries++
    }
    if ($tries -ge 25) { Fail 'ENV' 'No free ssh port found in 2222-2246.' }

    # ---------------------------------------------------- [9/9] launcher
    $launchPs1 = Join-Path $script:vmDir "${distro}-launch.ps1"
    $launchCmd = Join-Path $script:vmDir "${distro}-launch.cmd"
    if (Test-Path $launchPs1) {
        $bak = "$launchPs1.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $launchPs1 $bak -Force
        Log "Backed up existing launcher -> $bak"
    }

    $launcher = @'
# @DISTRO@ VM launcher - generated by New-GpuVm.ps1 v3.2 on @DATE@.
# Re-running setup regenerates this file (previous copy saved as .bak-*).
# Usage: .\@DISTRO@-launch.ps1 [-BootInstaller] [-FullScreen]
#   -BootInstaller  boot the ISO (first install, or rescue/reinstall later)
#   -FullScreen     start fullscreen; Ctrl+Alt+F toggles any time
# After first install, run WITHOUT -BootInstaller.
# Verify 3D inside the guest:  glxinfo -B   -> renderer must be virgl (NOT llvmpipe).
param(
    [switch]$BootInstaller,
    [switch]$FullScreen
)
 $ErrorActionPreference = 'Stop'
 $hdBoot = if ($BootInstaller) { 1 } else { 0 }   # OVMF boots by bootindex, not -boot order

 $qemu = '@QEMU@'
 $a = @(
    '-name','@DISTRO@-vm',                                   # window title
    '-machine','q35',                                        # modern chipset (PCIe, ICH9)
    '-accel','@ACCEL@',                                      # whpx = Windows hypervisor; tcg = emulation fallback
    '-cpu','@CPU@',                                          # host = pass host features; max is required under TCG
    '-smp','@SMP@',                                          # @VCPUS@ vCPUs, 1 socket
    '-m','@RAM@G',                                           # guest RAM
    '-nodefaults',                                           # nothing implicit: every device below is deliberate
    # UEFI/OVMF: read-only firmware code + writable per-VM NVRAM
    '-drive','if=pflash,format=raw,readonly=on,file=@CODE@',
    '-drive','if=pflash,format=raw,file=@VARS@',
    # GPU: virtio-*-gl = paravirt GPU with VirGL 3D (host GL via ANGLE on Windows builds)
    #      blob+hostmem = required for GL4.6/Venus; venus=true adds Vulkan forwarding
    '-device','@GPU@',
@VGANONE@
    # SDL window with a host OpenGL context; gl=on is REQUIRED for virgl; vsync'd presentation
    '-display','@DISPLAY@',
    # system disk on virtio-blk; bootindex decides UEFI boot order
    '-drive','file=@DISK@,if=none,id=hd,format=qcow2',
    '-device',"virtio-blk-pci,drive=hd,bootindex=$hdBoot",
    # input: xHCI + tablet (seamless pointer) + keyboard; rng avoids boot-time entropy stalls
    '-device','qemu-xhci','-device','usb-tablet','-device','usb-kbd','-device','virtio-rng-pci',
    # user-mode NAT (no admin, no bridge); host port @PORT@ -> guest ssh
    '-device','virtio-net-pci,netdev=n0',
    '-netdev','user,id=n0,hostfwd=tcp:127.0.0.1:@PORT@-:22',
    '-rtc','base=utc'                                        # correct clock for Linux guests
)
if (@HAVEAUDIO@) {   # audio: DirectSound backend -> ICH9 HDA (PipeWire auto-detects in guest)
    $a += @('-audiodev','dsound,id=ao','-device','ich9-intel-hda','-device','hda-dup,audiodev=ao')
}
if ($BootInstaller) {   # installer ISO with top boot priority while installing
    $a += @('-drive','file=@ISO@,if=none,id=cd,readonly=on','-device','ide-cd,drive=cd,bootindex=0')
}
if ($FullScreen) { $a += '-full-screen' }

& $qemu @a
exit $LASTEXITCODE
'@

    # Token substitution: table-driven, no line-continuations to break on paste
    $tokens = [ordered]@{
        '@DATE@'      = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        '@QEMU@'      = $script:qemuExe
        '@DISTRO@'    = $distro
        '@ACCEL@'     = $accel
        '@CPU@'       = $cpuModel
        '@SMP@'       = "$Vcpus,sockets=1,cores=$Vcpus,threads=1"
        '@VCPUS@'     = "$Vcpus"
        '@RAM@'       = "$RamGB"
        '@CODE@'      = $code
        '@VARS@'      = $vars
        '@GPU@'       = $gpuArg
        '@DISPLAY@'   = $display
        '@VGANONE@'   = $(if ($needsVgaNone) { "    '-vga','none'," } else { '' })
        '@DISK@'      = $disk
        '@PORT@'      = "$port"
        '@ISO@'       = $IsoPath
        '@HAVEAUDIO@' = $(if ($audioOK) { '$true' } else { '$false' })
    }
    foreach ($t in $tokens.Keys) { $launcher = $launcher.Replace([string]$t, [string]$tokens[$t]) }

    try { $null = [scriptblock]::Create($launcher) }   # syntax-check WITHOUT running
    catch { Fail 'TOOL' "Internal error: generated launcher failed to parse: $($_.Exception.Message)" }

    Set-Content -LiteralPath $launchPs1 -Value $launcher -Encoding UTF8
    $cmdBody = '@echo off' + [Environment]::NewLine + 'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0' + $distro + '-launch.ps1" %*' + [Environment]::NewLine
    Set-Content -LiteralPath $launchCmd -Value $cmdBody -Encoding ASCII
    Log "Launcher written: $launchPs1 (accel=$accel gpu=$gpuArg display=$display port=$port audio=$audioOK)"

    # ---------------------------------------------------- summary
    Write-Host ''
    Write-Host '================= VM ready =================' -ForegroundColor Green
    Write-Host " Distro      : $distro"
    Write-Host " Accelerator : $accel"
    Write-Host " GPU device  : $gpuArg"
    Write-Host " Display     : $display"
    Write-Host " Audio       : $(if ($audioOK) { 'dsound -> ICH9 HDA' } else { 'none (backend missing)' })"
    Write-Host " Disk        : $disk"
    Write-Host " Launcher    : $launchPs1  (or ${distro}-launch.cmd)"
    Write-Host " Guest ssh   : ssh -p $port <user>@localhost"
    Write-Host " Log         : $script:LogPath   (warnings: $script:Warns)"
    Write-Host '--------------------------------------------'
    Write-Host ' 1. Run with -BootInstaller to install to disk'
    Write-Host ' 2. In guest: glxinfo -B  -> renderer must be virgl, NOT llvmpipe'
    if ($isOma) { Write-Host ' 3. Hyprland mode: monitor = Virtual-1,1920x1080@144,0x0,1  (judge with a vsync test)' }
    else { Write-Host ' 3. GNOME may cap at 60 Hz; verify with a browser vsync test on the physical console' }
    Write-Host '============================================'
    Log 'Setup complete.'

    $doLaunch = $LaunchNow
    if (-not $doLaunch -and -not $Unattended) { $doLaunch = (Ask 'Launch the VM now (installer)?' 'y', 'n' 'n' 'n') -eq 'y' }
    if ($doLaunch) { & $launchPs1 -BootInstaller }
    $script:exitCode = 0
}
catch {
    $raw = $_.Exception.Message
    $kind = 'UNEXPECTED'; $msg = $raw
    if ($raw -match '^([A-Z]+)\|(.*)$') { $kind = $Matches[1]; $msg = $Matches[2] }
    switch ($kind) {
        'ABORT' { $script:exitCode = 2 }
        'ENV' { $script:exitCode = 3 }
        'INPUT' { $script:exitCode = 4 }
        'TOOL' { $script:exitCode = 5 }
        default { $script:exitCode = 1 }
    }
    Log ("EXIT {0}: [{1}] {2}" -f $script:exitCode, $kind, $msg)
    Write-Host "`n=== FAILED (exit $($script:exitCode)) ===" -ForegroundColor Red
    Write-Host $msg
    if ($script:LogPath) { Write-Host "Details: $script:LogPath" }
}
finally {
    # never leave probe VMs behind, whatever happened
    foreach ($procId in $script:ProbePids) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    # pause so double-clicked windows don't vanish before the message is read
    if ($script:exitCode -ne 0 -and -not $NoPause -and -not $Unattended -and [Environment]::UserInteractive) {
        Write-Host "`nPress Enter to close..."
        [void](Read-Host)
    }
}
exit $script:exitCode
# --- EOF: New-GpuVm.ps1 v3.2 ---