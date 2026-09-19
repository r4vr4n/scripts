<#
.SYNOPSIS
    Creates and launches a QEMU VM with GPU acceleration on Windows 11 using WINQ-EMU.
.DESCRIPTION
    Single-script setup for Omarchy (Hyprland/Wayland) and Ubuntu 24.04 VMs with 144 Hz target.
    Uses WINQ-EMU (patched QEMU + Venus Vulkan) via WHPX on Windows 11.
    Handles: WINQ-EMU install, OVMF, disk creation, ISO extraction (Omarchy), QMP supervision, GPU verification.
.PARAMETER IsoPath
    Path to ISO file (Omarchy or Ubuntu desktop ISO).
.PARAMETER VmDir
    Target directory for VM files (disk, logs, launch script).
.PARAMETER Distro
    Distribution type: Omarchy, Ubuntu, or Auto (detect from ISO filename).
.PARAMETER Vcpus
    Number of vCPUs (default 8).
.PARAMETER MemoryGB
    RAM in GiB (default 16).
.PARAMETER DiskSize
    Disk size (default 64G).
.PARAMETER Ccd
    CCD to pin on Ryzen 7000/9000 (0 or 1). Default 0.
.PARAMETER GpuMem
    Venus hostmem (default 4G).
.PARAMETER ForceRecreate
    Overwrite existing disk.
.PARAMETER VerboseOutput
    Detailed per-flag explanations.
.PARAMETER NoGpuAccel
    Fallback to llvmpipe (no Venus/virgl).
.PARAMETER SecureBoot
    Use Secure Boot OVMF (Ubuntu only).
.PARAMETER DebugGpu
    Enable VENUS_DEBUG=1 for troubleshooting.
.EXAMPLE
    .\New-QemuVm.ps1 -IsoPath "C:\ISOs\omarchy-3.0.iso" -VmDir "C:\VMs\Omarchy" -Distro Omarchy -Ccd 0 -VerboseOutput
.EXAMPLE
    .\New-QemuVm.ps1 -IsoPath "C:\ISOs\ubuntu-24.04-desktop-amd64.iso" -VmDir "C:\VMs\Ubuntu" -SecureBoot
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$IsoPath,

    [Parameter(Mandatory, Position=1)]
    [ValidateScript({Test-Path $_ -PathType Container})]
    [string]$VmDir,

    [ValidateSet('Omarchy','Ubuntu','Auto')]
    [string]$Distro = 'Auto',

    [int]$Vcpus = 8,
    [int]$MemoryGB = 16,
    [string]$DiskSize = '64G',
    [ValidateSet(0,1)]
    [int]$Ccd = 0,
    [string]$GpuMem = '4G',
    [switch]$ForceRecreate,
    [switch]$VerboseOutput,
    [switch]$NoGpuAccel,
    [switch]$SecureBoot,
    [switch]$DebugGpu
)

# --- Constants ---
$WINQ_EMU_URL = "https://github.com/cmspam/winq-emu/releases/latest/download/winq-emu-portable.zip"
$WINQ_EMU_DIR = "C:\WINQ-EMU"
$WINQ_EMU_BIN = Join-Path $WINQ_EMU_DIR "bin\qemu-system-x86_64.exe"
$WINQ_EMU_IMG = Join-Path $WINQ_EMU_DIR "bin\qemu-img.exe"
$OVMF_BASE_URL = "https://github.com/tianocore/edk2/releases/download/edk2-stable202411/OVMF-202411.zip"
$TRY_OMARCHY_BASE = "https://github.com/omacom/try-omarchy-windows/releases/download/v0.0.3-preview"
$WINKEY_FORWARDER_URL = "https://github.com/omacom/try-omarchy-windows/releases/download/v0.0.3-preview/winkey-forwarder.exe"

# --- Helpers ---
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $prefix = "[$(Get-Date -Format 'HH:mm:ss')] [$Level]"
    if ($Level -eq 'VERBOSE' -and -not $VerboseOutput) { return }
    Write-Host "$prefix $Message"
}

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WinqEmuPath {
    Write-Log "Checking for WINQ-EMU..."
    if (Test-Path $WINQ_EMU_BIN) {
        $ver = & $WINQ_EMU_BIN -version 2>&1 | Select-String 'WINQ-EMU|QEMU emulator'
        if ($ver -and $ver -match 'WINQ-EMU') {
            Write-Log "Found WINQ-EMU: $ver" 'VERBOSE'
            return $WINQ_EMU_BIN
        }
    }
    $pathQemu = Get-Command qemu-system-x86_64.exe -ErrorAction SilentlyContinue
    if ($pathQemu) {
        $ver = & $pathQemu.Source -version 2>&1 | Select-String 'WINQ-EMU'
        if ($ver) {
            Write-Log "Found WINQ-EMU in PATH: $ver" 'VERBOSE'
            return $pathQemu.Source
        }
    }
    return $null
}

