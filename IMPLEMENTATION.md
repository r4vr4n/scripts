# IMPLEMENTATION.md

## Architecture Overview

This project implements a single PowerShell script (`New-QemuVm.ps1`) that creates and launches QEMU VMs with GPU acceleration on Windows 11 using WINQ-EMU (patched QEMU + Venus Vulkan) via WHPX.

### Phase Breakdown

```
Phase 1: Core Foundation
  ├─ WHPX enablement check
  ├─ WINQ-EMU auto-install (GitHub Releases)
  ├─ OVMF download/extract (EDK2 stable)
  └─ qcow2 disk creation

Phase 2: Distro-Specific Setup
  ├─ Omarchy: ISO mount → kernel/initrd extract → pre-built rootfs download → qcow2
  └─ Ubuntu: OVMF ready for UEFI ISO install

Phase 3: QEMU Launch & Supervision
  ├─ Build argument array (flag table below)
  ├─ Emit reusable launch-VM.ps1
  ├─ Start QEMU with TCP QMP
  ├─ Launch winkey-forwarder.exe
  ├─ QMP event loop: SHUTDOWN → exit, RESET → relaunch
  └─ Memfd → file backend fallback on launch failure

Phase 4: GPU Verification
  ├─ Wait for SSH port
  └─ Print guest-side verification commands
```

### Dependency Flow

```
WHPX (Windows Feature)
    ↓
WINQ-EMU (QEMU + virglrenderer + Venus + SDL patches)
    ↓
OVMF (EDK2) ──→ Ubuntu only
    ↓
qcow2 Disk (qemu-img)
    ↓
Omarchy ISO → kernel/initrd + rootfs (Try Omarchy)
    ↓
QEMU Process (WHPX accel, virtio-vga-gl, Venus)
    ↓
TCP QMP (127.0.0.1:4444/4445)
    ↓
Supervision Loop (PowerShell)
    ↓
Guest SSH (2222/2223) → Verification
```

---

## Key Design Decisions

| Decision | Choice | Reasoning |
|----------|--------|-----------|
| **Hypervisor** | WHPX (Windows Hypervisor Platform) | Only native hypervisor on Windows 11; KVM unavailable |
| **QEMU Build** | WINQ-EMU Alpha 10+ | Only Windows build with Venus + virgl + `-cpu host` patches; stock QEMU panics on XSAVE |
| **QMP Transport** | TCP (127.0.0.1) | Simpler in PowerShell vs AF_UNIX; Try Omarchy uses Go wrapper with Unix sockets |
| **CPU Topology** | CCD pinning (4C/2T × 2 = 8 vCPU) | Ryzen 7950X = 2 CCDs × 8 cores × 2 threads; pinning avoids cross-CCD latency |
| **Memory Backend** | `memfd` → `memory-backend-file` fallback | `memfd` preferred for Venus blob mapping; WHPX may not support it |
| **Omarchy Boot** | Direct kernel (BIOS) | WINQ-EMU finding: Venus fails under EFI; BIOS boot required for performance |
| **Display Backend** | SDL + WINQ-EMU patches | Only path to 144 Hz: EDID match, DPI awareness, USB tablet fix |
| **Audio Backend** | DirectSound (`dsound`) | WINQ-EMU testing: `intel-hda` crackles under load; `dsound` stable |
| **Boot Mode** | Omarchy: BIOS direct kernel; Ubuntu: UEFI + GRUB | Omarchy Venus needs BIOS; Ubuntu installer requires UEFI |

---

## Component Reference (Function Signatures)

### Get-WinqEmuPath
```powershell
function Get-WinqEmuPath { ... }  # Returns [string] path or $null
```
- Checks `C:\WINQ-EMU\bin\qemu-system-x86_64.exe`
- Parses `-version` for `WINQ-EMU` string
- Falls back to PATH lookup

