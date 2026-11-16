# wiscomultiprox

One Proxmox VE install stick for several machines. `build.sh` takes the stock Proxmox VE ISO and a folder with one
[answer file](https://pve.proxmox.com/wiki/Automated_Installation) per machine, and writes one ISO. Written to a
USB stick, it boots to a menu with an unattended-install entry per machine, next to Proxmox's own entries:

```
Leave the stick: boot from the local disk    <- highlighted; after 90 s with no key it is started
Automated Install: node1
Automated Install: node2
Install Proxmox VE (Graphical)
Install Proxmox VE (Terminal UI)
...
Advanced Options
```

GRUB counts down at the bottom of the menu ("The highlighted entry will be executed automatically in 90s").
Any key (an arrow key, say) stops the countdown; then the menu waits for ever.

## What it does to a machine

**Picking a machine's entry wipes that machine's disk and installs Proxmox VE on it, without asking.** That is the
point of an unattended install. Any other machine is refused before a disk is touched:

- the machine's serial number is not the entry's (if you gave one: `<name>.serial`): refused at once, with both
  serial numbers on the screen
- the network card or the disk is not the one in the answer file: Proxmox's installer refuses
  (`filter did not match any device` for the network card, `...any devices` for the disk)

Leaving the stick in a machine is safe: after 90 seconds with no key pressed the menu starts its first entry,
"Leave the stick", which starts the local disk's boot loader. So a node that reboots with the stick still in comes
back up from its disk, 90 s late. The timeout never starts an install entry. Pull the stick anyway once the
install is done.

How it works: that entry looks on every disk except the stick (the disk GRUB booted from, and any disk with
Proxmox's `/.pve-cd-id.txt`) for a UEFI boot loader at, in this order, `\EFI\BOOT\BOOTX64.EFI` (the
removable-media default, which most installs also write), `\EFI\systemd\systemd-bootx64.efi` (Proxmox VE on ZFS
without Secure Boot, the nodes here) and `\EFI\proxmox\grubx64.efi` (Proxmox VE with GRUB), in GPT or MBR
partitions 1 to 8 of disks `hd0` to `hd15`. It starts the first it finds (GRUB `chainloader`; the screen says
`multiprox: leaving the stick for (hdN,gptM)/EFI/...`). If no disk has one, it says so and runs GRUB's `exit`:
the firmware's own boot menu, or its next boot device. Nothing installs either way.

Why not just GRUB's `exit`, which would let the firmware pick its next device in `BootOrder`: GRUB 2.12's `exit`
(`exit 1` too) returns `EFI_SUCCESS`, and when a boot loader returns that, the UEFI spec (3.1.1) has the firmware
stop going down `BootOrder` and show its boot menu. OVMF does exactly that (tested; an EFI program that returns an
error status does fall through to the next device). Firmware that follows the spec would stop at its menu, with
the node down. The price of chainloading: the stick picks the disk (the first with a loader at those paths), not
the firmware's `BootOrder`; with one system disk, as on the nodes, that is the same disk.

`--timeout <seconds>` sets the time (10 to 3600; default 90); `--timeout off` turns it off (the menu waits for
ever, with the Graphical installer highlighted, as before). On legacy BIOS (not tested) there is no timeout either
way: the menu waits, Graphical highlighted, and the "Leave the stick" entry is not shown (it is UEFI only).
Secure Boot on is not tested: the chainloaded loader must then pass shim's check.

## What you need

- A build host: Debian with the Proxmox VE repository, or any Proxmox VE node. The tools:
  `proxmox-auto-install-assistant`, `xorriso`, `e2fsprogs` (`mke2fs`), `cpio`, `zstd`, `python3` (3.11 or later).
  No root
- About twice the ISO's size free beside the output file (3.5 GB for 9.2-1)
- The stock ISO from <https://www.proxmox.com/en/downloads>, checked against its sha256 there
- Machines that boot UEFI. Legacy BIOS and Secure Boot are **not tested** (see "Tested")

**The next command installs packages.**

```
# 🔴 [!! makes changes !!] installs the tools (on a Proxmox VE node most are there already)
sudo apt install proxmox-auto-install-assistant xorriso e2fsprogs cpio zstd python3
```

## Gathering a machine's values

Each answer file names its machine's network card and disk exactly. On the machine (an installed Proxmox VE, or
any Linux live system):

