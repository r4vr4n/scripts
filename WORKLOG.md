# WORKLOG

Running log of work on the QEMU VM builder scripts. Newest session at the bottom.

---

## 2026-09-30: Ubuntu 26.04 VM with `New-QemuVm-Universal.ps1`

**Goal:** build a GPU-accelerated Ubuntu 26.04 VM from
`C:\Users\r4v\Downloads\ubuntu-26.04.1-desktop-amd64.iso` (6.48 GB) into `E:\VMs\Ubuntu26`.

### 1. Host findings (read-only probes)

| Item | Value |
| --- | --- |
| CPU | AMD Ryzen 9 7950X, 32 logical cores |
| RAM | 63 GB total, ~30 GB free |
| Hypervisor | `HypervisorPresent = True` (WHPX usable) |
| Shell | not elevated |
| QEMU | 9.2.91 at `C:\Program Files\qemu`, **not on PATH** |
| QEMU capabilities | `virtio-vga-gl`, SDL, dsound, `qemu-img.exe`, `edk2-x86_64-code.fd` all present |
| Free space | C: 478 GB, D: 78 GB, E: 166 GB |

Chosen settings: `-Vcpus 8 -RamGB 16 -DiskGB 80`, VM dir `E:\VMs\Ubuntu26` (next to the existing `E:\VMs\TryOmarchy`).

### 2. First launch failed: my quoting bug (not a script bug)

I launched the builder in a new window with `Start-Process powershell -ArgumentList ... -Command '$env:PATH = "C:\Program Files\qemu;..."'`.
`Start-Process` dropped the inner double quotes. PowerShell then tried to run `C:\Program`, never updated PATH, and lost `-IsoPath`/`-VmDir`.
The script prompted for a directory (the user typed `E:\VMs`) and exited 4 ("qemu-system-x86_64.exe is not on PATH").

- Side effect: a stray `E:\VMs\setup-log.txt`, which can be deleted.
- Fix: run from a wrapper `.ps1` via `-File`, or have the user paste single-quoted commands into their own terminal.
- Also: my Claude shell is sandboxed, and writes to `E:` from it don't persist. So real runs have to happen in the user's own PowerShell.

### 3. Second run stopped at the GPU gate

With QEMU on PATH, WHPX probed OK, then:

```text
WARNING: GPU 'virtio-vga-gl,hostmem=4G,blob=true' failed to initialize: ... The display backend does not have
OpenGL support enabled It can be enabled with '-display BACKEND,gl=on' ...
GPU fallback -> virtio-vga
No working VirGL 3D path detected ... continue anyway? (y/n [n]):
```

### 4. Root cause: the probe itself was wrong

`Test-QemuLaunch` always passed `-display none`. A `virtio-*-gl` device refuses to start without a GL-enabled display, so the GPU probe failed on **every** build, virgl-capable or not.

Manual check with the stock QEMU and a GL display:

```powershell
qemu-system-x86_64.exe -machine q35 -nodefaults -display sdl,gl=on -monitor none -S `
    -accel whpx -device virtio-vga-gl,hostmem=4G,blob=true
