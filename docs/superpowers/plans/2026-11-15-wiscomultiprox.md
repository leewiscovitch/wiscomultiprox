# wiscomultiprox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `build.sh` turns the stock Proxmox VE ISO plus a folder of answer files into one ISO whose boot menu has
an unattended-install entry per machine, proven by an automated VM test.

**Architecture:** one bash script (`build.sh`) that checks its inputs, makes a small overlay archive (a picker
script, an `mdev.conf` line, one tiny answer image per node), adds the overlay and a menu to a copy of the stock
ISO, and hands the copy to Proxmox's own `prepare-iso` in partition mode. Nothing of the installer is replaced.
Two test scripts: one for the build's checks and output (no VM), one that boots the result in QEMU.

**Tech Stack:** bash, `proxmox-auto-install-assistant`, `xorriso`, `mke2fs`, `cpio`, `zstd`, `python3` (stdlib
`tomllib`, to read the answer files), QEMU/KVM with OVMF for the VM test. Proxmox VE 9.2-1 ISO.

**Spec:** `docs/superpowers/specs/2026-11-15-wiscomultiprox-design.md` (approved by the owner 2026-11-15). Read it first.
The spike's scripts, which worked, are in `docs/spike-2026-11-15/` (`picker`, `mdev.conf`, `grub.cfg`, `run.sh`):
start from them, with `labx` renamed to `multiprox`.

**Where:** this repo exists only on node3 (a local checkout, no remote yet:
see "After this plan"). Every task runs there. Commit after every task; there is nothing to push to yet.
The stock ISO is not in the repo: download it once to a path outside the repo and give it to the tests as
`MULTIPROX_TEST_ISO` (URL and sha256 in the spec).

## Status notes

- **2026-11-15, Tasks 1–4 done** in one session on node3 (model opus). `tests/build-test.sh` 42 passed, `tests/picker-test.sh` 7 passed,
  `tests/vm-test.sh` 6 passed (table in the spec, "Proven so far", and in the readme)
- Differences from the plan, each decided on the way: `validate-answer` and `prepare-iso` exit 0 on errors (the
  build reads their output); the "ID_SERIAL missing" case uses another disk filter (`validate-answer` already
  refuses none at all); the initrd is checked by listing it, not unpacking it; test 3 matches the installer's
  real NIC wording ("any device"); an older `--out` is removed once the checks pass; refusal tests stop QEMU as
  soon as the expected lines are in the log
- The built example ISO was written to a real USB stick (an Intel Optane in a Realtek USB case, on node3)
  with the readme's `dd` and checked with `cmp`. Not booted on hardware yet