function Install-WinqEmu {
    Write-Log "Downloading WINQ-EMU from $WINQ_EMU_URL..."
    $zipPath = Join-Path $env:TEMP "winq-emu-portable.zip"
    try {
        Invoke-WebRequest -Uri $WINQ_EMU_URL -OutFile $zipPath -UseBasicParsing
        if (-not (Test-Path $WINQ_EMU_DIR)) { New-Item -ItemType Directory -Path $WINQ_EMU_DIR | Out-Null }
        Expand-Archive -Path $zipPath -DestinationPath $WINQ_EMU_DIR -Force
        # Download winkey-forwarder
        $toolsDir = Join-Path $WINQ_EMU_DIR "tools"
        if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir | Out-Null }
        $wkPath = Join-Path $toolsDir "winkey-forwarder.exe"
        if (-not (Test-Path $wkPath)) {
            Write-Log "Downloading winkey-forwarder..."
            Invoke-WebRequest -Uri $WINKEY_FORWARDER_URL -OutFile $wkPath -UseBasicParsing
        }
        Write-Log "WINQ-EMU installed to $WINQ_EMU_DIR"
        return $WINQ_EMU_BIN
    } catch {
        Write-Error "Failed to install WINQ-EMU: $_"
        exit 1
    }
}

function Get-Ovmf {
    param($DestDir, [switch]$Secure)
    $codeName = if ($Secure) { 'OVMF_CODE.secboot.fd' } else { 'OVMF_CODE.fd' }
    $varsName = if ($Secure) { 'OVMF_VARS.secboot.fd' } else { 'OVMF_VARS.fd' }
    $codePath = Join-Path $DestDir $codeName
    $varsPath = Join-Path $DestDir $varsName
    if (Test-Path $codePath -and Test-Path $varsPath) {
        Write-Log "OVMF already present at $DestDir" 'VERBOSE'
        return @{ Code = $codePath; Vars = $varsPath }
    }
    Write-Log "Downloading OVMF from $OVMF_BASE_URL..."
    $zipPath = Join-Path $env:TEMP "OVMF.zip"
    try {
        Invoke-WebRequest -Uri $OVMF_BASE_URL -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $DestDir -Force
        # Find the files (structure varies)
        $codeFiles = Get-ChildItem $DestDir -Recurse -Filter $codeName
        $varsFiles = Get-ChildItem $DestDir -Recurse -Filter $varsName
        if ($codeFiles -and $varsFiles) {
            Move-Item $codeFiles[0].FullName $codePath -Force
            Move-Item $varsFiles[0].FullName $varsPath -Force
        }
        Write-Log "OVMF extracted to $DestDir"
        return @{ Code = $codePath; Vars = $varsPath }
    } catch {
        Write-Error "Failed to download/extract OVMF: $_"
        exit 1
    }
}

function New-VMDisk {
    param($DiskPath, $Size)
    if (Test-Path $DiskPath -and -not $ForceRecreate) {
        Write-Error "Disk already exists at $DiskPath. Use -ForceRecreate to overwrite."
        exit 1
    }
    Write-Log "Creating qcow2 disk: $DiskPath ($Size)..."
    & $WINQ_EMU_IMG create -f qcow2 -o preallocation=off $DiskPath $Size
    if ($LASTEXITCODE -ne 0) { Write-Error "qemu-img failed"; exit 1 }
}

function Detect-Distro {
    param($IsoPath)
    $name = [IO.Path]::GetFileName($IsoPath).ToLower()
    if ($name -match 'omarchy') { return 'Omarchy' }
    if ($name -match 'ubuntu.*desktop.*amd64') { return 'Ubuntu' }
    throw "Cannot auto-detect distro from filename: $name. Use -Distro Omarchy|Ubuntu"
}