```
# 🟢 [read-only] on Proxmox VE: what the installer sees
proxmox-auto-install-assistant device-info -t network    # the card's ID_NET_NAME_MAC, e.g. enx525400123456
proxmox-auto-install-assistant device-info -t disk       # the disk's ID_SERIAL
# 🟢 [read-only] on any Linux: the same values
ip -br link                                              # MAC 52:54:00:12:34:56 -> enx525400123456
udevadm info --query=property /dev/nvme0n1 | grep '^ID_SERIAL='
# 🟢 [read-only] the machine's serial number, for <name>.serial
sudo cat /sys/class/dmi/id/product_serial
```

## The nodes folder

One `<name>.toml` per machine; the name (lowercase letters, digits, `-`, at most 40) becomes the menu entry. Start from
`examples/` (made-up values) and keep your folder **outside** this repository, or as `nodes/` (ignored by git).

- `<name>.toml`: an ordinary Proxmox answer file. It must have `filter.ID_NET_NAME_MAC` under `[network]` and
  `filter.ID_SERIAL` under `[disk-setup]`, each the exact value (no `*`, `?`, `[`: a pattern could match another
  machine), and no other filter or `disk-list` (another key, such as `ID_MODEL = "Samsung*"`, could match another
  machine too). For `--first-boot`, add `[first-boot]` with `source = "from-iso"`
