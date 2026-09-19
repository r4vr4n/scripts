# USAGE.md

## Prerequisites

### One-Time Setup (Run as Administrator)
```powershell
# Enable Windows Hypervisor Platform (WHPX)
dism /online /Enable-Feature /FeatureName:HypervisorPlatform /All
# Reboot if prompted
```

### Hardware Requirements
- AMD Ryzen 7000/9000 series (tested on 7950X)
- 64 GB+ RAM (16 GB per VM + headroom)
- dGPU + iGPU (dGPU used for Venus via RADV)
- 144 Hz monitor (EDID read by WINQ-EMU SDL)

### ISO Files
Place in `C:\ISOs\`:
- Omarchy: `omarchy-*.iso` (latest from omarchy.org)
- Ubuntu: `ubuntu-24.04-desktop-amd64.iso` (generic, always latest point release)

---

## Quick Start

### Omarchy (Hyprland/Wayland)
```powershell
# First run (extracts ISO, downloads rootfs, launches VM)
.\New-QemuVm.ps1 -IsoPath "C:\ISOs\omarchy-3.0.iso" -VmDir "C:\VMs\Omarchy" -Distro Omarchy -Ccd 0 -VerboseOutput

# Subsequent launches
cd C:\VMs\Omarchy
.\launch-VM.ps1
```

### Ubuntu 24.04 (GNOME or Hyprland)
```powershell
# First run (installs via ISO, uses OVMF)
.\New-QemuVm.ps1 -IsoPath "C:\ISOs\ubuntu-24.04-desktop-amd64.iso" -VmDir "C:\VMs\Ubuntu" -SecureBoot

# After install completes, re-launch (removes -boot d automatically)
cd C:\VMs\Ubuntu
.\launch-VM.ps1
```

---

## Common Scenarios

### Change CCD Pinning (Ryzen 7950X = 2 CCDs)
```powershell
# CCD0 (cores 0-7) - default
.\New-QemuVm.ps1 ... -Ccd 0

# CCD1 (cores 8-15) - try if CCD0 has thermal/throttling issues
.\New-QemuVm.ps1 ... -Ccd 1
```

### Increase Venus VRAM (for higher resolution / more VRAM-heavy apps)
```powershell
.\New-QemuVm.ps1 ... -GpuMem 6G  # Default 4G
```

### Debug GPU Issues
```powershell
# Enable Venus debug logging
.\New-QemuVm.ps1 ... -DebugGpu