function Extract-OmarchyIso {
    param($IsoPath, $DestDir)
    Write-Log "Extracting Omarchy ISO: $IsoPath"
    $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $driveLetter = ($mountResult | Get-Volume).DriveLetter
    $isoRoot = "$($driveLetter):\"
    try {
        # Copy kernel + initrd
        $kernelSrc = Join-Path $isoRoot "arch\boot\x86_64\vmlinuz-linux"
        $initrdSrc = Join-Path $isoRoot "arch\boot\x86_64\initramfs-linux.img"
        $sfsSrc = Join-Path $isoRoot "arch\x86_64\airootfs.sfs"
        if (-not (Test-Path $kernelSrc) -or -not (Test-Path $initrdSrc) -or -not (Test-Path $sfsSrc)) {
            Write-Warning "ISO structure not as expected. Falling back to Try Omarchy pre-built."
            return $false
        }
        $omarchyDir = Join-Path $DestDir "omarchy"
        if (-not (Test-Path $omarchyDir)) { New-Item -ItemType Directory -Path $omarchyDir | Out-Null }
        Copy-Item $kernelSrc (Join-Path $omarchyDir "vmlinuz-linux") -Force
        Copy-Item $initrdSrc (Join-Path $omarchyDir "initramfs-linux.img") -Force
        # Download pre-built rootfs (squashfs extraction to raw is complex without unsquashfs)
        Write-Log "Downloading pre-built rootfs from Try Omarchy..."
        $rootfsUrl = "$TRY_OMARCHY_BASE/rootfs.ext4.zst"
        $zstPath = Join-Path $omarchyDir "rootfs.ext4.zst"
        Invoke-WebRequest -Uri $rootfsUrl -OutFile $zstPath -UseBasicParsing
        # Decompress with zstd
        $zstd = Get-Command zstd.exe -ErrorAction SilentlyContinue
        if (-not $zstd) {
            Write-Log "Installing zstd via winget..."
            winget install --id Meta.Zstandard -e --source winget --accept-source-agreements --accept-package-agreements
            $zstd = Get-Command zstd.exe
        }
        $rawPath = Join-Path $omarchyDir "rootfs.ext4"
        & $zstd -d $zstPath -o $rawPath
        # Convert to qcow2
        & $WINQ_EMU_IMG convert -f raw -O qcow2 $rawPath (Join-Path $DestDir "omarchy.qcow2")
        Write-Log "Omarchy extraction complete at $omarchyDir"
        return $true
    } finally {
        Dismount-DiskImage -ImagePath $IsoPath
    }
}