### Install-WinqEmu
```powershell
function Install-WinqEmu { ... }  # Returns [string] installed binary path
```
- Downloads portable ZIP from GitHub Releases (`cmspam/winq-emu`)
- Extracts to `C:\WINQ-EMU`
- Downloads `winkey-forwarder.exe` to `tools\`

### Get-Ovmf
```powershell
function Get-Ovmf { param($DestDir, [switch]$Secure) }  # Returns @{Code; Vars}
```
- Downloads EDK2 stable release ZIP (`edk2-stable202411`)
- Extracts `OVMF_CODE.fd` + `OVMF_VARS.fd` (or `.secboot` variants)
- Handles varying archive structures

### New-VMDisk
```powershell
function New-VMDisk { param($DiskPath, $Size) }
```
- `qemu-img create -f qcow2 -o preallocation=off`
- Respects `-ForceRecreate`

### Detect-Distro
```powershell
function Detect-Distro { param($IsoPath) }  # Returns 'Omarchy'|'Ubuntu'
```
- Regex on filename: `omarchy` / `ubuntu.*desktop.*amd64`

### Extract-OmarchyIso
```powershell
function Extract-OmarchyIso { param($IsoPath, $DestDir) }  # Returns [bool]
```
- Mounts ISO via `Mount-DiskImage`
- Copies `vmlinuz-linux`, `initramfs-linux.img`
- Downloads pre-built `rootfs.ext4.zst` from Try Omarchy releases
- Decompresses with `zstd`, converts to qcow2
- Returns `$false` if ISO structure unexpected → triggers fallback

### Build-QemuArgs
```powershell
function Build-QemuArgs { param($Distro, $VmDir, $VmName, $QmpPort, $SshPort, $Ovmf) }  # Returns [string[]]
```
- Constructs full QEMU argument array
- Full flag table with rationale (see below)

### Emit-LaunchScript
```powershell
function Emit-LaunchScript { param($VmDir, $VmName, $Distro, $QmpPort, $SshPort, $QemuArgs, $QemuBin) }
```
- Writes `launch-VM.ps1` with embedded QEMU path and args

### Invoke-Qemu
```powershell
function Invoke-Qemu { param($QemuPath, $Args, $VmDir, $VmName, $UseMemfd = $true) }  # Returns [Process] or $null
```
- Launches QEMU with stderr redirect to `qemu.log`
- Detects immediate memfd failure, returns `$null` to trigger fallback

### Connect-Qmp / Read-QmpEvent
```powershell
function Connect-Qmp { param($Host, $Port, $TimeoutMs) }  # Returns hashtable or $null
function Read-QmpEvent { param($Qmp, $TimeoutMs) }  # Returns PSObject or $null
```
- TCP connection, QMP handshake (`qmp_capabilities`)
- Async read with timeout

### Start-VMWithSupervision
```powershell
function Start-VMWithSupervision { param($QemuPath, $Args, $VmDir, $VmName, $QmpPort, $SshPort) }
```
- Launches `winkey-forwarder.exe`
- QMP event loop: `SHUTDOWN` → exit; `RESET(guest-reset)` → relaunch
- Memfd→file fallback on launch failure
- 4× retry with 3s backoff on QMP connect failure

### Test-GpuAcceleration
```powershell
function Test-GpuAcceleration { param($SshPort, $VmName) }
```
- Waits for SSH port (180s timeout)
- Prints verification commands (guest-side execution required)

---

## QEMU Flag Rationale (Complete Table)

| Flag | Value | Purpose | Source |
|------|-------|---------|--------|
| `-machine` | `q35,accel=whpx,kernel-irqchip=on` | Q35 chipset, WHPX acceleration, in-kernel irqchip | QEMU WHPX docs |
| `-cpu` | `host` | Pass host CPU features (AVX2, Zen 4) | **Requires WINQ-EMU** (upstream panics) |
| `-smp` | `8,sockets=1,cores=4,threads=2` | 8 vCPUs = 4 cores × 2 threads (1 CCD) | Ryzen 7950X topology |
| `-object cpu-map` | `id=mapX,core=Y,thread=Z` | Pin each vCPU to physical core/thread | CCD affinity |
| `-m` | `16G` | Guest RAM | User parameter |
| `-object memory-backend-memfd` | `id=mem1,size=16G,share=on` | Shared memory for Venus blob mapping | Linux/KVM pattern |
| `-machine memory-backend=mem1` | | Wire memory backend | |
| `-drive` (disk) | `file=...,if=virtio,discard=on` | VirtIO block with TRIM | |
| `-kernel/-initrd/-append` | Omarchy direct boot | BIOS boot, avoids EFI Venus regression | WINQ-EMU finding |
| `-drive` (OVMF) | `if=pflash,readonly=on` / `if=pflash` | UEFI firmware for Ubuntu | |
| `-vga none` | | Suppress default VGA (display trap) | Critical |
| `-device virtio-vga-gl` | `blob=on,hostmem=4G,venus=on` | Venus Vulkan + virgl GL | WINQ-EMU build |
| `-display sdl,gl=on,show-cursor=off` | | WINQ-EMU SDL: EDID match, no cursor conflict | |
| `-audiodev dsound` | `id=snd0` | DirectSound audio (WINQ-EMU tested) | |
| `-device virtio-sound-pci` | `audiodev=snd0` | VirtIO sound | |
| `-device virtio-keyboard-pci` | | Keyboard input | |
| `-device virtio-tablet-pci` | | Absolute pointer (no grab issues) | |
| `-device virtio-net-pci` | `netdev=net0` | Network | |
| `-netdev user` | `hostfwd=tcp::2222-:22` | User-mode + SSH forward | |
| `-device virtio-rng-pci` | | Entropy source | |
| `-serial file:` | `serial.log` | Debug log | |
| `-qmp tcp:` | `server=on,wait=off` | TCP QMP for supervision | |
| `-no-reboot` | | Prevent WHPX reboot wedge | |
| `-pidfile` | `qemu.pid` | Process tracking | |
| `-boot d` | (Ubuntu only) | Boot from CDROM first | |

---

## Omarchy ISO Strategy (Dual Path)

```
Path A (Preferred): ISO → Mount → Extract kernel/initrd → Download rootfs → qcow2
Path B (Fallback):  Download all pre-built from Try Omarchy releases
```

**Why**: Omarchy ISO is an archinstall medium, not a pre-built disk image. Direct kernel boot requires kernel/initrd + rootfs. Squashfs extraction to raw is complex without `unsquashfs` on Windows; pre-built rootfs is reliable.

**Implementation**:
1. Mount ISO, verify structure (`arch/boot/x86_64/vmlinuz-linux`, `initramfs-linux.img`, `arch/x86_64/airootfs.sfs`)
2. Copy kernel + initrd to `$VmDir/omarchy/`
3. Download `rootfs.ext4.zst` from Try Omarchy releases
4. Decompress with `zstd` → `rootfs.ext4`
5. `qemu-img convert -f raw -O qcow2 rootfs.ext4 omarchy.qcow2`
6. If any step fails → Path B: download all 4 pre-built artifacts

---

## Supervision Logic (State Machine)

```
START
  ↓
