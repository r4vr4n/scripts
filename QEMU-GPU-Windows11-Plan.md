# QEMU GPU Acceleration on Windows 11 — Complete Plan

**Target**: 8 vCPUs, 144 Hz desktop with real GPU acceleration for Omarchy (Hyprland/Wayland) and Ubuntu 24.04.1 VMs on Windows 11 host.

**Hardware**: AMD Ryzen 7950x, 64 GB+ RAM, iGPU + dGPU.

---

## DELIVERABLE 1 — Feasibility Assessment (Blunt)

### Bottom Line

**144 Hz with real GPU acceleration IS achievable on Windows 11, but ONLY via WINQ-EMU (patched QEMU + Venus Vulkan). Stock QEMU on Windows cannot do it.**

---

### WHPX vs KVM — What You Actually Get

| Aspect | KVM (Linux Host) | WHPX (Windows 11 Host) |
| -------- | ------------------ | ------------------------ |
| **CPU Acceleration** | Near-native, `-cpu host` works fully | Upstream: `-cpu host` **panics guest** (XSAVE/XCR0 bug). WINQ-EMU patches fix this. |
| **AVX2/AVX-512 Passthrough** | Yes | Upstream: **No** (guest kernel panic at ~0.25s). WINQ-EMU: **Yes**. |
| **Interrupt Latency** | ~1-2 µs | ~5-10 µs (WHPX inner exit loop). WINQ-EMU caps at 5 ms deadline. |
| **Nested Virt Detection** | Explicit | WHPX requests `NestedVirtualization` → fails on Meteor Lake / some Zen 4 with VBS on. WINQ-EMU downgrades to warning + retries with `kernel-irqchip=off`. |
| **Your Ryzen 7000/9000** | N/A | Works well; no hybrid P/E cores to pin, but CCD topology exists. |

**Cost**: ~5-15% CPU overhead vs KVM. Acceptable for desktop workloads.

---

### virtio-gpu + virgl / Venus on Windows Host Builds