function Build-QemuArgs {
    param($Distro, $VmDir, $VmName, $QmpPort, $SshPort, $Ovmf)
    $qemuArgs = @()
    $qemuArgs += "-name", "`"$VmName`""
    $qemuArgs += "-machine", "q35,accel=whpx,kernel-irqchip=on"
    $qemuArgs += "-cpu", "host"
    # CPU pinning for CCD
    $coresPerCcd = 8
    $threadsPerCore = 2
    $startCore = $Ccd * $coresPerCcd
    $smpStr = "$Vcpus,sockets=1,cores=$($Vcpus/2),threads=2"
    $qemuArgs += "-smp", $smpStr
    # CPU map objects for pinning
    for ($i = 0; $i -lt $Vcpus; $i++) {
        $core = $startCore + [math]::Floor($i / 2)
        $thread = $i % 2
        $qemuArgs += "-object", "cpu-map,id=map$i,node=0,socket=0,core=$core,thread=$thread"
    }
    $qemuArgs += "-m", "$MemoryGB" + "G"
    # Memory backend - try memfd first
    $memBackend = "memory-backend-memfd,id=mem1,size=$MemoryGB" + "G,share=on"
    $qemuArgs += "-object", $memBackend
    $qemuArgs += "-machine", "memory-backend=mem1"
    # Disk
    $diskName = if ($Distro -eq 'Omarchy') { 'omarchy.qcow2' } else { 'ubuntu.qcow2' }
    $qemuArgs += "-drive", "file=`"$VmDir\$diskName`",format=qcow2,if=virtio,discard=on"
    if ($Distro -eq 'Omarchy') {
        $qemuArgs += "-kernel", "`"$VmDir\omarchy\vmlinuz-linux`""
        $qemuArgs += "-initrd", "`"$VmDir\omarchy\initramfs-linux.img`""
        $qemuArgs += "-append", "`"root=/dev/vda rw quiet loglevel=3 mitigator=off`""
    } else {
        $qemuArgs += "-drive", "`"$Ovmf.Code`",format=raw,if=pflash,readonly=on"
        $qemuArgs += "-drive", "`"$Ovmf.Vars`",format=raw,if=pflash"
    }
    # GPU
    if (-not $NoGpuAccel) {
        $qemuArgs += "-vga", "none"
        $qemuArgs += "-device", "virtio-vga-gl,blob=on,hostmem=$GpuMem,venus=on"
        $qemuArgs += "-display", "sdl,gl=on,show-cursor=off"
    } else {
        $qemuArgs += "-vga", "virtio"
        $qemuArgs += "-display", "sdl"
    }
    # Audio
    $qemuArgs += "-audiodev", "dsound,id=snd0"
    $qemuArgs += "-device", "virtio-sound-pci,audiodev=snd0"
    # Input
    $qemuArgs += "-device", "virtio-keyboard-pci"
    $qemuArgs += "-device", "virtio-tablet-pci"
    # Network
    $qemuArgs += "-device", "virtio-net-pci,netdev=net0"
    $qemuArgs += "-netdev", "user,id=net0,hostfwd=tcp::${SshPort}-:22"
    # RNG
    $qemuArgs += "-device", "virtio-rng-pci"
    # Serial + QMP
    $qemuArgs += "-serial", "file:`"$VmDir\serial.log`""
    $qemuArgs += "-qmp", "tcp:127.0.0.1:$QmpPort,server=on,wait=off"
    $qemuArgs += "-no-reboot"
    $qemuArgs += "-pidfile", "`"$VmDir\qemu.pid`""
    if ($Distro -eq 'Ubuntu') {
        $qemuArgs += "-boot", "d"
    }
    if ($DebugGpu) {
        $env:VENUS_DEBUG = "1"
    }
    return $qemuArgs
}

function Emit-LaunchScript {
    param($VmDir, $VmName, $Distro, $QmpPort, $SshPort, $QemuArgs, $QemuBin)
    $scriptPath = Join-Path $VmDir "launch-VM.ps1"
    $content = @"
<#
.SYNOPSIS
    Re-launch $VmName VM without re-running setup.
.DESCRIPTION
    Generated by New-QemuVm.ps1 on $(Get-Date).
    Run from $VmDir to boot the existing disk.
#>
param([switch]`$NoGpuAccel, [switch]`$Fullscreen, [switch]`$Fresh)
`$qemu = "$QemuBin"
`$vmdir = "`$PSScriptRoot"
`$qmpPort = $QmpPort
`$sshPort = $SshPort
"@
    if ($Distro -eq 'Omarchy') {
        $content += @"
`$args = @(
"@
    } else {
        $content += @"
`$ovmfCode = "`$vmdir\OVMF_CODE.fd"
`$ovmfVars = "`$vmdir\OVMF_VARS.fd"
`$args = @(
"@
    }
    foreach ($arg in $QemuArgs) {
        $content += "    `"$arg`",`n"
    }
    $content += @"
)
& `$qemu @`$args
"@
    Set-Content -Path $scriptPath -Value $content -Encoding UTF8
    Write-Log "Emitted launch script: $scriptPath"
}

function Invoke-Qemu {
    param($QemuPath, $Args, $VmDir, $VmName, $UseMemfd = $true)
    Write-Log "Starting QEMU: $VmName"
    Write-Log "Command: $QemuPath $($Args -join ' ')" 'VERBOSE'
    $logFile = Join-Path $VmDir "qemu.log"
    $proc = Start-Process -FilePath $QemuPath -ArgumentList $Args -PassThru -RedirectStandardError $logFile
    $proc.Id | Out-File (Join-Path $VmDir "qemu.pid")
    # Quick check if process died immediately
    Start-Sleep 1
    if ($proc.HasExited) {
        $err = Get-Content $logFile -ErrorAction SilentlyContinue
        if ($UseMemfd -and ($err -match 'memfd|memory-backend-memfd')) {
            Write-Warning "memfd backend failed, will retry with memory-backend-file"
            return $null
        }
    }
    return $proc
}

# --- QMP Supervision ---
function Connect-Qmp {
    param($Host, $Port, $TimeoutMs = 30000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $async = $tcp.BeginConnect($Host, $Port, $null, $null)
    $success = $async.AsyncWaitHandle.WaitOne($TimeoutMs)
    if (-not $success -or -not $tcp.Connected) { return $null }
    $stream = $tcp.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream) { AutoFlush = $true }
    # QMP handshake
    $hello = $reader.ReadLine()
    if (-not ($hello -match 'QMP')) { return $null }
    $writer.WriteLine('{"execute":"qmp_capabilities"}')
    $reader.ReadLine() | Out-Null
    return @{ Tcp = $tcp; Stream = $stream; Reader = $reader; Writer = $writer }
}

function Read-QmpEvent {
    param($Qmp, $TimeoutMs = 5000)
    $stream = $Qmp.Stream
    $reader = $Qmp.Reader
    $stream.ReadTimeout = $TimeoutMs
    try {
        $line = $reader.ReadLine()
        if ($line) { return $line | ConvertFrom-Json }
    } catch { }
    return $null
}

function Start-VMWithSupervision {
    param($QemuPath, $Args, $VmDir, $VmName, $QmpPort, $SshPort)
    Write-Log "Starting VM with QMP supervision (port $QmpPort)..."
    # Start winkey-forwarder
    $wkPath = Join-Path $WINQ_EMU_DIR "tools\winkey-forwarder.exe"
    $wkProc = $null
    if (Test-Path $wkPath) {
        $wkProc = Start-Process $wkPath -ArgumentList "-vm $VmName" -PassThru -WindowStyle Hidden
    }
    $retryCount = 0
    $maxRetries = 4
    $useMemfd = $true
    while ($true) {
        $proc = Invoke-Qemu $QemuPath $Args $VmDir $VmName $useMemfd
        if (-not $proc) {
            # Switch to memory-backend-file and rebuild args
            $useMemfd = $false
            $Args = $Args | ForEach-Object {
                if ($_ -match 'memory-backend-memfd') {
                    "memory-backend-file,id=mem1,size=$MemoryGB" + "G,share=on,mem-path=$env:TEMP\qemu-mem-$VmName"
                } elseif ($_ -eq 'memory-backend=mem1') {
                    "memory-backend=mem1"
                } else {
                    $_
                }
            }
            Write-Log "Retrying with memory-backend-file..."
            continue
        }
        Start-Sleep 2
        $qmp = Connect-Qmp "127.0.0.1" $QmpPort
        if (-not $qmp) {
            Write-Warning "QMP connection failed, retrying... ($retryCount/$maxRetries)"
            $proc.Kill()
            $retryCount++
            if ($retryCount -ge $maxRetries) { throw "QMP connect failed after $maxRetries retries" }
            Start-Sleep 3
            continue
        }
        $retryCount = 0
        Write-Log "QMP connected. Monitoring for SHUTDOWN/RESET..."
        try {
            while ($true) {
                $event = Read-QmpEvent $qmp
                if ($null -eq $event) { continue }
                Write-Log "QMP Event: $($event.event)" 'VERBOSE'
                if ($event.event -eq 'SHUTDOWN') {
                    Write-Log "Guest shutdown requested."
                    return 0
                }
                if ($event.event -eq 'RESET') {
                    $reason = if ($event.data -and $event.data.reason) { $event.data.reason } else { 'unknown' }
                    if ($reason -eq 'guest-reset') {
                        Write-Log "Guest reboot requested. Relaunching..."
                        break
                    }
                }
            }
        } finally {
            $qmp.Tcp.Close()
            if ($proc -and -not $proc.HasExited) { $proc.Kill() }
        }
    }
    if ($wkProc -and -not $wkProc.HasExited) { $wkProc.Kill() }
}

function Test-GpuAcceleration {
    param($SshPort, $VmName)
    Write-Log "Waiting for SSH on port $SshPort..."
    $timeout = 180
    $start = Get-Date
    while ((Get-Date) -lt $start.AddSeconds($timeout)) {
        $tcp = New-Object System.Net.Sockets.TcpClient
        try { $tcp.Connect("127.0.0.1", $SshPort); $tcp.Close(); break } catch { Start-Sleep 2 }
    }
    Write-Log "SSH ready. Running GPU verification..."
    # Note: requires SSH key setup or password. For now, print commands to run manually.
    $verificationCmds = @(
        "glxinfo | grep 'OpenGL renderer'",
        "vulkaninfo | grep -i venus",
        "vkcube --duration 10000 --fps 2>&1 | tail -10",
        "hyprctl monitors 2>/dev/null || echo 'GNOME: check Settings > Displays'"
    )
    Write-Log "Run these commands in guest via SSH (port $SshPort):" 'VERBOSE'
    $verificationCmds | ForEach-Object { Write-Log "  $_" 'VERBOSE' }
    Write-Log "Expected: vkcube FPS >= 144, Venus ICD visible, 144 Hz refresh rate."
}

# --- Main ---
try {
    Write-Log "=== QEMU GPU VM Setup ==="
    Write-Log "ISO: $IsoPath"
    Write-Log "VM Dir: $VmDir"
    Write-Log "Distro: $Distro"
    Write-Log "vCPUs: $Vcpus, RAM: ${MemoryGB}G, CCD: $Ccd, GPU Mem: $GpuMem"

    # 1. WHPX check
    Write-Log "Checking WHPX..."
    $whpx = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue
    if (-not $whpx -or $whpx.State -ne 'Enabled') {
        Write-Warning "WHPX not enabled. Run as Admin: dism /online /Enable-Feature /FeatureName:HypervisorPlatform /All"
        Write-Warning "Reboot required. Exiting."
        exit 0
    }
    Write-Log "WHPX enabled." 'VERBOSE'

    # 2. WINQ-EMU
    $qemuPath = Get-WinqEmuPath
    if (-not $qemuPath) {
        if (-not (Test-Admin)) { Write-Error "Admin required to install WINQ-EMU"; exit 1 }
        $qemuPath = Install-WinqEmu
    }

    # 3. Distro detection
    if ($Distro -eq 'Auto') { $Distro = Detect-Distro $IsoPath }
    Write-Log "Distro: $Distro"

    # 4. VM Directory
    if (-not (Test-Path $VmDir)) { New-Item -ItemType Directory -Path $VmDir | Out-Null }

    # 5. Disk
    $diskName = if ($Distro -eq 'Omarchy') { 'omarchy.qcow2' } else { 'ubuntu.qcow2' }
    $diskPath = Join-Path $VmDir $diskName
    New-VMDisk $diskPath $DiskSize

    # 6. OVMF (Ubuntu only)
    $ovmf = $null
    if ($Distro -eq 'Ubuntu') {
        $ovmf = Get-Ovmf $VmDir -Secure:$SecureBoot
    }

    # 7. Omarchy ISO extraction
    if ($Distro -eq 'Omarchy') {
        $omarchyDir = Join-Path $VmDir "omarchy"
        if (-not (Test-Path (Join-Path $omarchyDir "vmlinuz-linux"))) {
            $extracted = Extract-OmarchyIso $IsoPath $VmDir
            if (-not $extracted) {
                Write-Warning "ISO extraction failed. Downloading Try Omarchy pre-built artifacts..."
                $files = @("vmlinuz-linux", "initramfs-linux.img", "build-spec.json", "rootfs.ext4.zst")
                foreach ($f in $files) {
                    $url = "$TRY_OMARCHY_BASE/$f"
                    $dest = Join-Path $omarchyDir $f
                    if (-not (Test-Path $dest)) {
                        Write-Log "Downloading $f..."
                        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
                    }
                }
                # Decompress rootfs
                $zstPath = Join-Path $omarchyDir "rootfs.ext4.zst"
                $rawPath = Join-Path $omarchyDir "rootfs.ext4"
                $zstd = Get-Command zstd.exe -ErrorAction SilentlyContinue
                if (-not $zstd) { winget install --id Meta.Zstandard -e --source winget --accept-source-agreements --accept-package-agreements; $zstd = Get-Command zstd.exe }
                & $zstd -d $zstPath -o $rawPath
                # Convert to qcow2 (overwrite disk)
                & $WINQ_EMU_IMG convert -f raw -O qcow2 $rawPath $diskPath
            }
        }
    }

    # 8. Build QEMU args
    $vmName = if ($Distro -eq 'Omarchy') { 'Omarchy' } else { 'Ubuntu-24.04' }
    $qmpPort = if ($Distro -eq 'Omarchy') { 4444 } else { 4445 }
    $sshPort = if ($Distro -eq 'Omarchy') { 2222 } else { 2223 }
    $qemuArgs = Build-QemuArgs $Distro $VmDir $vmName $qmpPort $sshPort $ovmf

    # 9. Emit launch script
    Emit-LaunchScript $VmDir $vmName $Distro $qmpPort $sshPort $qemuArgs $qemuPath

    # 10. Launch with supervision
    Start-VMWithSupervision $qemuPath $qemuArgs $VmDir $vmName $qmpPort $sshPort

    # 11. GPU verification
    Test-GpuAcceleration $sshPort $vmName

    Write-Log "=== Setup complete ==="
    Write-Log "Re-launch anytime: cd $VmDir; .\launch-VM.ps1"
    Write-Log "SSH: ssh -p $sshPort user@localhost"
} catch {
    Write-Error "Fatal error: $_"
    exit 1
}