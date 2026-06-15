# void-wsl2-installer

The easiest Void Linux installer for Windows WSL2.

One-shot installer for [Void Linux](https://voidlinux.org/) on WSL2.

Void is an independent rolling-release distribution with the
[XBPS](https://docs.voidlinux.org/xbps/) package manager and the
[runit](http://smarden.org/runit/) init system. It's not in the Microsoft
Store. This script automates the whole "download rootfs, `wsl --import`,
configure the in-distro side" flow so you can be in a working Void shell
in about 90 seconds.

## Quick start (easiest path)

**On a Windows 11 machine**:

1. Download this repo as a ZIP from GitHub
   ([direct link](https://github.com/t3m3d/void-wsl2-installer/archive/refs/heads/main.zip))
   and extract it anywhere.
2. **Double-click `run.cmd`** in the extracted folder.
3. Watch the PowerShell window. When it says "Void installed and ready",
   you're done.
4. Open a regular PowerShell and run: `wsl -d Void`

`run.cmd` handles the two friction points that bite first-time users:
PowerShell blocks unsigned `.ps1` files by default, and double-clicking
a `.ps1` opens Notepad instead of running it. `run.cmd` runs `install.ps1`
through PowerShell with the right flags, in a window that stays open so
you can read the output.

If WSL2 isn't installed yet on the machine, the script will detect that,
ask permission, and run `wsl --install` for you (with a UAC prompt). After
that you may need to **reboot once** and re-run.

If you prefer the terminal path, scroll to [Usage](#usage) below.

## What it does

1. Verifies WSL2 is installed
2. Reads `sha256sum.txt` from
   [`repo-default.voidlinux.org/live/current`](https://repo-default.voidlinux.org/live/current/)
   to discover the current ROOTFS filename + hash (so the installer
   tracks upstream automatically; no hard-coded date)
3. Downloads the `void-x86_64-ROOTFS-<date>.tar.xz` (~120 MB) — or the
   musl variant if you pass `-Libc musl`
4. Verifies the SHA256 against the upstream entry
5. `wsl --import` to register the distro
6. Inside the new distro:
   - writes `/etc/wsl.conf` with sensible defaults (`appendWindowsPath=false`
     and `noexec` on `/mnt/c` — see [Hardening](#hardening) below)
   - creates `/etc/hostname`, sets timezone
   - creates a non-root user in the `wheel` group with sudo enabled
   - runs `xbps-install -Sy xbps`, then `xbps-install -Syu` (full system
     update), then installs `sudo` and `nano`
7. Bounces WSL so the default-user setting takes effect
8. Smoke-tests with `whoami` + `xbps-query --version` + `uname -r`

Re-running the script later reuses the cached tarball if its SHA still
matches upstream — re-installs after the first run finish in seconds
instead of re-downloading.

## Hardening

The installer bakes `/mnt/c noexec` + `appendWindowsPath=false` into
`/etc/wsl.conf`. Net effect inside the new Void install:

- Linux PATH does **not** absorb your Windows `PATH`. Typing `kcc` finds
  the Linux native install, never some stray `C:\...\kcc.exe`.
- `/mnt/c/...whatever.exe` can be **read and listed** but **cannot be
  executed** from inside WSL. Prevents accidentally running a Windows
  binary when you meant the Linux native version, and shrinks the
  blast-radius if a script does something stupid in `/mnt/c`.
- `explorer.exe .` / `code .` / `cmd.exe` still work when you explicitly
  cross the boundary (since `[interop] enabled=true`).

If you don't want this for your use case, edit `/etc/wsl.conf` after
install and run `wsl --shutdown` to apply.

## Usage

The double-click path is `run.cmd`. From a terminal you'd run:

```powershell
.\install.ps1
```

Useful parameters:

| Parameter | Default | Notes |
| --- | --- | --- |
| `-DistroName` | `Void` | Name `wsl --list` will show. |
| `-InstallPath` | `C:\WSL\void` | Where the distro's `ext4.vhdx` lives. Pick a non-system drive (e.g. `D:\WSL\void`) if you don't want it ballooning your `C:`. |
| `-DownloadDir` | `C:\WSL\downloads` | Stage tarball cache. Re-runs reuse the cached file if its SHA matches upstream. |
| `-Username` | your Windows username, lower-cased | The Linux user the installer creates. Overridable here or at the interactive prompt. |
| `-Hostname` | `<computer>-void` | Written to `/etc/hostname`. |
| `-Timezone` | `America/New_York` | Symlinks `/etc/localtime`. |
| `-Libc` | `glibc` | Pass `musl` for the musl variant. |
| `-RootfsBase` | upstream | Mirror URL. Default is `https://repo-default.voidlinux.org/live/current`. |
| `-Force` | off | Skip the "InstallPath isn't empty" guard and the "already registered" prompt. |

Example: install the musl variant to a non-system drive, named differently:

```powershell
.\install.ps1 -Libc musl -DistroName VoidMusl -InstallPath D:\WSL\voidmusl
```

## After install

The installer creates one user (the one you set during the run), in the
`wheel` group with sudo enabled. `sudo` and `nano` are installed. Updates:

```sh
sudo xbps-install -Syu       # update everything
sudo xbps-install <pkg>      # install
sudo xbps-remove <pkg>       # remove
xbps-query -Rs <term>        # search
```

WSL2's `ext4.vhdx` grows but never shrinks. Heavy package installs can
fill your system drive over time. To reclaim space (Windows side, admin):

```powershell
wsl --shutdown
diskpart
  select vdisk file="C:\WSL\void\ext4.vhdx"
  attach vdisk readonly
  compact vdisk
  detach vdisk
```

Or move the distro off the system drive entirely:

```powershell
wsl --export Void D:\wsl\void.tar
wsl --unregister Void
wsl --import Void D:\wsl\void D:\wsl\void.tar --version 2
```

## Tested on

- Windows 11 24H2, WSL 2.7.x
- glibc ROOTFS (default); musl path follows the same code path with
  `-Libc musl`

## License

MIT.