- `<name>.serial` (optional, recommended): one line, the machine's serial number, as plain ASCII text. Blanks
  and Windows line ends are trimmed; a BOM or UTF-16 (what PowerShell 5.1's `>` writes) is refused. So is a placeholder
  such as `To Be Filled By O.E.M.` or `Default string` (the same on many machines: delete the file instead) Without it, the installer's own filters are the only guard (they hold: see "Tested", test 4)
- Anything else in the folder is ignored, and named in a note; except near misses such as `node1.serial.txt` or
  `node1.SERIAL`, which are refused (they would silently drop a check)

**The next commands create a folder and copy files into it.**

```
# 🔴 [!! makes changes !!] a nodes folder from the examples, outside the repository
mkdir -p ~/multiprox-nodes
cp examples/node1.toml examples/node1.serial ~/multiprox-nodes/
# then edit ~/multiprox-nodes/node1.toml: fqdn, network, filters, root-password-hashed, root-ssh-keys
```

```
# 🟢 [read-only] prints a password hash for root-password-hashed (asks for the password)
openssl passwd -6
```

## Build

```
# 🟢 [read-only] the options
./build.sh --help
```

**The next command writes (or overwrites) the output ISO.** Its checks run first; any error stops it before
anything is written.

```
# 🔴 [!! makes changes !!] writes (or overwrites) the output ISO
./build.sh --iso proxmox-ve_9.2-1.iso --nodes ~/multiprox-nodes --out multiprox.iso --first-boot examples/first-boot.sh
```

`--timeout <seconds>` (10 to 3600, or `off`; default 90): how long the menu waits for a key before it leaves the
stick for the next boot device (see "What it does to a machine").

It ends with `build.sh: wrote multiprox.iso` and `build.sh: sha256 <hash>`. Every error is one line starting
`build.sh:`, and nothing is left at `--out`. Exit codes: `2` usage or a missing input, `3` a missing tool, `4` a bad
nodes folder, `5` the ISO is not what the method relies on (a new release: see below), `1` a tool failed.
`--out` may not be inside the nodes folder (the tool never writes there). A build that was killed leaves a
`.multiprox-build.*` folder beside `--out`; the next build names it, and you delete it. `--first-boot` is optional: a script (at most 1 MiB) the installed machine runs once at its first boot.
A bad `--timeout` (not 10 to 3600, nor `off`) is a usage error (`2`).

The variable `MULTIPROX_TEST_AUTOBOOT=<name>` is for `tests/vm-test.sh` only: it makes an ISO that **starts that
machine's install by itself after 3 seconds**. Never write such an ISO to a stick. The build says `TEST BUILD`
when it is set.

## Writing the stick

Name the stick by `/dev/disk/by-id/`, never by `/dev/sdX` (those letters change), and check it right before writing.

```
# 🟢 [read-only] plug the stick in, then find it: the usb-... line without -partN
ls -l /dev/disk/by-id/ | grep usb
```

```
# 🟢 [read-only] put YOUR stick's id here, then check it is the stick (size, model) and not mounted
STICK=/dev/disk/by-id/usb-REPLACE-WITH-YOUR-STICK
lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINTS "$STICK"
```

`$STICK` must be set in the same shell as the `dd` below; if it is not (a new terminal), `dd` does nothing.

If a partition of it shows a mount point, unmount it. **The next command unmounts a file system.**

```
# 🔴 [!! makes changes !!] unmounts one partition of the stick (repeat for each mount point lsblk showed)
sudo umount /media/REPLACE-WITH-THE-MOUNT-POINT
```

**The next command erases everything on `$STICK`. Check the `lsblk` output above first.**

```
# 🔴 [!! DESTRUCTIVE !!] writes the ISO over the whole stick
[ -b "$STICK" ] && sudo dd if=multiprox.iso of="$STICK" bs=4M conv=fsync oflag=direct status=progress
```

```
# 🟢 [read-only] the stick holds the ISO, byte for byte
sudo cmp -n "$(stat -c %s multiprox.iso)" multiprox.iso "$STICK" && echo "the stick matches"
```

## Installing

1. A first check with a new stick: boot it on a machine that is **not** in it and pick any machine's entry. It
   must refuse (serial number), or the installer must stop at `filter did not match any device(s)`. Switch that
   machine off. This relies on the very guards it checks, and booting on real hardware is not tested yet (see
   "Tested"): **use a machine whose disks hold nothing that matters**
2. On the machine: boot from the stick (UEFI boot menu, often F12), press an arrow key within 90 s (that stops
   the countdown), pick its entry
3. The install runs by itself (a few minutes) and reboots. Pull the stick at the reboot. If you miss it, the menu
   leaves the stick after 90 s and the machine boots its new install from the disk

If the machine is refused, the screen says why. Nothing was written; switch it off (hold the power button).

## A new Proxmox VE release

**The next command downloads the new stock ISO.**

```
# 🔴 [!! makes changes !!] download the new stock ISO
curl -fLO https://enterprise.proxmox.com/iso/proxmox-ve_<version>.iso
```

```
# 🟢 [read-only] compare with the sha256 on the downloads page; stop if it differs
sha256sum proxmox-ve_<version>.iso
```

**The next commands write an ISO, and temporary files for the VM test.**

```
# 🔴 [!! makes changes !!] build from the new release
./build.sh --iso proxmox-ve_<version>.iso --nodes ~/multiprox-nodes --out multiprox.iso
# 🔴 [!! makes changes !!] the VM test against the new release (temp files, removed at the end)
MULTIPROX_TEST_ISO=proxmox-ve_<version>.iso tests/vm-test.sh
```

If the build stops with exit `5`, or a VM test fails, the release changed something the method relies on (below).
The fallback is Proxmox's own ISO for one machine. **The next command writes an ISO.**

```
# 🔴 [!! makes changes !!] a one-machine ISO with the answer file inside (Proxmox's own method)
proxmox-auto-install-assistant prepare-iso proxmox-ve_<version>.iso --fetch-from iso --answer-file ~/multiprox-nodes/<name>.toml
```

## How it works

The build:

1. Checks the tools, the nodes folder (names, `validate-answer`, exact filters, no two machines with the same MAC,
   disk serial or serial number) and the stock ISO
2. Makes, per machine, a 1 MiB ext2 image labelled `proxmox-ais` holding its `answer.toml`
3. Packs an overlay (cpio): `/etc/mdev.conf` (one line), `/multiprox/picker`, the images and the serials
4. Replaces the stock menu's "Automated" block with the "Leave the stick" entry (UEFI only: `chainloader` to the
   local disk's boot loader), the
   timeout (UEFI: `--timeout` seconds, default that entry; BIOS: none, default Graphical) and one entry per
   machine; each loads Proxmox's own initrd and the overlay after it, with the kernel option
   `proxmox-multiprox-node=<name>`
5. Adds the menu and the overlay to a copy of the ISO (`xorriso -dev <copy> -boot_image any keep -map ...`), then
   runs `proxmox-auto-install-assistant prepare-iso <copy> --fetch-from partition` on it. This order matters:
   `prepare-iso` first fails ("Overlapping MBR partition entries"), and `-boot_image any replay` to a new file
   fails ("GPT partitions 1 and 2 overlap")

At boot: the kernel unpacks Proxmox's initrd and the overlay into one tree (the overlay only adds files).
Proxmox's `/init` runs busybox `mdev -s`, which reads the overlay's `/etc/mdev.conf` and runs the picker once. The
picker reads the machine's name from the kernel command line, compares the serial number if the stick has one, and
attaches that machine's image read-only to a loop device. The installer, in partition mode, finds the label
`proxmox-ais` on it and installs with that answer file and its filters. Nothing is written to the stick.

The option is called `proxmox-...` on purpose: the installer copies unknown boot options into the installed
system's kernel command line, except those matching `proxmox-*`.

### What it relies on

| Relied on | Checked |
|---|---|
| The initrd's `/init` runs `mdev -s`; the initrd has no `/etc/mdev.conf`; its busybox has `losetup` | by the build (exit 5) |
| `grub.cfg` has the block `if [ -f auto-installer-mode.toml ]; then` (holding only the Automated entry), then the Graphical entry, each once | by the build (exit 5) |
| The installer finds an answer on a loop device by label, and drops `proxmox-*` options | by the VM test |
| `validate-answer` and `prepare-iso` print `Error` on failure (both exit 0 even then, in 9.2-1) | by the build |
| The local disk has a UEFI boot loader at one of the three paths; the stick's GRUB has `chain`, `regexp`, `fat`, `part_gpt` | by the VM test (a Proxmox VE install on ZFS, OVMF); real hardware: by hand (see "Tested") |

## Tested

Proxmox VE 9.2-1, `tests/vm-test.sh` on a Proxmox VE node: QEMU/KVM, UEFI (OVMF), the ISO as a USB stick, a 16 GB
disk with a set serial, user-mode network.

| # | Result | Test machine and what happened |
|---|---|---|
| 1 | ok | vm1 entry, serial WRONG: picker refuses, disk untouched |
| 2 | ok | vm1 entry, wrong disk serial: installer's filter refuses, disk untouched |
| 3 | ok | vm1 entry, wrong MAC: installer's filter refuses, disk untouched |
| 4 | ok | vm2 entry (no serial file), wrong disk: no early check, installer's filter refuses, disk untouched |
| 5 | ok | vm1 entry, vm1's machine: installs unattended and reboots (118 s, QEMU exit 0) |
| 6 | ok | boots from disk: vm1.example.org, 10.0.2.15/24, pool healthy, first-boot ran, no multiprox option left |
| 7 | ok | the real stick (default 90 s) left in, first in the boot order: menu waits, then vm1 boots from its disk (SSH after 103 s) |
| 8 | ok | 10 s stick left in, blank disk: no loader found, the firmware's boot menu, nothing installed, disk untouched |

Tests 1 to 4: "disk untouched" means all 16 GB still read as zeros. Test 6 boots the installed disk with the
stick removed and checks over SSH. Test 7 boots an ordinary build (no test option) with the stick first in the
firmware's boot order and no key pressed: GRUB's menu shows on the serial console, it chainloads the disk's
loader, no installer starts, and the installed vm1 answers over SSH no sooner than 90 s after power-on. Test 8 is
the same with a blank disk.

Also done: the built ISO written to a real USB stick with the `dd` above, and `cmp` says it matches.

**On real hardware:** the timeout's hand-over to the disk did **not** work on the first try, on an HP laptop
with Ubuntu (2026-11-15; cause not found yet). Nothing was installed.

**Not tested:** the install entries on real hardware; legacy BIOS boot; Secure Boot on; products other than Proxmox VE.

### Checking the timeout on real hardware

On a machine that already boots from its disk (a node), with the stick written as above:

1. Plug the stick in and switch the machine on; pick the stick from the firmware's one-time boot menu (often F12),
   or, closer to the case this guards against, put the stick first in the firmware's boot order
2. The multiprox menu shows with "Leave the stick" highlighted and a countdown from 90 s at the bottom. Touch
   nothing
3. At 0 the screen shows `multiprox: leaving the stick for (hdN,gpt2)/EFI/...`, then the machine boots from its
   disk as usual: the node's own boot menu (systemd-boot, on the nodes here), then its login prompt. Nothing was
   installed: the machine is as before
4. Pass: the node is up from its disk (`ssh tech@<node>`, then `uptime`: it shows the fresh boot). Not a pass,
   and worth writing down with what the screen said: `multiprox: no other disk has a UEFI boot loader` followed
   by the firmware's boot menu (the disk's loader is somewhere else; nothing was installed, choose the disk by
   hand); an error after `leaving the stick for` (the loader would not start: Secure Boot?)
