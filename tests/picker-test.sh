#!/bin/bash
# The picker on its own, run by the stock initrd's busybox in a chroot (a user namespace: no root, no VM).
# /proc/cmdline and the DMI serial are plain files there, and there is no loop device, so a picker that gets past
# its checks stops at the loop device: that is how a pass is seen here. The VM test covers the real thing.
# Run: MULTIPROX_TEST_ISO=<stock proxmox-ve ISO> tests/picker-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
need_iso
unshare -r true 2> /dev/null || { echo "picker-test.sh: 'unshare -r' (user namespaces) does not work here" >&2; exit 2; }

tmp=$(mktemp -d "${MULTIPROX_TEST_TMP:-/var/tmp}/multiprox-picker-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
xorriso -osirrox on -indev "$MULTIPROX_TEST_ISO" -extract /boot/initrd.img "$tmp/initrd.img" > /dev/null 2>&1
root="$tmp/root"
mkdir "$root"
(cd "$root" && zstd -dc "$tmp/initrd.img" | cpio -idm --quiet 2> /dev/null) || true
[ -x "$root/bin/busybox" ] || { echo "picker-test.sh: no busybox in the initrd" >&2; exit 2; }
mkdir -p "$root/multiprox" "$root/proc" "$root/sys/class/dmi/id"
cp "$repo/picker" "$root/multiprox/picker"
: > "$root/multiprox/node1.img"
: > "$root/multiprox/node2.img"
echo EXAMPLESERIAL1 > "$root/multiprox/node1.serial"

# A picker past its checks stops at the loop device (none in a chroot).
past="REFUSED: (no free loop device|could not attach the answer image)"

# run <kernel command line> <DMI serial>: prints what the picker printed (it never returns from a refusal).
run() {
  rm -f "$root/multiprox/.ran"
  printf '%s\n' "$1" > "$root/proc/cmdline"
  printf '%s\n' "$2" > "$root/sys/class/dmi/id/product_serial"
  timeout 3 unshare -r chroot "$root" /bin/sh /multiprox/picker 2>&1 || true
}

check "right serial: past the check" 0 "$past" -- \
  run "ro quiet proxmox-multiprox-node=node1" "EXAMPLESERIAL1"
check "wrong serial: refused, both serials named" 0 "serial number is 'OTHER'; the entry is for node1 \('EXAMPLESERIAL1'\)" -- \
  run "ro quiet proxmox-multiprox-node=node1" "OTHER"
check "no .serial for node2: no serial check" 0 "$past" -- \
  run "ro quiet proxmox-multiprox-node=node2" "ANYTHING"
check "firmware serial with trailing blanks: past the check" 0 "$past" -- \
  run "ro quiet proxmox-multiprox-node=node1" "EXAMPLESERIAL1   "
check "no node option: refused" 0 "REFUSED: no proxmox-multiprox-node=" -- run "ro quiet" "EXAMPLESERIAL1"
check "a node the stick does not have: refused" 0 "REFUSED: this stick has no answer for 'node3'" -- \
  run "ro quiet proxmox-multiprox-node=node3" "EXAMPLESERIAL1"

# A pattern on the command line must not be expanded against file names (here: one named like node2's option).
: > "$root/proxmox-multiprox-node=node2"
check "a glob on the command line is not expanded" 0 "REFUSED: bad node name 'nod\*'" -- \
  run "ro quiet proxmox-multiprox-node=nod*" "ANYTHING"
rm -f "$root/proxmox-multiprox-node=node2"

finish