- Final review (a fresh reviewer, model fable): no Critical; four Important fixed with tests (only the one exact
  filter per table, no `disk-list`; a `.serial` must be plain ASCII; near-miss names like `node1.serial.txt`
  refused; the readme's first hardware check no longer called harmless). The 13 minors were then fixed too (the owner asked), each with a test that
  failed first where it is code: the picker has `set -f` (a `nod*` on the command line had picked node2) and
  trims the machine's serial; placeholder serials refused; the automated block must hold only the stock entry;
  entries chosen by `--id` (`multiprox-graphical` by default); Python without `tomllib` is exit 3; `--out` may
  not be the `--first-boot` script (it was deleted), inside the nodes folder, or end in `/`; a stopped build's
  work folder is named; titles are `Automated Install: <name>` (the owner; the theme cuts titles at about 60 characters, so names are at most 40); readme prefixes, the fallback command, a `$STICK`
  guard. New `tests/picker-test.sh` (7 cases, the picker in the stock initrd's busybox); build-test 42 cases
- Next: "After this plan", in `wiscolabx`, a fresh session, model `fable`

## Global Constraints

- **Nothing of wiscolabx is touched by this plan.** No file there, no tofu, no playbook
- Kernel option: exactly `proxmox-multiprox-node=<name>` (the installer drops `proxmox-*`; any other name ends up
  on the installed machine). Overlay paths: `/etc/mdev.conf`, `/multiprox/picker`, `/multiprox/<name>.img`,
  `/multiprox/<name>.serial`. In the ISO: `/boot/multiprox.cpio`, `/boot/grub/grub.cfg`. Label: `proxmox-ais`
- `mdev.conf` is exactly one line: `loop0 0:0 0660 @/multiprox/picker`
- Build order: copy the stock ISO → `xorriso -dev <copy> -boot_image any keep -map ...` → `prepare-iso <copy>
  --fetch-from partition`. Never `-boot_image any replay`, never `prepare-iso` first (both fail, see the spec)
- The real menu has **no timeout** and its default is the stock "Install Proxmox VE (Graphical)" entry
- Node names: `[a-z0-9-]+`. No `*`, `?`, `[` in `filter.ID_NET_NAME_MAC` or `filter.ID_SERIAL`
- The tool never writes to a device, never needs root, and never writes inside `--nodes`
- No machine value, hash or ISO is committed: `.gitignore` has `nodes/`, `out/`, `*.iso`; `examples/` holds
  made-up values only (MAC `52:54:00:...`, serials starting `EXAMPLE`)
- Bash style: `set -euo pipefail`, two-space indent, double quotes, lowercase names. `shellcheck` clean if it is
  installed (not required)
- Every error is one line starting `build.sh: `, on stderr, with the exit code of its class:
  `2` usage or a missing input, `3` a missing tool, `4` a bad nodes folder, `5` the ISO is not what the method
  relies on, `1` a tool that failed. Nothing is left at `--out` after an error
- Readme commands carry the prefixes `# 🟢 [read-only]`, `# 🔴 [!! makes changes !!]`,
  `# 🔴 [!! DESTRUCTIVE !!]`, with a bold warning line before any block of the last two kinds
- Legacy BIOS and Secure Boot are not tested and the readme says so

## Review Focus

1. **A `.serial` file edited on Windows** (CRLF, trailing blanks, an empty file). Expected: blanks and CR are
   trimmed at build time; an empty one is refused (exit 4) and names the file. Test in Task 1
2. **An ISO that was already prepared** (it has `/auto-installer-mode.toml`) or is not a Proxmox ISO at all.
   Expected: exit 5, "give the stock ISO". Test in Task 1
3. **`--out` that is the stock ISO itself, or a device** (`/dev/...`). Expected: exit 2 before anything is
   written. Test in Task 1
4. **Paths with a space** (`--nodes "./my nodes"`). Expected: works. Test in Task 2
5. **Stray content in the nodes folder**: a `.serial` with no `.toml` of that name is refused (exit 4: a typo
   there would silently drop the early check); any other file is ignored and named in a note. Test in Task 1

---

### Task 1: `build.sh`: arguments and every check

**Model:** sonnet

**Files:**
- Create: `build.sh` (0755), `tests/build-test.sh` (0755), `tests/lib.sh`, `examples/node1.toml`,
  `examples/node1.serial`, `examples/node2.toml`, `examples/first-boot.sh`

**Interfaces:**
- Produces: `./build.sh --iso <stock.iso> --nodes <dir> --out <file.iso> [--first-boot <script>]`; `-h|--help`
  prints usage, exit 0. Exit codes and message form as in Global Constraints. After the checks pass it prints
  `build.sh: checks passed (<n> node(s): <names in sorted order>)` on stdout, and in this task then exits 0
  **without building** (Task 2 replaces that exit with the build)
- Produces for tests (`tests/lib.sh`): `check <description> <expected exit code> <grep pattern for stderr+stdout>
  -- <command...>` prints `ok`/`FAIL` per case and counts; `finish` exits 1 if any failed. `need_iso` stops the
  script with exit 2 and `set MULTIPROX_TEST_ISO to the stock ISO's path` when the variable is unset or not a file

- [x] **Step 1: Examples.** `examples/node1.toml` and `node2.toml`: complete answer files that pass
  `proxmox-auto-install-assistant validate-answer` (model: `docs/spike-2026-11-15/spike1.toml`, with
  `[first-boot] source = "from-iso"`, `ordering = "before-network"`), fqdn `node1.example.org` / `node2...`,
  MACs `enx525400aabb01` / `...02`, disk serials `EXAMPLEDISK01` / `...02`, a root password hash made with
  `openssl passwd -6 example` and one made-up `ssh-ed25519` key line. `examples/node1.serial`: `EXAMPLESERIAL1`.
  `node2` has no `.serial` on purpose. `examples/first-boot.sh`: writes `date -u` to `/root/multiprox-first-boot-ran`
- [x] **Step 2: The failing tests**, `tests/build-test.sh` (uses `need_iso`; each case copies `examples/` to a temp
  folder and breaks one thing). Cases, with the expected exit code and a word the message must contain:

  | Case | Exit | Message contains |
  |---|---|---|
  | no arguments | 2 | `usage` |
  | `--iso` not a file | 2 | the path |
  | `--nodes` empty folder | 4 | `no node` |
  | `Node1.toml` (capital) | 4 | `Node1` |
  | an answer file that fails `validate-answer` | 4 | the file name |
  | `filter.ID_SERIAL` missing | 4 | `ID_SERIAL` |
  | `filter.ID_NET_NAME_MAC = "enx5254*"` | 4 | `wildcard` |
  | two nodes with the same disk serial | 4 | both names |
  | two nodes with the same `.serial` | 4 | both names |
  | `node1.serial` empty | 4 | `node1.serial` |
  | `node1.serial` = `EXAMPLESERIAL1\r\n` | 0 | `checks passed` |
  | `ghost.serial` without `ghost.toml` | 4 | `ghost` |
  | a `notes.txt` in the folder | 0 | `ignored` and `notes.txt` |
  | `--out` equal to `--iso` | 2 | `--out` |
  | `--out /dev/null` | 2 | `device` |
  | `--iso` a file that is not an ISO | 5 | `stock` |
  | `--iso` an ISO that has `/auto-installer-mode.toml` (make one: `cp` the stock ISO, `xorriso -dev <copy> -boot_image any keep -map <any file> /auto-installer-mode.toml`) | 5 | `already prepared` |
  | `PATH` without `xorriso` | 3 | `xorriso` |
  | the untouched examples | 0 | `checks passed (2 node(s): node1 node2)` |

- [x] **Step 3: Run it.** `MULTIPROX_TEST_ISO=<path> tests/build-test.sh` → every case `FAIL` (no `build.sh` yet)
- [x] **Step 4: Implement the checks in `build.sh`**, in this order: tools (`proxmox-auto-install-assistant
  xorriso mke2fs cpio zstd python3`; `mke2fs` also looked for in `/usr/sbin`), arguments and paths, the nodes
  folder, the ISO. Answer files are read with `python3 -c 'import tomllib ...'` (keys `network.filter.ID_NET_NAME_MAC`
  and `disk-setup.filter.ID_SERIAL`). The ISO checks, each exit 5 with its own message:
  - `xorriso -indev` can read it and it has `/boot/linux26`, `/boot/initrd.img`, `/boot/grub/grub.cfg`,
    `/.pve-cd-id.txt`; it has **no** `/auto-installer-mode.toml`
  - the initrd, unpacked into a temp folder (`zstd -dc | cpio -idm`): `init` contains `mdev -s`; there is no
    `etc/mdev.conf`; `sbin/losetup` or `bin/losetup` exists
  - `grub.cfg` contains the line `if [ -f auto-installer-mode.toml ]; then` exactly once and the line starting
    `menuentry 'Install Proxmox VE (Graphical)'` exactly once, the first before the second
  Temp files in one `mktemp -d` removed by a `trap`
- [x] **Step 5: Run it.** Every case `ok`; the script ends `19 passed, 0 failed`, exit 0
- [x] **Step 6: Commit** `build.sh: arguments and checks, with tests`

### Task 2: `build.sh`: the build, and the picker

**Model:** sonnet

**Files:**
- Create: `picker` (0755)
- Modify: `build.sh`, `tests/build-test.sh`

**Interfaces:**
- Consumes: Task 1's checks and `tests/lib.sh`
- Produces: the built ISO at `--out`; last stdout lines `build.sh: wrote <path>` and `build.sh: sha256 <hash>`.
  Test-only environment variable **`MULTIPROX_TEST_AUTOBOOT=<node>`**: the menu's default becomes that node's
  entry with `set timeout=3`, and every node entry gets ` console=tty0 console=ttyS0,115200` appended. With it
  set, the build prints `build.sh: TEST BUILD: starts <node> by itself after 3 s` (Task 3 needs it; the readme
  says never to write such an ISO to a stick)

- [x] **Step 1: The failing tests**, added to `tests/build-test.sh` (one build from `examples/` into a temp
  folder whose name has a space, `--nodes "<tmp>/my nodes"`, `--first-boot examples/first-boot.sh`; then look
  inside the result with `xorriso -osirrox on -indev ... -extract`):
  - exit 0; `--out` exists; the printed sha256 equals `sha256sum`
  - `/auto-installer-mode.toml` contains `mode = "partition"` and `partition_label = "proxmox-ais"`
  - `/boot/grub/grub.cfg`: exactly two lines containing `proxmox-multiprox-node=` (`node1`, `node2`), each on a
    `linux` line that also has `proxmox-start-auto-installer` and no `console=`; each entry's `initrd` line is
    `/boot/initrd.img /boot/multiprox.cpio`; titles `Install Proxmox VE for node1 (refuses any other machine)`;
    no `set timeout=` line with a number ≥ 0 before the first entry (`set timeout=-1`), and `set default=` names
    the Graphical entry's position; the stock `Install Proxmox VE (Automated)` entry is gone; the Graphical,
    Terminal UI and Rescue entries are still there
  - `/boot/multiprox.cpio` lists exactly `etc`, `etc/mdev.conf`, `multiprox`, `multiprox/picker`,
    `multiprox/node1.img`, `multiprox/node1.serial`, `multiprox/node2.img` (`cpio -it`), all owned by uid 0
    (`cpio -itv`); `etc/mdev.conf` is the one line from Global Constraints; `picker` is executable and `sh -n`
    accepts it; `node1.serial` is `EXAMPLESERIAL1` with no CR
  - `blkid` on the extracted `node1.img` says `LABEL="proxmox-ais"`; `debugfs -R "cat /answer.toml"` on it equals
    `examples/node1.toml`
  - a second run to the same `--out` succeeds (overwrites)
  - with `MULTIPROX_TEST_AUTOBOOT=node2`: `set timeout=3`, the default is node2's entry, both node entries have
    `console=ttyS0,115200`, and stdout has `TEST BUILD`
  - with `MULTIPROX_TEST_AUTOBOOT=nosuch`: exit 2
  - a build stopped half-way (`PATH` without `proxmox-auto-install-assistant` is caught earlier, so instead:
    `--first-boot` pointing at a file larger than 1 MiB, which `prepare-iso` refuses) leaves no file at `--out`
- [x] **Step 2: Run it.** The new cases `FAIL`
- [x] **Step 3: `picker`**: the script in the spec ("The picker, as proven"), unchanged
- [x] **Step 4: Implement the build in `build.sh`** (spec "Build" steps 2 to 7): per node
  `mke2fs -q -t ext2 -L proxmox-ais -d <dir with answer.toml> <img> 1024`; the overlay with
  `cpio -o -H newc -R 0:0`; the menu by replacing, in the stock `grub.cfg`, everything from the
  `if [ -f auto-installer-mode.toml ]; then` line up to (not including) the Graphical `menuentry` line; node
  entries copy the stock Automated entry's `linux` options (`ro ramdisk_size=16777216 rw quiet splash=silent
  proxmox-start-auto-installer`) and add the node option. `set default=` is computed: the number of node entries
  (the Graphical entry follows them). The copy of the ISO and all work files live in the `mktemp -d` beside
  `--out` (same filesystem, about 2× the ISO's size is needed: check free space first, exit 2 if short); the
  result is moved to `--out` only when `prepare-iso` succeeded
- [x] **Step 5: Run it.** All cases `ok`
- [x] **Step 6: Commit** `build.sh: builds the multi-node ISO; picker`

### Task 3: The VM test

**Model:** opus (a boot that fails in a new way needs judgement; if the method itself fails, stop and say so:
that is a `fable` session)

**Files:**
- Create: `tests/vm-test.sh` (0755)
- Modify: `tests/lib.sh` if a helper is shared

**Interfaces:**
- Consumes: `build.sh` with `MULTIPROX_TEST_AUTOBOOT`; `docs/spike-2026-11-15/run.sh` (the QEMU command line that
  worked: q35, OVMF 4M code + a copy of the vars file, `-smbios type=1,serial=`, virtio disk with `serial=`,
  the ISO as `usb-storage` on `qemu-xhci`, user network with `hostfwd=tcp:127.0.0.1:<port>-:22`,
  `-serial file:`, `-no-reboot`, `timeout`)
- Produces: `sudo`-less start (`tests/vm-test.sh` calls `sudo -n kvm` itself and says so if that fails); a
  results table on stdout; exit 0 only if every test passed

- [x] **Step 1: Write `tests/vm-test.sh`.** It needs `MULTIPROX_TEST_ISO`, KVM and OVMF
  (`/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd`, `OVMF_VARS_4M.fd`; override with `MULTIPROX_OVMF_DIR`). It
  makes its own nodes folder in a temp dir on a filesystem with 8 GB free (`MULTIPROX_TEST_TMP`, default
  `/var/tmp`): `vm1` (serial `VMSERIAL1`, MAC `52:54:00:aa:bb:01`, disk `VMDISK01`, address `10.0.2.15/24`,
  gateway `10.0.2.2`, dns `10.0.2.3`, a key pair made for the run) and `vm2` (`VMSERIAL2`, `...:02`, `VMDISK02`,
  **no `.serial` file**). It builds two ISOs: autoboot `vm1`, autoboot `vm2`. Tests (disk: a sparse 16 GB raw
  file; "untouched" = `cmp` against `/dev/zero` over its whole size):

  | # | ISO | Machine: DMI serial / disk serial / MAC | Wait | Pass when |
  |---|---|---|---|---|
  | 1 | vm1 | `WRONG` / `VMDISK01` / `...:01` | 60 s | serial log has `REFUSED: this machine's serial number is 'WRONG'`; disk untouched |
  | 2 | vm1 | `VMSERIAL1` / `OTHERDISK` / `...:01` | 150 s | log has `Found answer file on partition` and `filter did not match any devices`; disk untouched |
  | 3 | vm1 | `VMSERIAL1` / `VMDISK01` / `52:54:00:aa:bb:99` | 150 s | log has `filter did not match any devices`; disk untouched |
  | 4 | vm2 | `ANYTHING` / `OTHERDISK` / `...:02` | 150 s | log has `[multiprox] vm2: its answer file is on` (no serial file: no early check) and `filter did not match any devices`; disk untouched |
  | 5 | vm1 | all of vm1's | 900 s | QEMU exits 0 by itself (the installer rebooted); log has `Installation done` |
  | 6 | none (boot test 5's disk; keep `-device qemu-xhci` so the NIC keeps its name) | vm1's | 200 s | over SSH as root with the run's key: `hostname -f` is `vm1.example.org`; `ip -br -4 addr` has `10.0.2.15/24`; `zpool status -x` says healthy; `/root/multiprox-first-boot-ran` exists; `/etc/kernel/cmdline` and `/proc/cmdline` contain no `multiprox` |

  Never match QEMU processes with `pkill -f` (it matches the test itself, and this host runs real guests as
  `kvm`): keep each PID and wait for it, or rely on `timeout`. The SSH port is picked free, not fixed
- [x] **Step 2: Run it** on node3: `MULTIPROX_TEST_ISO=<path> tests/vm-test.sh`. Expected: six `ok`
  lines, `6 passed, 0 failed`, about 10 minutes. A failure prints the last 30 non-kernel lines of that test's
  serial log
- [x] **Step 3: Commit** `tests: the VM test (refusals, a full install, the installed system)` with the
  results table in the commit message

### Task 4: Readme, licence, close-out

**Model:** sonnet

**Files:**
- Create: `readme.md`, `LICENSE` (MIT, `Copyright (c) 2026 Lee Wiscovitch`)
- Modify: `docs/superpowers/specs/2026-11-15-wiscomultiprox-design.md` (status line: built, date; "Proven so
  far" gains Task 3's table), this plan (status notes)

- [x] **Step 1: `readme.md`**, in this order: what it is (three sentences and what the menu looks like);
  **what it does to a machine** (wipes the picked machine's disk without asking; refuses any other); what you
  need (a Debian with the Proxmox repository or a Proxmox node; the tools; UEFI machines); gathering a machine's
  values (`proxmox-auto-install-assistant device-info -t network`, `-t disk`, `cat /sys/class/dmi/id/product_serial`);
  the nodes folder (from `examples/`); build; **writing the stick** (find it by `/dev/disk/by-id/`, `lsblk` check,
  `dd`, `cmp`: the reader replaces the id, the readme never guesses one); installing (boot the stick, pick the
  entry, pull the stick at the reboot); a first harmless check (boot it on a machine that is not in it: it must
  refuse); a new Proxmox release (download, build, run `tests/vm-test.sh`); how it works and what it relies on
  (from the spec, shortened); tested / not tested (Task 3's table; legacy BIOS, Secure Boot, real hardware until
  someone has done it); the tests and how to run them; secrets (the ISO and the stick hold the answer files'
  password hashes; `nodes/` is never committed)
- [x] **Step 2: Check the readme against the tool.** Every command in it is run once as written (except `dd`),
  and every one carries its prefix
- [x] **Step 3: Everything once.** `tests/build-test.sh` and `tests/vm-test.sh` pass; `git status` clean;
  `git grep -n -i -E '<the lab machines' MAC prefix, serial prefixes and host names>'` finds only this plan, the spec and
  `docs/spike-2026-11-15/` mentioning names (no MAC, no serial)
- [x] **Step 4: Commit** `readme, licence; design marked built`

---

## After this plan (not part of it)

The tool is then finished and tested, and still only on node3. What follows is `wiscolabx` work, to be
designed and planned **there** in a fresh session (`fable`), after the session working in that repo is done:

1. **How the lab's hosts reach this repository.** Found 2026-11-15: GitHub allows a deploy key on **one**
   repository only, and each host's key is already the deploy key of `wiscolabx`. So "the same keys on both
   repos" cannot be done. Reading needs no key (the repository is public: clone over HTTPS). Writing needs a
   second key on the host that develops it, or another way: a decision for that design
2. `tofu/github` takes the repository over (an `import`; the token already reaches it, checked 2026-11-15)
3. The first push of this repo
4. The changes listed in the spec's "What changes in `wiscolabx`" (`host_serial`, `install-media.yml`, the docs,
   the third-node plan's Task 10 Steps 3 and 4, the harmless hardware check)