# Check QEMU log for Venus errors
Get-Content C:\VMs\Omarchy\qemu.log -Wait
```

### Force Recreate Disk (Clean Slate)
```powershell
.\New-QemuVm.ps1 ... -ForceRecreate
```

### Fallback to Software Rendering (If Venus Fails)
```powershell
.\New-QemuVm.ps1 ... -NoGpuAccel
```

### Run Multiple VMs Simultaneously
```powershell
# Each VM needs unique ports (auto-assigned: Omarchy=4444/2222, Ubuntu=4445/2223)
# Launch in separate terminals
Terminal 1: cd C:\VMs\Omarchy; .\launch-VM.ps1
Terminal 2: cd C:\VMs\Ubuntu; .\launch-VM.ps1
```

### Lightweight Test VM
```powershell
# 4 vCPU, 8G RAM, 32G disk
.\New-QemuVm.ps1 -IsoPath "C:\ISOs\ubuntu-24.04-desktop-amd64.iso" -VmDir "C:\VMs\Test" -Vcpus 4 -MemoryGB 8 -DiskSize 32G
```

---

## Troubleshooting

### WHPX Not Enabled
```
Error: "WHPX not enabled. Run as Admin: dism /online /Enable-Feature /FeatureName:HypervisorPlatform /All"
```
**Fix**: Run the dism command as Administrator, reboot.

### QMP Connection Failed (Retries Exhausted)
```
Warning: "QMP connect failed after 4 retries"
```
**Causes**:
- QEMU crashed on startup (check `qemu.log`)
- WHPX nested virtualization conflict (WSL2/Hyper-V running)
- Port conflict (4444/4445 in use)

**Fix**: Check `qemu.log` for `WHvCreatePartition` or `memfd` errors. Try `-NoGpuAccel` to isolate.

### Venus Not Detected in Guest
```
vulkaninfo: no Venus ICD found
```
**Checks**:
1. Host GPU: `lspci` in guest should show `Red Hat, Inc. Virtio GPU`
2. Mesa version: `glxinfo \| grep "OpenGL version"` ≥ 24.2
3. Kernel: `uname -r` ≥ 6.13
4. WINQ-EMU version: `qemu-system-x86_64.exe -version` shows `WINQ-EMU`

**Fix**: Ensure WINQ-EMU is latest. Try `-DebugGpu` for `VENUS_DEBUG=1` logs.

### 144 Hz Not Achieved (vkcube < 144 FPS)
```
vkcube FPS: 60-90
```
**Checks**:
1. Host monitor actually 144 Hz (Windows Settings → Display → Advanced)
2. WINQ-EMU SDL EDID match working (check `qemu.log` for "EDID")
3. Guest Hyprland/GNOME set to 144 Hz (see Guest Config below)
4. `-display sdl,gl=on` not `-display gtk` or `-vga virtio`
5. Host GPU not throttling (check temperatures)

**Fix**: Try `-GpuMem 6G`, ensure `mitigator=off` in kernel cmdline, disable Windows Game Mode.

### Ubuntu Install Stuck at GRUB / Black Screen
**Cause**: Venus under EFI has reduced performance (WINQ-EMU finding).
**Workaround**: Install with `-NoGpuAccel`, then re-enable after install.

### Omarchy Boots to Emergency Shell / No Rootfs
**Cause**: Rootfs download/convert failed.
**Fix**: Check `C:\VMs\Omarchy\omarchy\rootfs.ext4.zst` exists. Re-run with `-ForceRecreate`.

### Memory Backend Fallback Triggered
```
Warning: "memfd backend failed, will retry with memory-backend-file"
```
**Meaning**: WHPX doesn't support `memfd` on this build. Script auto-falls back to file-based shared memory in `%TEMP%`. This is expected on some WHPX versions.

---

## Guest-Side Configuration

### Omarchy / Hyprland (Wayland)

**File**: `~/.config/hypr/monitors.lua`
```lua
monitor = "eDP-1"  -- virtio-gpu names it
monitor {
    name = "eDP-1"
    preferred = true
    resolution = "2560x1440@144"  -- or your native @ 144
    scale = 1
    cursor {
        invisible = false  -- MUST be false for SDL (WINQ-EMU finding)
    }
}
```
Apply: `hyprctl reload`

**Install Venus Vulkan Driver** (if missing):
```bash
# Omarchy uses Arch - install from AUR
yay -S vulkan-virtio  # or build Mesa with -Dvulkan-drivers=virtio
```

**Verify**:
```bash
glxinfo | grep "OpenGL renderer"
# Should show: virgl / venus
vulkaninfo | grep -i venus
# Should show: Virtio-GPU Venus (AMD Radeon Graphics)
vkcube --duration 10000 --fps
# Should show FPS ≥ 144
```

### Ubuntu 24.04 / GNOME (Wayland)

**Refresh Rate**: Settings → Displays → Refresh Rate → **144 Hz**

**Install Venus**:
```bash
sudo apt update && sudo apt install -y mesa-vulkan-drivers vulkan-tools
```

**Verify**:
```bash
vulkaninfo | grep -i venus
vkcube --duration 10000 --fps
```

### Ubuntu 24.04 / Hyprland (If Installed)
Same `monitors.lua` as Omarchy. Install `hyprland`, `waybar`, `wlroots` via apt or build.

---

## Advanced Configuration

### Custom OVMF (Ubuntu)
```powershell
# Download specific EDK2 release manually, place in VmDir:
# OVMF_CODE.fd, OVMF_VARS.fd (or .secboot variants)
# Script auto-detects existing files
```

### TAP Networking (Better Performance)
```powershell
# Requires WinTAP (OpenVPN) + Hyper-V vSwitch
# Manual QEMU args (not in script yet):
-netdev tap,id=net0,ifname="vEthernet (WSL)"
-device virtio-net-pci,netdev=net0
```

### VirtioFS Shared Folders (Faster than 9p)
```powershell
# If WINQ-EMU includes virtiofsd:
-chardev socket,id=char0,path=\\.\pipe\virtiofs
-device vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=shared
# Guest: mount -t virtiofs shared /mnt/shared
```

### 9P Shared Folders (Current Script Support)
```powershell
# Add to QEMU args manually:
-virtfs local,path=C:\Shared,mount_tag=shared,security_model=mapped-xattr
# Guest:
mount -t 9p -o trans=virtio,version=9p2000.L shared /mnt/shared
```

### Multiple VMs with Different Resources
```powershell
# Lightweight VM (4 vCPU, 8G RAM)
.\New-QemuVm.ps1 -IsoPath "..." -VmDir "C:\VMs\Test" -Vcpus 4 -MemoryGB 8 -Ccd 0 -DiskSize 32G
```

---

## Verification Checklist (Post-Boot)

Run these in guest via SSH (`ssh -p 2222 user@localhost` for Omarchy, `ssh -p 2223 user@localhost` for Ubuntu):

```bash
# 1. GPU Acceleration Active
glxinfo | grep "OpenGL renderer"
# ✅ Contains "virtio-gpu" or "venus"