5. Pull the stick. If you changed the boot order in step 1, put it back

## The tests

**The next commands write temporary files (and start QEMU, for the VM test).**

```
# 🔴 [!! makes changes !!] temp files only (MULTIPROX_TEST_TMP, default /var/tmp), removed at the end
MULTIPROX_TEST_ISO=proxmox-ve_9.2-1.iso tests/build-test.sh     # the checks and the build: under a minute, 4 GB free
MULTIPROX_TEST_ISO=proxmox-ve_9.2-1.iso tests/picker-test.sh    # the picker in the initrd's busybox: seconds
MULTIPROX_TEST_ISO=proxmox-ve_9.2-1.iso tests/vm-test.sh        # boots test machines: about 15 min, 8 GB free
```

`MULTIPROX_VM_TESTS` runs some VM tests only, e.g. `MULTIPROX_VM_TESTS="7 8"` for the menu's timeout (about
6 min). Tests 6 and 7 boot the disk test 5 installs, so asking for either brings 5 along. For a change to the
menu alone, `build-test.sh` (it checks the generated `grub.cfg`) and then the VM tests it touches are enough; run
them all before a release.

`picker-test.sh` runs the picker in a chroot of the stock initrd as an unprivileged user namespace (`unshare -r`):
no root, no VM. `vm-test.sh` needs KVM, OVMF (`/usr/share/pve-edk2-firmware`, or set `MULTIPROX_OVMF_DIR`) and `sudo -n kvm`
(passwordless sudo for QEMU). It prints a table and exits 0 only if every test passed; a failure shows the end of
that machine's serial console.

## Secrets

The ISO, and so the stick, hold every answer file: root password hashes, SSH keys, addresses. Keep the stick like
a key. Never commit a nodes folder or an ISO (`.gitignore` has `nodes/`, `out/`, `*.iso`).

## Licence

MIT, see [LICENSE](LICENSE).
