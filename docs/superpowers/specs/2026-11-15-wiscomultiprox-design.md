# wiscomultiprox: one Proxmox VE install stick for several machines (design)

Status: **approved by the owner 2026-11-15; built 2026-11-15** (plan `docs/superpowers/plans/2026-11-15-wiscomultiprox.md`).
`build.sh`, `picker` and both test scripts exist; the VM test passes (see "Proven so far").

## What it is, and why

A build tool. It takes the stock Proxmox VE ISO and a folder with one answer file per machine, and writes **one**
ISO. Written to a USB stick, that ISO boots to a menu with one entry per machine; picking an entry runs Proxmox's
own unattended install with that machine's answer file.

Why: the owner's three nodes are identical laptops. Today every reinstall means building a full ISO for one node and
rewriting the stick. The owner wants one stick for all of them, one stock ISO that is easy to replace at a new release,
and only the per-machine part kept separate.

It is its own public repository (`wiscomultiprox`) because nothing in it is specific to the owner's lab. The lab's
values and secrets stay in `wiscolabx`, which calls the tool.

## Goals

- One stock ISO in, one ISO out, written to a stick with plain `dd`
- A boot menu with one entry per machine
- A wrong pick never touches a disk
- Nothing runs elsewhere during the install: no server, no DHCP, no second stick
- A new Proxmox release: download the stock ISO, run the build again
- No machine values or secrets in the repository

## Not goals

- Legacy (non-UEFI) boot: not tested, not needed by the target machines. The readme says so
- Secure Boot: off on the target machines; not tested with it on
- Products other than Proxmox VE (PBS, PMG use the same installer, untested)
- Writing the stick: the readme gives the commands; the tool never writes to a device

## What would make it a failure even if it "works"

- An install on a machine other than the one picked
- A file of Proxmox's installer replaced or patched (it must survive a new release without merging)
- A machine's MAC, serial number or password hash committed

## How it works

### Inputs

```
nodes/                      # not committed (.gitignore); the user's own folder, any path
  node1.toml        # an ordinary Proxmox answer file
  node1.serial      # optional: one line, the machine's serial number
  node2.toml
  ...
```

The MAC and the disk serial are not given to the tool separately: they are already in each answer file
(`filter.ID_NET_NAME_MAC`, `filter.ID_SERIAL`), where the installer wants them. The file name is the menu name.
The optional `.serial` file holds what `cat /sys/class/dmi/id/product_serial` prints on that machine; with it,
the wrong machine is refused before the installer starts, with a message that names both serials. Without it,
the installer's own filters are the only guard (they are enough: see "Proven so far", test 2).

The repository ships `examples/` with made-up values.

### Build

```
./build.sh --iso proxmox-ve_9.2-1.iso --nodes ./nodes --out multiprox.iso [--first-boot first-boot.sh]
```

1. Checks (each fails with a clear message, nothing written):
   - `proxmox-auto-install-assistant`, `xorriso`, `mke2fs`, `cpio`, `zstd` are there
   - every `nodes/*.toml` passes `validate-answer`; names are `[a-z0-9-]+`; at least one node
   - every answer file has both filters, and neither contains `*`, `?` or `[` (a pattern could match another
     machine); no two nodes share a MAC, a disk serial or a machine serial
   - the stock ISO's own layout is what the method relies on (see "What it relies on")
2. For each node, a 1 MiB ext2 image labelled `proxmox-ais` holding its `answer.toml` (`mke2fs -d`, no root)
3. An overlay archive (cpio, `newc`, owner root) with: `/etc/mdev.conf` (one line), `/multiprox/picker`, and per
   node `/multiprox/<name>.img` and, if given, `/multiprox/<name>.serial`
4. A boot menu: the stock `grub.cfg` with its "Automated" block replaced by one entry per node
5. A copy of the stock ISO, edited in place with `xorriso -dev <copy> -boot_image any keep -map ...` (adds the
   menu as `/boot/grub/grub.cfg` and the overlay as `/boot/multiprox.cpio`). This is how Proxmox's own tool edits
   an ISO; `-boot_image any replay` to a new file fails on this ISO ("GPT partitions 1 and 2 overlap")
6. `proxmox-auto-install-assistant prepare-iso <copy> --fetch-from partition [--on-first-boot ...] --output <out>`.
   This order matters: `prepare-iso` first and the menu second fails ("Overlapping MBR partition entries")
7. Prints the result's path and sha256. Safe to run again; it overwrites the output

A menu entry:

```
menuentry 'Automated Install: node1' ... {
    linux   /boot/linux26 ro ramdisk_size=16777216 rw quiet splash=silent proxmox-start-auto-installer proxmox-multiprox-node=node1
    initrd  /boot/initrd.img /boot/multiprox.cpio
}
```