# 2. Venus Vulkan ICD Present
vulkaninfo | grep -i venus
# ✅ Shows "Virtio-GPU Venus (AMD Radeon Graphics)"

# 3. Vulkan Performance ≥ 144 FPS
vkcube --duration 10000 --fps
# ✅ FPS ≥ 144 at native resolution

# 4. Display at 144 Hz
# Hyprland:
hyprctl monitors
# ✅ Shows "2560x1440@144" (or your native @ 144)
# GNOME:
gnome-control-center display
# ✅ Refresh Rate = 144 Hz

# 5. CPU Topology Correct
lscpu | grep -E 'CPU\(s\)|Thread|Core|Socket|NUMA'
# ✅ 8 CPUs, 2 threads/core, 4 cores, 1 socket

# 6. Memory Backend Working
dmesg | grep -i virtio
# ✅ virtio-gpu, virtio-blk, virtio-net present

# 7. Audio Working
pactl info | grep "Server Name"
# ✅ PipeWire running
speaker-test -t wav -c 2
# ✅ Audio audible

# 8. Network/SSH
ip addr show
# ✅ eth0 with 10.0.2.15 (user-mode NAT)
ssh localhost
# ✅ Works from host via port forward
```

---

## File Layout After Run

```
C:\WINQ-EMU\
├── bin\qemu-system-x86_64.exe
├── share\qemu\ (virglrenderer, keymaps, etc.)
└── tools\winkey-forwarder.exe

C:\VMs\Omarchy\
├── omarchy.qcow2
├── omarchy\
│   ├── vmlinuz-linux
│   ├── initramfs-linux.img
│   └── build-spec.json
├── launch-VM.ps1
├── serial.log
├── qemu.log
├── qemu.pid
├── qmp-supervisor.log
└── verification.log

C:\VMs\Ubuntu\
├── ubuntu.qcow2
├── OVMF_CODE.fd / OVMF_VARS.fd (or .secboot variants)
├── launch-VM.ps1
├── serial.log
├── qemu.log
├── qemu.pid
├── qmp-supervisor.log
└── verification.log
```

---

## Parameter Reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-IsoPath` | string (mandatory) | — | Path to ISO file |
| `-VmDir` | string (mandatory) | — | Target VM directory |
| `-Distro` | Omarchy/Ubuntu/Auto | Auto | Distribution type |
| `-Vcpus` | int | 8 | Number of vCPUs |
| `-MemoryGB` | int | 16 | RAM in GiB |
| `-DiskSize` | string | 64G | Disk size (qemu-img format) |
| `-Ccd` | 0/1 | 0 | CCD to pin (Ryzen 7950X) |
| `-GpuMem` | string | 4G | Venus hostmem |
| `-ForceRecreate` | switch | false | Overwrite existing disk |
| `-VerboseOutput` | switch | false | Detailed per-flag logging |
| `-NoGpuAccel` | switch | false | Fallback to llvmpipe |
| `-SecureBoot` | switch | false | UEFI Secure Boot (Ubuntu) |
| `-DebugGpu` | switch | false | Enable `VENUS_DEBUG=1` |

---

## Environment Variables

| Variable | Used By | Purpose |
|----------|---------|---------|
| `VENUS_DEBUG` | QEMU (via `-DebugGpu`) | Venus Vulkan debug logging |
| `TEMP` | Memory backend fallback | `memory-backend-file` path |

---

## Ports Reference

| VM | QMP Port | SSH Port | Winkey Forwarder |
|----|----------|----------|------------------|
| Omarchy | 4444 | 2222 | Auto |
| Ubuntu | 4445 | 2223 | Auto |

---

## Log Files

| File | Purpose |
|------|---------|
| `serial.log` | Guest kernel/boot messages |
| `qemu.log` | QEMU stderr (Venus errors, WHPX issues) |
| `qmp-supervisor.log` | Supervision events (SHUTDOWN, RESET, retries) |
| `verification.log` | GPU verification output (future) |