Launch QEMU (Invoke-Qemu)
  ↓
Wait 2s
  ↓
Connect QMP (30s timeout)
  ↓              ↓
Success        Fail (memfd)          Fail (connect)
  ↓                ↓                      ↓
Monitor         Switch to file        Retry (4× max)
Events          backend, rebuild      ↓
  ↓             args, restart         Kill proc, wait 3s
  ↓                ↓                      ↓
Events:        Relaunch ──────────────────┘
  ├─ SHUTDOWN → Exit 0
  └─ RESET (guest-reset) → Break → Relaunch loop
```

### QMP Event Handling

| Event | Action |
|-------|--------|
| `SHUTDOWN` | Guest `systemctl poweroff` → exit supervision cleanly |
| `RESET` (reason: `guest-reset`) | Guest `systemctl reboot` → break inner loop, outer `while($true)` relaunches |
| QMP disconnect | Retry up to 4× with 3s backoff |
| Launch failure (memfd) | Switch to `memory-backend-file`, rebuild args, retry |

---

## GPU Verification Success Criteria

| Check | Command | Pass Threshold |
|-------|---------|----------------|
| OpenGL Renderer | `glxinfo \| grep "OpenGL renderer"` | Contains `virtio-gpu` / `venus` |
| Venus ICD | `vulkaninfo \| grep -i venus` | Shows `Virtio-GPU Venus (AMD Radeon Graphics)` |
| Vulkan Perf | `vkcube --duration 10000 --fps` | **≥ 144 FPS** at native resolution |
| Refresh Rate | `hyprctl monitors` / GNOME Settings | 144 Hz mode active |

---

## Known Limitations

1. **SSH Authentication** — Script prints verification commands; user must run manually (no key injection yet)
2. **Secure Boot Enrollment** — `-SecureBoot` downloads OVMF but doesn't enroll keys in guest
3. **Omarchy Provisioning** — First-boot `gum` form requires manual interaction on tty1
4. **TAP Networking** — Only user-mode (`-netdev user`) implemented
5. **virtiofs** — Not included (WINQ-EMU may lack `virtiofsd`)
6. **Multi-monitor** — Single virtio-gpu display only
7. **CPU Pinning Validation** — Script pins to CCD but doesn't verify inside guest (use `lscpu`)
8. **Win-key Forwarder** — Bundled binary from Try Omarchy; not rebuilt from source