# -> process alive after 5 s, WHPX operational: the device starts fine
```

### 5. Decision: fix the probe AND always install a virgl build

The user chose "always download virgl build" over "fix the probe only".

Build research:

| Build | Latest | Package | Notes |
| --- | --- | --- | --- |
| [WINQ-EMU (cmspam)](https://github.com/cmspam/winq-emu) | `alpha10`, 2026-04-27 | `WINQ-EMU-Alpha10-Setup.exe` (60 MB, NSIS) | QEMU 11.0 + virglrenderer 1.3.0, Venus; installs to `C:\WINQ-EMU` |
| [qemu-virgl-whpx (Tsuki-Bakery)](https://github.com/Tsuki-Bakery/qemu-virgl-whpx) | `v0.0.5`, 2025-04-30 | `qemu-virgl-whpx.zip` (117 MB) | Older; not used |

I picked WINQ-EMU: it's newer, the docs already recommend it, and it has a single silent-installable installer.

### 6. Script changes (`New-QemuVm-Universal.ps1` v3.2 → v3.3)

- New parameters:
  - `-WinqEmuDir` (default `C:\WINQ-EMU`)
  - `-UsePathQemu` (old behaviour: QEMU from PATH, no download)
- New helper `Install-WinqEmu`, which:
  - queries the GitHub latest-release API
  - asks before installing (safe-exit rule: `-Unattended` never installs third-party software)
  - downloads to `%TEMP%\winq-emu`
  - checks the file size and, when the API publishes one, the SHA256 digest
  - logs the Authenticode status
  - runs the NSIS silent install `/S /D=<dir>`
- Phase 2:
  - reuses an existing WINQ-EMU install and installs only if it's missing
  - puts its folder first on PATH for the process
- `Test-QemuLaunch` gained a `-Display` parameter. The GPU probe now uses the real display (`sdl,gl=on`), so a small SDL window flashes for about 4 s during the probe.

### 7. Verification

- ✅ PowerShell parser: 0 errors after the edits. Encoding (UTF-8, no BOM) unchanged.
- ✅ The GitHub API lookup the script uses resolves:
  - `alpha10` / `WINQ-EMU-Alpha10-Setup.exe`, 60,132,474 bytes
  - digest `sha256:7a50aa4f…0f15fbe`, so the SHA256 check will run
- ✅ `USAGE-Universal.md` updated in §2.3 (auto-install), §4 (new parameters), §5 (phase 2) and §13 (unattended).
- ⏳ **End-to-end run: pending, done by the user in their own PowerShell** (my sandbox can't write to `E:` or install software):

  ```powershell
  Set-ExecutionPolicy -Scope Process Bypass -Force
  & 'D:\Github\scripts\New-QemuVm-Universal.ps1' -IsoPath 'C:\Users\r4v\Downloads\ubuntu-26.04.1-desktop-amd64.iso' -VmDir 'E:\VMs\Ubuntu26' -Vcpus 8 -RamGB 16 -DiskGB 80 -Verbose
  ```

  Expected: install prompt → UAC → silent install into `C:\WINQ-EMU` → GPU probe passes → summary shows `GPU device : virtio-vga-gl,hostmem=4G,blob=true`, exit 0.
- ⏳ In the guest after install: `glxinfo -B` → the renderer should be virgl, not llvmpipe.

### Follow-ups (not done)

- WINQ-EMU recommends **BIOS boot rather than EFI** for Vulkan/Venus performance. The script is UEFI-only.
- `venus=true` is only added for Omarchy. Ubuntu 26.04's Mesa could likely use it too.

### 8. First real run (user)

- ? WINQ-EMU installed into `C:\WINQ-EMU`. GPU probe passed: `virtio-vga-gl,hostmem=4G,blob=true`, `sdl,gl=on`, WHPX, 0 warnings.
- ? The launcher failed at once: `'hda-dup' is not a valid device model name`. The audio codec was misspelled in the launcher template; it should be `hda-duplex` (confirmed with `-device help`). Fixed.
- Note: the files landed in `E:\Vms\` rather than `E:\VMs\Ubuntu26`. Check which `-VmDir` was actually passed.


### 9. Installer UI glitching (v3.4)

**Symptom:** the Ubuntu 26.04 live session booted, but GNOME windows smeared. Stacked ghost copies of old frames made the installer unusable. The disk was still empty (198 KB), so nothing had been installed.

**Comparison with WINQ-EMU's own tested launcher** (`C:\WINQ-EMU\launch-vm.bat` + `README.txt`):

| | Ours (v3.3) | WINQ-EMU reference |
| --- | --- | --- |
| Firmware | UEFI (OVMF) | **BIOS**. README: "Use BIOS boot, not EFI/UEFI - EFI boot causes a timing issue with Vulkan initialization" |
| GPU | `virtio-vga-gl,hostmem=4G,blob=true` | `virtio-vga-gl,blob=on,hostmem=4G,venus=on` |
| Audio | ICH9 HDA + hda-duplex | `virtio-sound-pci` |

**Changes (`New-QemuVm-Universal.ps1` v3.4):**
- `-Firmware Auto|Bios|Uefi`:
  - `Auto` picks BIOS for a new or empty disk.
  - It picks UEFI only if the disk holds more than 1 MB of data **and** `<distro>-VARS.fd` exists. That protects VMs already installed under UEFI.
  - Disk usage comes from `qemu-img info -U --output=json`.
  - The disk and port phase now runs before the firmware phase.
- `venus=true` for all distros on WINQ-EMU. If the GPU probe fails, it retries once without venus before falling back to 2D.
- Audio uses `virtio-sound-pci` when the build has it.
- New launcher switch `-SafeGraphics`: `virtio-vga` + `sdl,gl=off`, for finishing an install if 3D still misbehaves.

**Verification (mine):**
- ✅ Parser: 0 errors.
- ✅ The launcher template renders and parses for both BIOS and UEFI. The BIOS variant has no pflash lines.
- ✅ `-SafeGraphics` swaps the GPU to `virtio-vga` and the display to `sdl,gl=off`.
- ✅ WINQ-EMU probe with `virtio-vga-gl,hostmem=4G,blob=true,venus=true` + `sdl,gl=on` + virtio-sound under WHPX: still alive after 5 s.
- ✅ `E:\Vms\ubuntu.qcow2` actual-size is 198,144 bytes, so `Auto` resolves to **BIOS**.
- ⏳ The user re-runs the script, then checks whether the installer draws cleanly.

### 10. Installer: "Next" does nothing

**Result of v3.4:** the live session now draws cleanly, so the ghosting is gone. BIOS + Venus + virtio-sound works.

**New problem:** on the installer's "What do you want to do with Ubuntu?" page, clicking Next has no effect.

Possible causes (not yet known which):
- **(a)** The installer backend (subiquity) is still probing, or it crashed.
- **(b)** Pointer clicks aren't reaching the window properly.
- **(c)** The Flutter app is stalling under virgl/Venus.

Diagnosis steps sent to the user:
1. Wait about 60 s and try again.
2. Press `Tab` until Next is highlighted, then `Enter`.
3. In a terminal, run `journalctl -b --no-pager | grep -iE 'subiquity|ubuntu-desktop-bootstrap|error' | tail -40`.
4. Close and relaunch the installer.
5. Fallback: boot with `-BootInstaller -SafeGraphics`.

No script change until the cause is known.

### 11. Still flickering at the corners, Next still dead → `-Fresh` + 2D install (v3.5)

**Report:** under BIOS + Venus, the live installer still flickers at the window corners, and Next still does nothing.

**Decision:**
- **Start over on every failed attempt.** The user asked for this. It's an explicit `-Fresh` switch, not the default, so that a routine re-run after a real install can't wipe the OS.
- **Install in 2D.** The GNOME live session under virgl misbehaves on both the UEFI and BIOS paths. The installer doesn't need 3D, so "Launch now?" at the end of setup now boots `-BootInstaller -SafeGraphics`. 3D is judged on the installed desktop.

**`-Fresh` behaviour:**
- Collects `<distro>(-N).qcow2`, `<distro>-VARS.fd`, `<distro>-launch.ps1/.cmd(.bak-*)` and stale `probe-*.err` in the VM dir.
- If a QEMU process is running on those disks, it offers a hard stop. The default is no, which aborts.
- Lists the files with their sizes and confirms (default y, since `-Fresh` is itself the consent), then deletes them and rebuilds. `setup-log.txt` is kept.

**Verification (mine):**
- ✅ Parser: 0 errors.
- ✅ Dry-run match against `E:\Vms` finds `ubuntu.qcow2`, `ubuntu-VARS.fd`, `ubuntu-launch.ps1/.cmd`, 3 launcher backups and 2 `probe-*.err`.
- ✅ It leaves `TryOmarchy\` and `setup-log.txt` alone.
- ✅ The running VM (PID 50704) is matched by its disk path, so the stop prompt will appear.
- ⏳ The user re-runs with `-Fresh`, then does the install in 2D.

### 12. Result: success ✅

The user ran it with `-Fresh`. The first attempt worked end to end: the cleanup, the rebuild, and the 2D (`-SafeGraphics`) install all went through with no issues.

**Working recipe (v3.5):** WINQ-EMU alpha10 (QEMU 11.0), WHPX, BIOS boot, `virtio-vga-gl,hostmem=4G,blob=true,venus=true`, `sdl,gl=on`, virtio-sound, and the install done in 2D.

Still open:
- Boot the installed desktop in 3D (`E:\Vms\ubuntu-launch.ps1`).
- Check `glxinfo -B` (virgl) and `vulkaninfo --summary` (Venus).
- See whether the installed GNOME session flickers the way the live session did.

### 13. Moving the VM to another Windows PC + firmware-detection fix

**Found while answering "can I move the image":**
- `E:\Vms\ubuntu-VARS.fd` is a leftover from the first UEFI attempt (19:52). The same disk was later reused and installed under **BIOS**.
- `-Firmware Auto` treated "disk has data + VARS.fd present" as a UEFI install. So any later re-run would have switched this VM to UEFI and it would no longer boot.

**Fix:** for an installed disk, `Auto` now uses the existing launcher as ground truth (`if=pflash` in it means UEFI, otherwise BIOS). Only when there's no launcher does it fall back to the VARS.fd check.

**Simulated:**
- This VM resolves to **bios**.
- A copied qcow2 alone (no launcher, no VARS.fd) resolves to **bios**.

**Move recipe:** copy only `ubuntu.qcow2` (9.4 GB used) and the ISO. Do **not** copy `ubuntu-VARS.fd`. On the new PC, run the setup script without `-Fresh` and answer **r** (reuse).

### 14. Terminal launch command added by the script

**Request:** have the script add the launch command to the user's terminal profile before the installation starts.

**Implementation (`Add-ProfileCommand`):**
- **When:** after the launcher is written and before "Launch now?". The script asks first (default y; `-Unattended` answers n; `-SkipProfileCommand` skips the question).
- **Where:** it always writes the Windows PowerShell 5.1 profile. It also writes the PowerShell 7 profile if pwsh is installed or `Documents\PowerShell` exists.
- **Managed block:** `# >>> New-GpuVm: <distro> >>>` … `<<<`. The block is **replaced** on every run, so a moved VM gets the new path. The rest of the profile is left untouched.
- **Name:** `<distro>`, or `<distro>-vm` if that name is already an executable (for example WSL's `ubuntu.exe`).
- **Encoding:** UTF-8 with BOM, so PS 5.1 reads it correctly.
- **Execution policy:** warns if the policy (ignoring the Process scope) is Restricted or AllSigned, because the profile would then not load.

**Tested against temp profiles:**
- ✅ Running twice leaves exactly one block, with the path updated.
- ✅ Existing oh-my-posh and manual `function ubuntu` lines are preserved. The managed block comes last, so it wins.
- ✅ A path with a space and a `'` is escaped correctly.
- ✅ The resulting profiles parse.

**Docs:** USAGE §4 now covers `-SkipProfileCommand`, and a FAQ entry covers moving the VM to another Windows PC.