The menu has **no timeout**, and the highlighted entry is the stock "Install Proxmox VE (Graphical)", which asks
before it does anything. So a stick left in a machine sits at the menu, and a blind Enter starts nothing unattended.
(My call. The owner's rule "never leave a stick in a machine" stays.)

### Boot

1. GRUB loads Proxmox's kernel, Proxmox's initrd, and the overlay after it. The kernel unpacks both into one
   file tree; the overlay only adds files
2. Proxmox's `/init` runs as always. Early on it runs `mdev -s` to create device nodes. busybox `mdev` reads
   `/etc/mdev.conf` (the stock initrd has none), finds our line `loop0 0:0 0660 @/multiprox/picker`, and runs
   the picker once
3. The picker reads `proxmox-multiprox-node=<name>` from the kernel command line. If there is a
   `<name>.serial`, it compares it with `/sys/class/dmi/id/product_serial`; on a difference it prints
   `REFUSED: this machine's serial number is '...'; the entry is for <name> ('...')` and never returns, so the
   installer never starts. Otherwise it attaches `/multiprox/<name>.img` read-only to a free loop device
4. `/init` carries on unchanged and starts the installer. In partition mode it looks for
   `/dev/disk/by-label/proxmox-ais`, finds the loop device, reads the answer file and installs. Its NIC and disk
   filters apply as always
5. Nothing is written to the stick at any point

The picker, as proven (the build uses this, with the names changed from `labx` to `multiprox`; since the review,
`picker` also has `set -f` and trims blanks from the machine's serial, tested by `tests/picker-test.sh`):

```sh
#!/bin/sh
export PATH=/sbin:/bin:/usr/bin:/usr/sbin
[ -e /multiprox/.ran ] && exit 0
: > /multiprox/.ran
stop() {
    echo; echo "[multiprox] REFUSED: $1"
    echo "[multiprox] Nothing was written to any disk. Switch the machine off (hold the power button)."
    while :; do sleep 3600; done
}
node=
for par in $(cat /proc/cmdline); do
    case $par in proxmox-multiprox-node=*) node="${par#proxmox-multiprox-node=}" ;; esac
done
[ -n "$node" ] || stop "no proxmox-multiprox-node= on the kernel command line"
case $node in *[!a-z0-9-]*) stop "bad node name '$node'" ;; esac
[ -f "/multiprox/$node.img" ] || stop "this stick has no answer for '$node'"
if [ -f "/multiprox/$node.serial" ]; then
    want=$(cat "/multiprox/$node.serial"); have=$(cat /sys/class/dmi/id/product_serial)
    [ "$want" = "$have" ] || stop "this machine's serial number is '$have'; the entry is for $node ('$want')"
fi
dev=$(losetup -f) || stop "no free loop device"
losetup -r "$dev" "/multiprox/$node.img" || stop "could not attach the answer image"
echo "[multiprox] $node: its answer file is on $dev"
```

### Why the option is called `proxmox-multiprox-node`

The installer copies every boot option it does not know into the installed system's kernel command line. It
drops the ones matching `proxmox-\S+` (`Proxmox/Install/Config.pm`, `parse_kernel_cmdline`). An option with any
other name would end up on the installed machine for good. The name is not free to choose.

## What it relies on (checked at build time, on the stock ISO)

| Relied on | Check | If a release changes it |
|---|---|---|
| `/init` in the initrd runs `mdev -s` | unpack the initrd, `grep` | build stops |
| the initrd has no `/etc/mdev.conf` of its own | file absent | build stops |
| the initrd's busybox has `losetup` | `sbin/losetup` or the applet list | build stops |
| `grub.cfg` has the block `if [ -f auto-installer-mode.toml ]; then` followed by the Graphical entry | both anchors found once | build stops |
| the installer finds a loop device by label, and drops `proxmox-*` options | the VM test (below), not the build | test fails |

The fallback when a release breaks it: Proxmox's plain `prepare-iso --fetch-from iso` for one node, which
`wiscolabx` does today.

## Approaches

| Approach | Verdict |
|---|---|
| One baked ISO per node, stick rewritten per node (today in `wiscolabx`) | Works, proven on hardware. One node per stick; stays as the fallback |
| Answer on a labelled partition, one file copied per use | One ISO, but no menu; the stick is still for one node at a time |
| Answer over HTTP | No picking at all, but needs DHCP and a server during the install; useless for a rebuild from nothing |
| Ventoy with three baked ISOs | A menu, but three ISOs, a third-party boot loader, and unproven with the automated installer |
| A second small Linux on the stick that copies the answer and reboots | A menu and one ISO, but a second system to maintain and two boots |
| Own script via the kernel option `rdinit=` | Tried 2026-11-15: the install works, the installed system does not boot (the option is carried over, see above) |
| **Own script via the initrd's `mdev` hook, answer on a loop device** | **Chosen (the owner, 2026-11-15).** A menu, one ISO, no installer file replaced, nothing written at boot |

## Proven so far (2026-11-15, node3)

Proxmox VE 9.2-1 (`sha256 4e88fe41...2c6c`), `proxmox-auto-install-assistant` from the node, QEMU/KVM with OVMF
(UEFI), 4 GB, the ISO as a removable USB disk, a 16 GB virtio disk with a set serial, user-mode network. Two test
nodes in the ISO, made-up values.

| # | Test machine | Result |
|---|---|---|
| 1 | serial number differs from the entry's | picker: `REFUSED: this machine's serial number is 'WRONGSERIAL'; the entry is for spike1 ('SPIKESERIAL1')`. Disk: all 16 GB still zero |
| 2 | serial matches, disk serial differs | picker passes; installer: `Found answer file on partition`, then `Installation failed: filter did not match any devices`. Disk: all zero |
| 3 | everything matches | installed unattended in about 2 minutes. Booted from disk: `spike1.example.org`, `10.0.2.15/24` on `vmbr0`, pool healthy, first-boot script ran, `/etc/kernel/cmdline` holds no `multiprox` option |

Test-only differences from the real thing: `console=ttyS0` on the entries (to read the screen), a 5 second menu
timeout, and the names (`labx` where the design says `multiprox`).

**The tool, 2026-11-15** (`tests/vm-test.sh`, the same setup, made-up machines `vm1` with a `.serial`, `vm2`
without):

| # | Result | Test machine and what happened |
|---|---|---|
| 1 | ok | vm1 entry, serial WRONG: picker refuses, disk untouched |
| 2 | ok | vm1 entry, wrong disk serial: installer's filter refuses, disk untouched |
| 3 | ok | vm1 entry, wrong MAC: installer's filter refuses, disk untouched |
| 4 | ok | vm2 entry (no serial file), wrong disk: no early check, installer's filter refuses, disk untouched |
| 5 | ok | vm1 entry, vm1's machine: installs unattended and reboots (118 s, QEMU exit 0) |
| 6 | ok | boots from disk: vm1.example.org, 10.0.2.15/24, pool healthy, first-boot ran, no multiprox option left |

Found while building: the installer words a network-card mismatch "filter did not match any device" (a disk: "any
devices"); `validate-answer` and `prepare-iso` both exit 0 on errors, so the build reads their output. The ISO was
also written to a real USB stick with `dd` and checked with `cmp`.

**Not tested:** real hardware (booting a real stick); legacy BIOS boot; Secure Boot on. (Picking the second entry and a MAC-only mismatch are now covered: tests 4 and 3.)

## Repository layout

```
build.sh                 # the tool (bash, set -euo pipefail, two-space indent, double quotes, lowercase names)
picker                   # the script that goes into the overlay
examples/                # node1.toml, node1.serial, first-boot.sh: made-up values
tests/vm-test.sh         # the three tests above, automated (needs KVM and root); prints a table
tests/build-test.sh      # the build's checks: bad name, wildcard in a filter, duplicate serial, missing tool...
readme.md                # what it is, prerequisites, gathering the values, build, write the stick, a new release,
                         # test results, what is not tested, how it works and what it relies on
.gitignore               # nodes/, out/, *.iso
LICENSE                  # MIT (my call)
docs/superpowers/specs/  # this file
```

Readme conventions (the owner's, from the request): every command shown is prefixed with `# 🟢 [read-only]`,
`# 🔴 [!! makes changes !!]` or `# 🔴 [!! DESTRUCTIVE !!]`; a bold warning line before any block that changes or
destroys; the stick is always named by `/dev/disk/by-id/...` and the reader is told to check it first.

Build host: Debian with the Proxmox repository, or any Proxmox node (the tool is a Proxmox package).

## What changes in `wiscolabx` (later, in its own session, after the session working there is done)

- `tofu/github`: the repository `wiscomultiprox`, public (plan, the owner's yes, apply from `admin`)
- `host_vars/<node>.yml`: a new `host_serial` (the laptop serials are in `bootstrap.md`'s table)
- `install-media.yml`: also writes every `pve` host's answer file and serial into one `nodes/` folder
- How a node gets the tool: checked out next to `wiscolabx` by the existing `claude_code_repos` list (my call;
  the plan decides whether a commit is pinned)
- `docs/install.md`, `docs/bootstrap.md`: one stick for every node; "Open: one stick for every node" closed
  with a pointer here; the "not through Ventoy" sentences stay true
- The third-node plan, Task 10 Step 3: the stick is the multi-node ISO; Step 4: the owner picks "node1"
- A first check on real hardware that cannot hurt: boot the stick on a machine that is **not** in it (the
  player, the owner's laptop) and pick any entry: it must refuse. That proves the stick boots on real UEFI hardware
  before it is used on node1

## Left to the builder

- Argument parsing and messages of `build.sh`
- How `tests/vm-test.sh` reads the result (serial console as in the spike, or screenshots)
- Whether the answer images are ext2 (proven) or FAT
- The exact readme wording
