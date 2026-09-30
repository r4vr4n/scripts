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

