# New-GpuVm.ps1 — User Guide

Builds a GPU-accelerated Omarchy or Ubuntu QEMU virtual machine on a Windows x86_64 host using WHPX hardware acceleration, with a safe-exit design: it probes every external fact before acting, never overwrites anything silently, and exits with a distinct code telling you exactly what needs attention.

> **Read this first:** this script produces the best VM that Windows-host QEMU can offer. It guarantees a *working, correctly-configured* VM — it does **not** guarantee locked 144 Hz frame pacing. See [§11 Refresh rate](#11-refresh-rate--what-to-expect) and §16 Known limits.

## Contents

1. [What it does / doesn't do](#1-what-it-does-and-doesnt-do)
2. [Prerequisites](#2-prerequisites)
3. [Quick start](#3-quick-start)
4. [Parameters](#4-parameters)
5. [What happens when you run it](#5-what-happens-when-you-run-it)
6. [Prompts and safe-exit behavior](#6-prompts-and-safe-exit-behavior)
7. [Exit codes](#7-exit-codes)
8. [Files created](#8-files-created)
9. [First boot — installing the OS](#9-first-boot--installing-the-os)
10. [Daily use](#10-daily-use)
11. [Refresh rate — what to expect](#11-refresh-rate--what-to-expect)
12. [Re-running the script (idempotency)](#12-re-running-the-script-idempotency)
13. [Unattended mode](#13-unattended-mode)
14. [Troubleshooting](#14-troubleshooting)
15. [FAQ](#15-faq)
16. [Known limits](#16-known-limits)

---

## 1. What it does and doesn't do

| ✅ DOES | ❌ DOESN'T |
| --- | --- |
| Detect your hardware, QEMU build, and WHPX state by probing, not assuming | Provide a QEMU build — you must install one (a 3D-capable one, see §2.3) |
| Auto-tune flags per distro (Venus/Vulkan for Omarchy/Hyprland) | Guarantee locked native 144 Hz — no Windows-host QEMU path can |
| Fall back safely (audio omitted, GPU downgraded, TCG last resort) — always telling you | Fix a wrong QEMU build for you — it warns and gates, you swap the binary |
| Never overwrite a disk or NVRAM; back up launchers before regenerating | Render the guest for you — final truth is `glxinfo -B` inside the guest |
| Write a full decision log and exit with a code that says what went wrong | Work over RDP reliably (host OpenGL usually breaks — test at the physical console) |

---

## 2. Prerequisites

### 2.1 Hardware / OS

- Windows 10 (2004+) or Windows 11, x86_64 (the script refuses to run on ARM64)
- CPU virtualization enabled in UEFI/BIOS (Intel VT-x / AMD-V — usually on by default)
- RAM: guest allocation (default 8 GB) plus ~4 GB for Windows

### 2.2 Enable Windows Hypervisor Platform

Either way requires one reboot:

- GUI: `optionalfeatures.exe` → tick Windows Hypervisor Platform → OK → reboot
- CLI (admin):

```powershell
DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All
```

You don't have to do this beforehand — if it's missing, the script detects it, offers to enable it for you (needs an elevated PowerShell), and exits with code 2 telling you to reboot and re-run.

### 2.3 Install QEMU — ⚠ the critical step

Stock QEMU from qemu.org or MSYS2 is 2D-only on Windows. Your guest will software-render (llvmpipe) — the script will detect this and warn you, but it cannot fix it. For real 3D you need a virgl-capable Windows build on PATH:

| BUILD | WHAT YOU GET |
| --- | --- |
| WINQ-EMU (cmspam) — linked from the try-omarchy-windows README | VirGL + Venus Vulkan, patched WHPX; what the official Omarchy EXE uses |
| Tsuki-Bakery/qemu-virgl-whpx | WHPX + VirGL (via ANGLE→D3D) cross-compiled for Windows |

Two rules:

1. Put the entire `bin` folder on PATH — copying out just the exe breaks it on missing DLLs (the script detects this and tells you).
2. Verify 3D capability *before* running the script:

```powershell
qemu-system-x86_64.exe -device help | findstr virtio-vga-gl
```

Output = good. No output = 2D-only build.

### 2.4 ISOs

- Ubuntu: `https://releases.ubuntu.com` → desktop amd64 ISO
- Omarchy: the official Omarchy site/repo
- Name the file so it contains `omarchy` or `ubuntu` (the script auto-detects the distro from the filename; otherwise it asks).
- Optional but recommended — note the hash to pass via `-ExpectedSha256`:

```powershell
Get-FileHash .\ubuntu-24.04-desktop-amd64.iso -Algorithm SHA256
```

### 2.5 Checklist

- [ ] Virtualization enabled in firmware
- [ ] Windows Hypervisor Platform enabled (or let the script do it) + rebooted
- [ ] Virgl-capable QEMU on PATH, `-device help` test passes
- [ ] ISO downloaded, hash noted
- [ ] Target VM directory on a local drive (not OneDrive), with room for up to `DiskGB`

---

## 3. Quick start

Save the script as `New-GpuVm.ps1`. If you downloaded it, unblock it first (`Unblock-File .\New-GpuVm.ps1`), then:

```powershell
cd C:\path\to\script
powershell -ExecutionPolicy Bypass -File .\New-GpuVm.ps1 -Verbose
```

Or in an existing PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\New-GpuVm.ps1 -Verbose
```

You'll be asked exactly two questions:

```text
Path to the Omarchy/Ubuntu ISO: D:\isos\omarchy-x86_64.iso
VM target directory: D:\vms\omarchy
```

The script then probes everything and prints a summary. A healthy run looks like:

```text
================ VM ready ================
 Distro      : omarchy
 Accelerator : whpx
 GPU device  : virtio-vga-gl,hostmem=4G,blob=true,venus=true
 Display     : sdl,gl=on
 Audio       : dsound -> ICH9 HDA
 Disk        : D:\vms\omarchy\omarchy.qcow2
 Launcher    : D:\vms\omarchy\omarchy-launch.ps1  (or omarchy-launch.cmd)
 Guest ssh   : ssh -p 2222 <user>@localhost
 Log         : D:\vms\omarchy\setup-log.txt   (warnings: 0)
 ------------------------------------------------
 1. Run with -BootInstaller to install to disk
 2. In guest: glxinfo -B  -> renderer must be virgl, NOT llvmpipe
 3. Hyprland mode: monitor = Virtual-1,1920x1080@144,0x0,1  (judge with a vsync test)
==========================================
```

Then install the OS (§9) and use the launcher daily (§10).

---

## 4. Parameters

All parameters are optional; the script asks for ISO path and VM directory interactively if omitted.

| PARAMETER | TYPE / DEFAULT | MEANING |
| --- | --- | --- |
| `-IsoPath` | string | Path to the Omarchy or Ubuntu `.iso`. Quoted/pasted paths are tolerated. |
| `-VmDir` | string | Target directory (created if missing). Holds disk, NVRAM, launchers, log. Avoid OneDrive. |
| `-Vcpus` | int, `8` (2–64) | Guest vCPUs. Warns if it starves the host. |
| `-RamGB` | int, `8` (1–256) | Guest RAM in GB. |
| `-DiskGB` | int, `60` (8–1024) | Sparse qcow2 size — grows as used, but warns if the drive can't hold the max. |
| `-ExpectedSha256` | string | If set, the ISO hash must match or the script exits 4. Makes *you* the verification step. |
| `-Unattended` | switch | Never prompt; every decision resolves to the safe default (usually abort). For automation. |
| `-SkipProbes` | switch | Skip the live WHPX/GPU launch probes and assume from help output. Only if probes hang on exotic hardware. |
| `-NoPause` | switch | Don't pause for Enter on error (for scripted runs). |
| `-LaunchNow` | switch | Boot the installer immediately after setup succeeds. |
| `-Verbose` | switch (common) | Streams every decision as it's made; also written to `setup-log.txt` regardless. |

Examples:

```powershell
# Fully explicit, verified ISO, boot right away
.\New-GpuVm.ps1 -IsoPath D:\isos\omarchy.iso -VmDir D:\vms\omarchy `
    -Vcpus 6 -RamGB 12 -DiskGB 80 `
    -ExpectedSha256 3B4A...C9 -LaunchNow

# Minimal
.\New-GpuVm.ps1
```

---

## 5. What happens when you run it

Nine phases, in order. Every ⚡ item is a live probe — a real test, not an assumption:

| PHASE | WHAT IT CHECKS / DOES |
| --- | --- |
| 1. Inputs | ARM64 host guard → ISO exists/sane size/.iso extension → VM dir created, writability probed → OneDrive warnings → optional SHA256 verification |
| 2. QEMU health | ⚡ Binary actually runs (catches missing-DLL installs) → version parsed → ⚡ `-device help` parsed: picks the best GPU device (`virtio-vga-gl` > `virtio-gpu-gl` > `virtio-vga` > `virtio-gpu` > `VGA`) → ⚡ `-display help`: SDL preferred, GTK fallback → ⚡ `-audiodev help`: `dsound` present? |
| 3. Host sizing | Logical cores, total/free RAM, free disk vs `DiskGB`, hybrid-Intel (E-core) warning, RDP-session warning |
| 4. Distro | From ISO filename; asks you if ambiguous (fails in `-Unattended`) |
| 5. Accelerator | `HypervisorPresent` + feature state → if feature missing: offers to enable via DISM (admin; then exit 2 → reboot → re-run) → ⚡ live WHPX launch probe (paused VM, 4 s); on failure, one second chance with `kernel-irqchip=off` (the documented wedge workaround) → TCG only if you explicitly accept |
| 6. GPU | Builds the device string: `hostmem` = min(4, RamGB/2) GB, `blob=true`, `venus=true` for Omarchy on QEMU ≥ 9.2 → ⚡ live device-realize probe (proves the 3D device initializes, not just that it's compiled in); on failure downgrades to 2D with your consent |
| 7. Firmware | Finds OVMF (`edk2-x86_64-code.fd` + vars template) next to QEMU; downloads from the qemu v9.2.0 tag (TLS 1.2, size-checked) if absent → creates per-VM NVRAM copy, preserves existing |
| 8. Disk + port | ⚡ `qemu-img` found → never overwrites: existing disk → reuse/new/abort → picks the first free ssh port from 2222 (Omarchy) / 2223 (Ubuntu) |
| 9. Launcher | Backs up any existing launcher (`.bak-*`) → generates `<distro>-launch.ps1` + double-clickable `.cmd` shim → syntax self-check (`[scriptblock]::Create()`) before writing |

---

## 6. Prompts and safe-exit behavior

Three tiers:

| TIER | BEHAVIOR | EXAMPLES |
| --- | --- | --- |
| Auto-handled | Logged, no prompt | Port busy → next free port; audio backend missing → launcher omits audio; NVRAM exists → preserved |
| ⚠ Asks you (default = safe, usually n) | You must explicitly choose to proceed | WHPX broken → "continue on TCG (unusably slow?)" · 3D missing → "continue knowing it's software-rendered?" · disk exists → reuse/new/abort (default reuse) |
| Hard-fail, exit now | Distinct exit code + message + log | ISO missing, hash mismatch, QEMU broken, dir unwritable, no free port, OVMF unavailable |

With `-Unattended`, every prompt is auto-answered with the safe default — meaning a degraded-but-possible build aborts rather than silently proceeding.

Example gated session (no virgl build on PATH):

```text
WARNING: This QEMU has no working VirGL 3D path - the guest will SOFTWARE-render
(llvmpipe). Better: install a virgl-capable Windows QEMU build (WINQ-EMU /
qemu-virgl-whpx) and re-run.
No working VirGL 3D path detected - continue anyway? (y/N) [n]: n
=== FAILED (exit 2) ===
No working VirGL 3D path detected - the guest will SOFTWARE-render (llvmpipe).
Details: D:\vms\omarchy\setup-log.txt
```

On error in an interactive session, the window pauses (Press Enter) so the message doesn't vanish — suppress with `-NoPause`.

---

## 7. Exit codes

| CODE | MEANING | TYPICAL CAUSES → WHAT TO DO |
| --- | --- | --- |
| 0 | Success | VM ready (and launched, if requested) |
| 1 | Unexpected error | Bug/unforeseen state → read `setup-log.txt` |
| 2 | Aborted at a prompt **or** reboot required | You declined a continue-gate; or the script just enabled Hypervisor Platform → reboot, re-run |
| 3 | Virtualization / accelerator failure | WHPX probe failed and you declined TCG; DISM failed → check firmware virtualization setting, `bcdedit /set hypervisorlaunchtype auto`, reboot |
| 4 | Input / validation failure | ISO missing or wrong hash; QEMU not on PATH; QEMU binary won't run (missing DLLs); VM dir not writable |
| 5 | Tooling failure | `qemu-img` missing; OVMF not found and download failed (place the `.fd` files in the VM dir manually and re-run); generated launcher failed its syntax self-check |

Every run appends to `<VmDir>\setup-log.txt` — that file is the ground truth for what was detected and why.

---

## 8. Files created

In the VM directory you chose:

| FILE | PURPOSE |
| --- | --- |
| `<distro>.qcow2` | System disk (sparse; grows as used). Never overwritten. |
| `<distro>-VARS.fd` | Per-VM UEFI NVRAM (boot entries live here). Never overwritten. |
| `<distro>-launch.ps1` | The launcher — use this daily. |
| `<distro>-launch.cmd` | Double-clickable shim for the launcher. |
| `setup-log.txt` | Append-only decision log of every run. |
| `edk2-*.fd` (maybe) | OVMF files, only if they had to be downloaded. |
| `<distro>-launch.ps1.bak-*` | Previous launcher, saved before regeneration. |
| `probe-*.err` | Transient probe output — deleted automatically. |

Move the whole folder freely **except** between drives/paths: the launcher embeds absolute paths. If you move the VM, re-run the script (it will detect and reuse everything).

---

## 9. First boot — installing the OS

The launcher has two switches:

```powershell
.\omarchy-launch.ps1 -BootInstaller    # boot the ISO (first install)
.\omarchy-launch.ps1                   # boot the installed disk (daily use)
.\omarchy-launch.ps1 -FullScreen       # start fullscreen (Ctrl+Alt+F toggles)
```

`-BootInstaller` puts the CD first in UEFI boot order (via `bootindex` — OVMF ignores legacy `-boot order=`). After installation, run without the switch and the disk boots.

**Ubuntu:** install normally (Erase disk is fine — it's the virtual disk). Reboot, remove `-BootInstaller`.

**Omarchy:** it boots into a live environment → run Omarchy's installer to the virtual disk → reboot without `-BootInstaller`. First boot shows Omarchy's setup form (create your account or pick the trial account).

> Reinstall/rescue later? Just run with `-BootInstaller` again — your disk and NVRAM are untouched.

---

## 10. Daily use

- **Start:** double-click `<distro>-launch.cmd`, or `.\omarchy-launch.ps1` in PowerShell.
- **Fullscreen:** `Ctrl+Alt+F` inside the VM window (or `-FullScreen` at start).
- **Files in/out:** no SPICE clipboard on this path — use SSH:

```powershell
ssh -p 2222 user@localhost          # Omarchy (2223 for Ubuntu)
scp -P 2222 file.txt user@localhost:~
```

  (Requires `openssh-server` in the guest: Ubuntu `sudo apt install openssh-server`, Omarchy `sudo pacman -S openssh`.)

- **Shared folders:** 9p/virtiofs are not usable on Windows hosts. Either SSH/SCP as above, or share a folder on Windows (SMB) and mount it in the guest from `//10.0.2.2/share` (slirp NAT maps the host there).
- **Audio** works automatically via PipeWire in the guest (if the `dsound` backend was present at build time — the summary told you).
- **Shutdown:** shut down from *inside* the guest. Closing the SDL window is the equivalent of pulling the power cord.

---

## 11. Refresh rate — what to expect

Honest expectations, in order of likelihood:

1. Smooth 60 Hz desktop, video, compositing — the normal outcome on decent hardware.
2. 120–144 Hz-ish on strong CPUs/GPUs — achievable but pacing won't be bare-metal clean.
3. Locked, tear-free native 144 — not promised by any Windows-host QEMU path. If that's a hard requirement: dual boot.

Two distinctions:

- *"Reports 144" ≠ "delivers 144."* The guest can *claim* a mode it can't pace. Never judge from the settings panel — run a browser vsync/refresh test (`testufo.com` or similar) inside the guest, on the physical console.
- **RDP lies.** Over RDP, host OpenGL frequently fails or degrades and results are meaningless. Always test at the physical console.

Guest-side setup:

*Omarchy (Hyprland/Wayland)* — add to `~/.config/hypr/hyprland.conf`:

```text
monitor = Virtual-1,1920x1080@144, 0x0, 1
```

Verify with `hyprctl monitors`. Hyprland generally accepts custom refresh rates where GNOME won't.

*Ubuntu (GNOME)* — Settings → Displays → refresh rate. Wayland sessions often cap at 60; an Xorg session can be forced higher with `cvt 1920 1080 144` + `xrandr --newmode/--addmode Virtual-1 <mode>`.

Definitive 3D check (do this first, before chasing Hz):

```bash
glxinfo -B              # renderer MUST say "virgl" (or Venus) - NOT "llvmpipe"
vulkaninfo --summary    # Omarchy with venus=true: should list a Venus device
```

`llvmpipe` = CPU rendering = your host QEMU build lacks virgl. Fix the build (§2.3), re-run the script — no amount of guest config changes this.

---

## 12. Re-running the script (idempotency)

Safe to run repeatedly, including to retune (new `-Vcpus`, different ISO, new QEMU build on PATH):

| ITEM | ON RE-RUN |
| --- | --- |
| Existing disk (`<distro>.qcow2`) | Never overwritten — asked: (r)euse [default] / create (n)ew numbered / (a)bort |
| NVRAM (`<distro>-VARS.fd`) | Preserved (your UEFI boot entries survive) |
| Existing launcher | Regenerated; old copy saved as `.bak-<timestamp>` (your manual edits don't survive regeneration — re-apply or edit the new file) |
| OVMF files | Reused if found; re-downloaded only if missing |
| ssh port | Re-picked from the base (2222/2223), skipping anything busy |

Deleting `<distro>-VARS.fd` resets UEFI to factory (occasionally useful if boot entries get corrupted). Deleting the `.qcow2` deletes the installed OS — that one is always your explicit choice.

---

## 13. Unattended mode

For scripting/CI — no prompts, safe defaults, machine-readable exit code:

```powershell
.\New-GpuVm.ps1 -IsoPath D:\isos\ubuntu-24.04-desktop-amd64.iso `
    -VmDir D:\vms\u2404 -ExpectedSha256 ABCD... -Unattended -NoPause
if ($LASTEXITCODE -ne 0) { throw "VM setup failed with $LASTEXITCODE" }
```

Behavior: ambiguous ISO names fail (4) instead of guessing; degraded paths (TCG, 2D, headless) abort (2) instead of proceeding; the final "launch now?" is skipped unless `-LaunchNow`.

`-SkipProbes` exists for hosts where the paused-VM probes misbehave; the script then trusts help-output parsing. Use it only if probes are your confirmed problem — probes are what catch broken setups *before* they waste your time.

---

## 14. Troubleshooting

### Setup-time (exit codes)

| SYMPTOM | CAUSE → FIX |
| --- | --- |
| Exit 4: "qemu-system-x86_64.exe is not on PATH" | QEMU not installed or PATH incomplete → add the full `bin` folder to PATH, reopen the shell |
| Exit 4: "QEMU at '…' failed to run" | Exe copied out of its folder without DLLs → reinstall / fix PATH |
| Exit 4: ISO hash mismatch | Re-download the ISO; compare against the *official published* hash |
| Exit 3: WHPX probe failed (both attempts) | Hypervisor Platform not enabled/rebooted; virtualization off in firmware; `hypervisorlaunchtype` set to `off` (`bcdedit /set hypervisorlaunchtype auto`, reboot); conflicting VMMs (VMware < v15, old VirtualBox) |
| Exit 2: "REBOOT now, then re-run" | Expected — the script just enabled Hypervisor Platform. Reboot, re-run. |
| Exit 5: OVMF download failed | Network/proxy → download `edk2-x86_64-code.fd` + `edk2-i386-vars.fd` from the qemu GitHub (v9.2.0 tag, `pc-bios/`) into the VM dir manually, re-run |
| Exit 2: you declined a continue-gate | That's the safe exit working. Fix the underlying issue (usually the QEMU build), re-run. |

### Runtime (in/around the VM)

| SYMPTOM | CAUSE → FIX |
| --- | --- |
| `glxinfo -B` says llvmpipe | Host QEMU build has no virgl → install WINQ-EMU / qemu-virgl-whpx (§2.3), re-run script, verify summary shows `virtio-vga-gl,...` |
| Launcher fails instantly at boot | Usually flags vs build mismatch → re-run the script so the launcher is regenerated against the *current* QEMU build; check `setup-log.txt` |
| No window at all | Build lacks SDL/GTK (summary would have said `Display: none`) → use a normal build |
| Everything is slow | Summary said `Accelerator: tcg` → fix WHPX (exit-3 row above) and re-run |
| Stuttering / bad frames over RDP | Expected — test at the physical console |
| Guest clock drifts | Launcher already sets `-rtc base=utc`; ensure the guest uses UTC/local correctly (Ubuntu `timedatectl`) |
| No audio | Summary said `Audio: none` → your build lacks `dsound`; install a build with it |
| GNOME stuck at 60 Hz | Wayland cap → try an Xorg session + xrandr (§11), then judge with a vsync test |
| Boot lands in UEFI shell after install | NVRAM lost boot entry → re-run script (preserves NVRAM), or from the UEFI shell select the disk's boot entry once; worst case delete `<distro>-VARS.fd` and re-run |

---

## 15. FAQ

**Can I have both an Omarchy and an Ubuntu VM?**
Yes — separate `-VmDir` per VM. Ports auto-resolve (Omarchy starts at 2222, Ubuntu at 2223, incrementing past anything busy).

**Can I resize the disk later?**
`qemu-img resize omarchy.qcow2 +20G`, then grow the partition/filesystem in the guest (`growpart` / `resize2fs`, or Arch's `parted` + `btrfs filesystem resize`). Only grows — shrinking qcow2 isn't supported.

**Snapshots?**
`qemu-img snapshot -c clean omarchy.qcow2` (create), `-a clean` (restore) — with the VM off.

**Where do I get the 3D-capable QEMU?**
WINQ-EMU (see credits in the try-omarchy-windows README) or Tsuki-Bakery/qemu-virgl-whpx. The script doesn't download QEMU for you — deliberately.

**Why no copy/paste between host and guest?**
Clipboard integration comes via SPICE, which Windows QEMU builds don't ship. Use SSH/SCP (§10).

**Can I move the VM folder?**
Same path: yes. Different path/drive: re-run the script — it regenerates the launcher (absolute paths) and reuses disk + NVRAM.

**Will I get 144 Hz?**
See §11 and §16. Short version: smooth 60 is the norm, 120+ is a bonus on strong hardware, locked native 144 is not on the menu — dual boot if it's a hard requirement.

---

## 16. Known limits

- **Probes prove initialization, not rendering throughput.** The script verifies WHPX launches and the 3D device realizes. Only `glxinfo -B` + a vsync test in the running guest tells you what you actually got.
- **The graphics path has inherent overhead:** every frame crosses guest compositor → virtio-gpu → QEMU → host GL → host compositor. This cannot match bare-metal latency or pacing, on any configuration.
- **Vendor caveats:** Venus/Vulkan path is least-tested on NVIDIA hosts; hybrid Intel CPUs (E-cores) can add scheduling jitter (the script warns).
- **The official Omarchy EXE is pre-tuned against its own bundled QEMU build (WINQ-EMU).** Running the generic ISO on a different virgl build is the least-trodden path — if in doubt for Omarchy specifically, the EXE is the zero-effort baseline to compare against.