| Backend | Stock QEMU (Stefan Weil / MSYS2) | WINQ-EMU (Alpha 10+) |
| --------- | ---------------------------------- | ---------------------- |
| **2D (virtio-gpu-pci)** | Works | Works |
| **virgl (OpenGL)** | **Broken** (GitLab #2490: `virtio-vga-gl` fails with current virglrenderer) | **Works** (virglrenderer 1.3.0 + patches) |
| **Venus (Vulkan)** | **Not built** (requires custom virglrenderer + Mesa) | **Works** — `virtio-vga-gl,blob=on,hostmem=4G,venus=on` |
| **Guest Requirements** | Mesa 24.2+, Linux 6.13+ for full features | Same |
| **Your Omarchy (Hyprland/Wayland)** | Software fallback (llvmpipe) only | **Hardware accel: virgl for GL, Venus for Vulkan** |

**Critical**: Stock Windows QEMU builds **do not include** virglrenderer with Venus support. You *must* use WINQ-EMU or self-build from MSYS2 UCRT64 with the patch series.

---

### Display Backend & 144 Hz

| Backend | Vsync Control | Frame Pacing | Max Refresh on Windows Host |
| --------- | --------------- | -------------- | ---------------------------- |
| **SDL (`-display sdl,gl=on`)** | Forced ON (NVIDIA/AMD drivers ignore `SDL_GL_SetSwapInterval(0)`) | Poor — timer blocks vCPU thread | 60-75 Hz typical; WINQ-EMU patches add **dynamic EDID matching** (reads host monitor EDID, falls back to 120 Hz) |
| **GTK (`-display gtk,gl=on`)** | `vblank_mode=0` possible but race conditions (patched in QEMU 11.1+) | Similar to SDL | Same |
| **SPICE / virt-viewer** | No GPU accel path for virgl/Venus | N/A | N/A |
| **VNC** | No GPU accel | N/A | N/A |

**WINQ-EMU's SDL patches** are the only path to 120-144 Hz: they implement per-monitor DPI awareness, USB tablet fix (no freezes), and **automatic host refresh rate matching via EDID**. Without these, you're stuck at 60 Hz vsync.

---

### VFIO GPU Passthrough on Windows Host

**DOES NOT WORK. Full stop.**

- VFIO requires Linux kernel (`vfio-pci`, `vfio_iommu_type1`), IOMMU groups (VT-d/AMD-Vi), and `/dev/vfio` — none exist on Windows.
- Looking Glass requires Linux host + KVMFR kernel module or IVSHMEM + SPICE. **No Windows host support.**
- Single-GPU passthrough (unbind host driver, bind vfio) is Linux-only.
- **Alternative for "near-native" GPU on Windows host**: WINQ-EMU's Venus Vulkan forwarding (your dGPU/iGPU stays owned by Windows; VirGL/Venus translates guest GL/VK → host D3D11/Vulkan).

---

### What Omarchy's `TryOmarchy.exe` Actually Does

| Component | What It Is |
| ----------- | ------------ |
| **Hypervisor** | Windows Hypervisor Platform (WHPX) — enables via `DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All`, reboots once |
| **QEMU** | **WINQ-EMU** (bundled portable ~84 MB): QEMU 11.0 + WHPX patches (`-cpu host`, PAT MSR sync, 5 ms exit deadline, `WHvAdviseGpaRange(Pin)`) + Venus-enabled virglrenderer 1.3.0 |
| **Graphics** | `virtio-vga-gl,blob=on,hostmem=4G,venus=on` + `-display sdl,gl=on` (WINQ-EMU's patched SDL) |
| **Guest Image** | Pre-built Arch + Omarchy (Hyprland), raw ext4 rootfs on virtio-blk, direct kernel boot (no GRUB/OVMF) |
| **Fallback** | llvmpipe (CPU rendering) if GPU path fails |
| **Supervision** | Go wrapper: monitors QMP, handles reboot/poweroff wedges (WHPX bug), re-launches, manages Win-key grab scope |

**Is this a better fit for you?** YES — it *is* the reference implementation for GPU-accelerated Linux on Windows. Your manual setup should replicate its recipe exactly.

---

### If QEMU Can't Hit Target — Ranked Alternatives

| Rank | Option | GPU Accel | 144 Hz | Notes |
| ------ | -------- | ----------- | -------- | ------- |
| 1 | **WINQ-EMU (this plan)** | ✅ Venus + virgl | ✅ 120-144 Hz via EDID | Best native QEMU path |
| 2 | **WSL2 + WSLg** | ✅ d3d12 / venus | ⚠️ 60 Hz typical, Wayland compositors limited | No Hyprland; systemd/pipewire quirks |
| 3 | **Hyper-V GPU-P (RemoteFX vGPU)** | ✅ Partitioned GPU | ⚠️ 60 Hz, no Vulkan | Enterprise SKU only, complex setup |
| 4 | **VMware Workstation Pro 17+** | ✅ SVGA3D / Vulkan | ✅ 144 Hz possible | Proprietary, best Windows-host GPU story |
| 5 | **VirtualBox 7+** | ⚠️ 3D pass-through | ❌ 60 Hz cap | Fragile, no Wayland/Hyprland |
| 6 | **Bare-metal dual boot** | ✅ Native | ✅ Native | Only true 144 Hz + zero overhead |

---

## DELIVERABLE 2 — Manual Walkthrough

### Assumptions

- WINQ-EMU installed at `C:\WINQ-EMU` (auto-installed by script)
- Host: AMD Ryzen 7000/9000, 64 GB RAM, iGPU + dGPU
- Target: 8 vCPUs, 16 GiB RAM, 144 Hz
- ISOs: Omarchy (local, needs extraction), Ubuntu 24.04.1 (local)

---

### 0. Prerequisites (One-Time)

```powershell
# Enable WHPX (run as Admin, requires reboot)
dism /online /Enable-Feature /FeatureName:HypervisorPlatform /All

# If Memory Integrity (VBS/HVCI) is ON, WHPX already works — no reboot needed.
# Verify:
#   WHvGetCapability via WINQ-EMU launcher or test VM boot
```

**OVMF (UEFI firmware)** — not needed for Omarchy direct kernel boot, but **required for Ubuntu ISO install**:

- Download: `https://github.com/tianocore/edk2/releases/download/edk2-stable202411/OVMF-202411.zip` (or latest stable)
- Extract `OVMF_CODE.fd` + `OVMF_VARS.fd` to `C:\WINQ-EMU\share\qemu\` (or your VM target dir)

---

### 1. Omarchy VM (Direct Kernel Boot — No Installer)

**Why direct kernel boot?** Avoids OVMF + GRUB; WINQ-EMU's Venus works only with BIOS boot (EFI tanks Vulkan perf per WINQ-EMU findings). Omarchy provides pre-built kernel/initrd/rootfs via Try Omarchy releases.

**Disk**: Pre-built raw image (~6 GiB sparse, expands to 24 GiB). Convert to qcow2 for snapshots.

```bash
# In WINQ-EMU shell or PowerShell:
qemu-img create -f qcow2 -o preallocation=off omarchy.qcow2 32G
# Convert Omarchy raw rootfs to qcow2 (if you have raw):
qemu-img convert -f raw -O qcow2 omarchy-rootfs.raw omarchy.qcow2
```

**Launch Command (Omarchy — GPU Accelerated, 144 Hz Target)**:

```powershell
$qemu = "C:\WINQ-EMU\bin\qemu-system-x86_64.exe"
$vmdir = "C:\VMs\Omarchy"

& $qemu `
  -name "Omarchy" `
  -machine q35,accel=whpx,kernel-irqchip=on `
  -cpu host `                              # WINQ-EMU patched WHPX: passes AVX2, Zen 4 features
  -smp 8,sockets=1,cores=8,threads=1 `    # 8 vCPUs, 1 socket (no SMT on Zen 4/5)
  -m 16G `                                # 16 GiB of 64 GiB
  -object memory-backend-memfd,id=mem1,size=16G,share=on `
  -machine memory-backend=mem1 `
  -drive file="$vmdir\omarchy.qcow2",format=qcow2,if=virtio,discard=on `
  -kernel "$vmdir\omarchy\vmlinuz-linux" `
  -initrd "$vmdir\omarchy\initramfs-linux.img" `
  -append "root=/dev/vda rw quiet loglevel=3 mitigator=off" `
  -vga none `                             # CRITICAL: suppress default VGA (display trap)
  -device virtio-vga-gl,blob=on,hostmem=4G,venus=on `  # Venus Vulkan + virgl GL
  -display sdl,gl=on,show-cursor=off `    # WINQ-EMU SDL: EDID match, DPI aware, no cursor conflict
  -device virtio-sound-pci `              # virtio-sound (needs -audiodev)
  -audiodev dsound,id=snd0 `
  -device virtio-sound-pci,audiodev=snd0 `
  -device virtio-keyboard-pci `
  -device virtio-tablet-pci `             # Absolute coords, no grab issues
  -device virtio-net-pci,netdev=net0 `
  -netdev user,id=net0,hostfwd=tcp::2222-:22 `
  -device virtio-rng-pci `
  -serial file:"$vmdir\serial.log" `
  -qmp tcp:127.0.0.1:4444,server=on,wait=off `
  -no-reboot `                            # Prevents WHPX reboot wedge
  -pidfile "$vmdir\qemu.pid"
```

**Flag Explanations** (key ones):

- `-machine q35,accel=whpx,kernel-irqchip=on` — Q35 chipset, WHPX accel, in-kernel irqchip (faster). If boot fails with `hr=80370302`, retry with `kernel-irqchip=off`.
- `-cpu host` — **Requires WINQ-EMU**; upstream QEMU panics guest on XSAVE.
- `-object memory-backend-memfd,share=on` — Required for Venus blob mapping (hostmem).
- `-vga none` + `-device virtio-vga-gl` — **Avoids the "two display" trap** (virtio-vga-gl IS the VGA device).
- `-display sdl,gl=on,show-cursor=off` — WINQ-EMU SDL: `gl=on` enables EGL/VirGL context; `show-cursor=off` lets QEMU draw guest cursor (Hyprland draws it; host cursor causes double-cursor).
- `-no-reboot` — Guest `systemctl reboot` would wedge WHPX QEMU; this makes QEMU exit cleanly so supervisor can relaunch.
- `mitigator=off` kernel param — Disables Spectre/Meltdown mitigations in guest (performance).

**Guest-Side Config (Omarchy / Hyprland)**:

```lua
-- ~/.config/hypr/monitors.lua  (edit after first boot)
monitor = "eDP-1"  -- virtio-gpu names it
monitor {
    name = "eDP-1"
    preferred = true
    resolution = "2560x1440@144"  -- or your native res @ 144
    scale = 1
    cursor {
        invisible = false  -- MUST be false for SDL (WINQ-EMU finding)
    }
}
```

Run `hyprctl reload` after edit.

**First Boot**: Boots to `omarchy-provision-owner.service` (interactive `gum` form on tty1). Complete it → SDDM → Hyprland.

---

### 2. Ubuntu 24.04.1 VM (Full Install via ISO)

**Disk**: `qcow2`, 64 GiB.

```bash
qemu-img create -f qcow2 ubuntu.qcow2 64G
```

**Launch Command (Ubuntu Install — First Boot)**:

```powershell
$qemu = "C:\WINQ-EMU\bin\qemu-system-x86_64.exe"
$vmdir = "C:\VMs\Ubuntu"
$iso  = "C:\ISOs\ubuntu-24.04.1-desktop-amd64.iso"
$ovmf = "C:\WINQ-EMU\share\qemu"

& $qemu `
  -name "Ubuntu-24.04" `
  -machine q35,accel=whpx,kernel-irqchip=on `
  -cpu host `
  -smp 8,sockets=1,cores=8,threads=1 `
  -m 16G `
  -object memory-backend-memfd,id=mem1,size=16G,share=on `
  -machine memory-backend=mem1 `
  -drive file="$vmdir\ubuntu.qcow2",format=qcow2,if=virtio,discard=on `
  -drive file="$iso",format=raw,if=virtio,media=cdrom `
  -drive file="$ovmf\OVMF_CODE.fd",format=raw,if=pflash,readonly=on `
  -drive file="$vmdir\OVMF_VARS.fd",format=raw,if=pflash `
  -vga none `
  -device virtio-vga-gl,blob=on,hostmem=4G,venus=on `
  -display sdl,gl=on,show-cursor=off `
  -device virtio-sound-pci `
  -audiodev dsound,id=snd0 `
  -device virtio-sound-pci,audiodev=snd0 `
  -device virtio-keyboard-pci `
  -device virtio-tablet-pci `
  -device virtio-net-pci,netdev=net0 `
  -netdev user,id=net0,hostfwd=tcp::2223-:22 `
  -device virtio-rng-pci `
  -serial file:"$vmdir\serial.log" `
  -qmp tcp:127.0.0.1:4445,server=on,wait=off `
  -no-reboot `
  -boot d `                              # Boot from CDROM first
  -pidfile "$vmdir\qemu.pid"
```

**After Install (Second Boot)**: Remove `-drive ...media=cdrom` and `-boot d`. Keep OVMF_VARS.fd (persists NVRAM).

**Guest-Side (Ubuntu/GNOME or Hyprland if you install it)**:

```bash
# Install VirtIO GPU drivers (already in kernel), Mesa, Venus ICD
sudo apt update && sudo apt install -y mesa-vulkan-drivers vulkan-tools
# Verify:
vulkaninfo | grep -i venus
# Should show: Virtio-GPU Venus (AMD Radeon Graphics)
```

**GNOME Refresh Rate**: Settings → Displays → Refresh Rate → 144 Hz (if EDID exposes it).  
**Hyprland on Ubuntu**: Same `monitors.lua` config as Omarchy.

---

### Common: Virtio Drivers, Audio, Networking, Shared Folders

| Feature | Configuration |
| --------- | --------------- |
| **VirtIO drivers** | Built into Linux kernel (virtio-blk, virtio-net, virtio-gpu, virtio-input, virtio-rng). No ISO needed. |
| **Audio** | `-audiodev dsound,id=snd0 -device virtio-sound-pci,audiodev=snd0` (WINQ-EMU finding: dsound works; intel-hda crackles under load). |
| **Networking** | User-mode (`-netdev user`) + `hostfwd=tcp::2222-:22` for SSH. For better perf: TAP + WinTAP (advanced). |
| **Shared Folders** | WINQ-EMU includes `virtio-9p` port: `-virtfs local,path=C:\Shared,mount_tag=shared,security_model=mapped-xattr` → Guest: `mount -t 9p -o trans=virtio,version=9p2000.L shared /mnt/shared` |
| **Clipboard** | Not via SPICE (no SPICE on Windows host). Use `virtio-9p` + script or `wl-clipboard` over SSH. |

---

### Omarchy-Specific vs Ubuntu Differences

| Item | Omarchy | Ubuntu |
| ------ | --------- | -------- |
| **Boot** | Direct kernel (vmlinuz + initramfs) | OVMF + GRUB (ISO install) |
| **Compositor** | Hyprland (Wayland) — Lua config | GNOME (Wayland) or install Hyprland |
| **Cursor Fix** | `cursor { invisible = false }` in `monitors.lua` | GNOME handles automatically |
| **Vulkan ICD** | Add `vulkan-virtio` to image (missing in factory) | `apt install mesa-vulkan-drivers` |
| **Audio** | `virtio-sound-pci` (pipewire) | `virtio-sound-pci` (pipewire) |
| **Provisioning** | Interactive `gum` form on tty1 (QMP-drivable) | Standard Ubiquity installer |

---

## DELIVERABLE 3 — Interactive PowerShell Script Specification

### Script: `New-QemuVm.ps1`

**Target**: Single `.ps1` script. User provides only ISO path + VM target directory. Handles everything else.

---

### Script Parameters

```powershell
param(
    [Parameter(Mandatory, Position=0)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$IsoPath,

    [Parameter(Mandatory, Position=1)]
    [ValidateScript({Test-Path $_ -PathType Container})]
    [string]$VmDir,

    [ValidateSet('Omarchy','Ubuntu','Auto')]
    [string]$Distro = 'Auto',  # Auto-detect from ISO filename

    [int]$Vcpus = 8,
    [int]$MemoryGB = 16,
    [string]$DiskSize = '64G',
    [switch]$ForceRecreate,
    [switch]$Verbose,
    [switch]$NoGpuAccel  # Fallback to llvmpipe
)
```

---

### Script Flow (Idempotent, Safe to Re-run)

```mermaid
flowchart TD
    A[Start] --> B{Validate QEMU on PATH?}
    B -->|No| C[Download & Install WINQ-EMU]
    B -->|Yes| D[Verify WINQ-EMU version >= Alpha 10]
    C --> D
    D --> E{ISO exists?}
    E -->|No| F[Error: ISO not found]
    E -->|Yes| G[Detect Distro from ISO name]
    G --> H{VmDir has disk.qcow2?}
    H -->|Yes & !ForceRecreate| I[Error: disk exists, use -ForceRecreate]
    H -->|No or ForceRecreate| J[Create qcow2 disk]
    J --> K{OVMF present?}
    K -->|No & Ubuntu| L[Download OVMF to VmDir]
    K -->|Yes or Omarchy| M[Build qemu command line]
    M --> N[Emit launch-VM.ps1 in VmDir]
    N --> O[Run QEMU (first boot)]
    O --> P[Wait for QMP / guest ready]
    P --> Q[Print next steps]
```

---

### Key Functions

| Function | Purpose |
| ---------- | --------- |
| `Get-WinqEmuPath` | Checks `qemu-system-x86_64.exe` in PATH; parses `-version`; validates WHPX + virglrenderer + Venus support |
| `Install-WinqEmu` | Downloads latest WINQ-EMU installer from GitHub Releases, runs silent install to `C:\WINQ-EMU` |
| `Detect-Distro` | Regex on ISO filename: `omarchy.*\.iso` → Omarchy; `ubuntu.*desktop.*\.iso` → Ubuntu |
| `New-VMDisk` | `qemu-img create -f qcow2 -o preallocation=off` with size; refuses overwrite without `-ForceRecreate` |
| `Get-Ovmf` | Downloads latest EDK2 OVMF release, extracts `OVMF_CODE.fd` + `OVMF_VARS.fd` to `$VmDir` |
| `Build-QemuArgs` | Returns hashtable of splatted args per distro (see manual walkthrough) |
| `Emit-LaunchScript` | Writes `launch-VM.ps1` in `$VmDir` with full command + inline comments |
| `Start-VMWithSupervision` | Launches QEMU with `-pidfile`, monitors QMP for `SHUTDOWN`/`RESET` events, handles `-no-reboot` relaunch loop |
| `Wait-GuestReady` | Polls QMP `guest-ping` or SSH port (2222/2223) with timeout |

---

### Omarchy-Specific Handling (ISO Extraction)

Since the Omarchy ISO is an archinstall medium (not pre-extracted kernel/initrd/rootfs), the script **downloads pre-built components from Try Omarchy releases** (same as their bootstrap):

```powershell
# Download from: https://github.com/omacom/try-omarchy-windows/releases/download/v0.0.3-preview/
# Files: vmlinuz-linux, initramfs-linux.img, build-spec.json, rootfs.ext4.zst
# Decompress rootfs.ext4.zst with zstd (winget install Meta.Zstandard)
# Convert rootfs.ext4 → qcow2 via qemu-img convert
```

---

### Error Handling & UX

```powershell
try {
    # All operations in try/catch
    # Validate paths: Test-Path, [IO.Directory]::GetAccessControl()
    # Detect host cores: (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
    # Warn if $Vcpus > $hostCores * 0.75
    # Detect RAM: (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    # Warn if $MemoryGB > $totalGB * 0.75
    # Detect accelerator: qemu-system-x86_64.exe -accel help | Select-String whpx
} catch {
    Write-Error $_
    exit 1
}
```

- **`-Verbose`**: Emits each QEMU flag with explanation (via `Write-Verbose`).
- **Comment-based help**: Full `<# .SYNOPSIS ... #>` block with examples.
- **Idempotency**: `New-VMDisk` checks existence; `Get-Ovmf` checks checksum; `Emit-LaunchScript` overwrites only the launch script (never the disk).

---

### Auto-Detection Logic

```powershell
function Detect-Distro {
    param($IsoPath)
    $name = [IO.Path]::GetFileName($IsoPath).ToLower()
    if ($name -match 'omarchy') { return 'Omarchy' }
    if ($name -match 'ubuntu.*desktop') { return 'Ubuntu' }
    throw "Cannot auto-detect distro from filename: $name. Use -Distro Omarchy|Ubuntu"
}
```

---

### Emitted `launch-VM.ps1` (Reusable)

```powershell
<#
.SYNOPSIS
    Re-launch the VM without re-running setup.
.DESCRIPTION
    Generated by New-QemuVm.ps1 on $(Get-Date).
    Run from $VmDir to boot the existing disk.
#>
param([switch]$NoGpuAccel, [switch]$Fullscreen, [switch]$Fresh)
$qemu = "C:\WINQ-EMU\bin\qemu-system-x86_64.exe"
# ... full command line from Build-QemuArgs ...
& $qemu @qemuArgs
```

---

### Dependencies (Script Installs If Missing)

| Tool | Source | Check |
| ------ | -------- | ------- |
| **WINQ-EMU** | GitHub Releases (`cmspam/winq-emu`) | `qemu-system-x86_64.exe -version` contains `WINQ-EMU` |
| **qemu-img** | Bundled with WINQ-EMU | Same PATH |
| **OVMF** | GitHub `tianocore/edk2` releases | `$VmDir\OVMF_CODE.fd` exists |
| **zstd** | winget `Meta.Zstandard` | For Omarchy rootfs.zst decompression |
| **7-Zip / Expand-Archive** | Built-in | For OVMF zip extraction |

---

### Validation Checklist (Script Enforces)

- [ ] QEMU on PATH, version ≥ WINQ-EMU Alpha 10 (QEMU 11.0 base)
- [ ] ISO file exists, readable
- [ ] `$VmDir` exists, writable, not a file
- [ ] No existing `disk.qcow2` unless `-ForceRecreate`
- [ ] Host has ≥ 16 logical cores (for 8 vCPUs + headroom)
- [ ] Host has ≥ 32 GB RAM (for 16 GB VM + host)
- [ ] WHPX capability: `WHvGetCapability` succeeds (via test VM or WINQ-EMU probe)
- [ ] AMD GPU detected (for Venus on RADV/AMDVLK)

---

### Example Invocation

```powershell
# Omarchy (downloads pre-built components from Try Omarchy releases)
.\New-QemuVm.ps1 -IsoPath "C:\ISOs\omarchy-3.0.iso" -VmDir "C:\VMs\Omarchy" -Distro Omarchy -Verbose

# Ubuntu 24.04.1
.\New-QemuVm.ps1 -IsoPath "C:\ISOs\ubuntu-24.04.1-desktop-amd64.iso" -VmDir "C:\VMs\Ubuntu" -Verbose
```

---

### What the Script Does NOT Do (By Design)

- ❌ Modify Windows features (WHPX enable) — requires Admin + reboot; user must do once (script exits 0 with message if reboot needed)
- ❌ Install GPU drivers on host — assumed present
- ❌ Configure guest OS post-install (Hyprland refresh rate, `vulkan-virtio` package) — documented in manual walkthrough
- ❌ Manage SSH keys / user accounts — guest-side

---

## Streaming Output Design (User Visibility)

| Stream | Content |
| -------- | --------- |
| `Write-Progress` | Phase: WHPX → WINQ-EMU → OVMF → Disk → Boot |
| `Write-Verbose` | Per-flag explanations (only with `-Verbose`) |
| `Write-Host` | QEMU stderr (tee), QMP events, milestones |
| `Write-Warning` | CPU/RAM warnings, fallback to CPU rendering |

---

## QMP Transport (Mirroring Omarchy's Proven Pattern)

- **Windows AF_UNIX sockets** at `%LOCALAPPDATA%\<VmName>IPC\*.sock`
- Three sockets: `supervisor.sock` (lifecycle), `tools.sock` (provisioning), `forward.sock` (winkey forwarder)
- **Launch watchdog**: Connect to supervisor QMP within 30s, retry 4× on wedge
- **Async SHUTDOWN read**: Keeps `ReadLineAsync()` permanently pending to catch `SHUTDOWN` event before socket close discards it
- **Guest reboot**: Detects `guest-reset` reason → relaunches VM automatically
- **Guest poweroff**: Exits script cleanly

---

## File Layout After Run

```
$VmDir\
├── omarchy.qcow2 / ubuntu.qcow2
├── OVMF_CODE.fd / OVMF_VARS.fd          # Ubuntu only
├── omarchy/                               # Omarchy only
│   ├── vmlinuz-linux
│   ├── initramfs-linux.img
│   └── build-spec.json
├── launch-VM.ps1                          # Reusable launcher
├── serial.log / serial-gpu.log
├── qemu.log
├── qemu.pid
├── supervisor.sock / tools.sock / forward.sock  # QMP sockets (AF_UNIX)
```

---

## Next Steps

1. **Review this plan** — confirm all assumptions
2. **Implement `New-QemuVm.ps1`** — single comprehensive script
3. **Test on your hardware** — run for Ubuntu first (full ISO install validates GPU path), then Omarchy

---

## Sources & References

- QEMU WHPX docs: <https://www.qemu.org/docs/master/system/whpx.html>
- QEMU virtio-gpu docs: <https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html>
- WINQ-EMU: <https://github.com/cmspam/winq-emu> / <https://cmspam.github.io/winq-emu>
- Try Omarchy Windows: <https://github.com/omacom/try-omarchy-windows> (esp. `docs/FINDINGS.md`)
- virglrenderer Venus: <https://docs.mesa3d.org/drivers/venus.html>
- EDK2 OVMF: <https://github.com/tianocore/edk2/releases>
