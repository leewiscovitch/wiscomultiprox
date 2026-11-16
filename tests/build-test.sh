#!/bin/bash
# The build's checks and output, without a VM.
# Run: MULTIPROX_TEST_ISO=<stock proxmox-ve ISO> tests/build-test.sh
# Temp files go to MULTIPROX_TEST_TMP (default /var/tmp; about 4 GB free needed) and are removed at the end.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
need_iso

build="$repo/build.sh"
iso="$MULTIPROX_TEST_ISO"
tmp=$(mktemp -d "${MULTIPROX_TEST_TMP:-/var/tmp}/multiprox-build-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
out="$tmp/out.iso"

# A fresh copy of examples/ for one case; prints its path.
fresh() {
  local d
  d=$(mktemp -d "$tmp/nodes.XXXXXX")
  cp "$repo"/examples/*.toml "$repo"/examples/*.serial "$d/"
  echo "$d"
}

echo "== checks"

check "no arguments" 2 "usage" -- "$build"

check "--iso not a file" 2 "$tmp/nosuch.iso" -- \
  "$build" --iso "$tmp/nosuch.iso" --nodes "$(fresh)" --out "$out"

mkdir "$tmp/empty"
check "--nodes empty folder" 4 "no node" -- \
  "$build" --iso "$iso" --nodes "$tmp/empty" --out "$out"

d=$(fresh); mv "$d/node1.toml" "$d/Node1.toml"; rm "$d/node1.serial"
check "Node1.toml (capital)" 4 "Node1" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); sed -i 's/^timezone = .*/timezone = "Nowhere\/Nothing"/' "$d/node2.toml"
check "answer file that fails validate-answer" 4 "node2\.toml" -- \
  "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); sed -i 's/^filter.ID_SERIAL = .*/filter.ID_MODEL = "EXAMPLEMODEL"/' "$d/node1.toml"
check "filter.ID_SERIAL missing" 4 "ID_SERIAL" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); sed -i 's/^filter.ID_NET_NAME_MAC = .*/filter.ID_NET_NAME_MAC = "enx5254*"/' "$d/node1.toml"
check "wildcard in the MAC filter" 4 "wildcard" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); sed -i 's/EXAMPLEDISK02/EXAMPLEDISK01/' "$d/node2.toml"
check "two nodes with the same disk serial" 4 "node1.*node2" -- \
  "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); cp "$d/node1.serial" "$d/node2.serial"
check "two nodes with the same .serial" 4 "node1.*node2" -- \
  "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); : > "$d/node1.serial"
check "node1.serial empty" 4 "node1\.serial" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); printf 'EXAMPLESERIAL1 \r\n' > "$d/node1.serial"
check "node1.serial with CRLF and a trailing blank" 0 "checks passed" -- \
  "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); echo GHOSTSERIAL > "$d/ghost.serial"
check "ghost.serial without ghost.toml" 4 "ghost" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); echo "my notes" > "$d/notes.txt"
check "a notes.txt in the folder" 0 "ignored.*notes\.txt" -- \
  "$build" --iso "$iso" --nodes "$d" --out "$out"

check "--out equal to --iso" 2 "--out" -- "$build" --iso "$iso" --nodes "$(fresh)" --out "$iso"

check "--out /dev/null" 2 "device" -- "$build" --iso "$iso" --nodes "$(fresh)" --out /dev/null

head -c 1048576 /dev/urandom > "$tmp/random.iso"
check "--iso a file that is not an ISO" 5 "stock" -- \
  "$build" --iso "$tmp/random.iso" --nodes "$(fresh)" --out "$out"

cp "$iso" "$tmp/prepared.iso"
echo 'mode = "iso"' > "$tmp/mode.toml"
xorriso -dev "$tmp/prepared.iso" -boot_image any keep -map "$tmp/mode.toml" /auto-installer-mode.toml \
  > /dev/null 2>&1
check "--iso already prepared" 5 "already prepared" -- \
  "$build" --iso "$tmp/prepared.iso" --nodes "$(fresh)" --out "$out"
rm -f "$tmp/prepared.iso"

mkdir "$tmp/bin"
for f in /usr/bin/* /usr/sbin/*; do
  [ "$(basename "$f")" = xorriso ] || ln -sf "$f" "$tmp/bin/"
done
d=$(fresh); sed -i '/^filter.ID_SERIAL/a filter.ID_MODEL = "Samsung*"' "$d/node1.toml"
check "an extra disk filter beside ID_SERIAL" 4 "only" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); sed -i '/^filter.ID_NET_NAME_MAC/a filter.ID_NET_NAME = "en*"' "$d/node2.toml"
check "an extra network filter beside ID_NET_NAME_MAC" 4 "only" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); printf '\xff\xfeE\0X\0A\0M\0P\0L\0E\0S\0E\0R\0I\0A\0L\x001\0' > "$d/node1.serial"
check "node1.serial saved as UTF-16 (PowerShell 5.1)" 4 "node1\.serial" -- \
  "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); printf '\xef\xbb\xbfEXAMPLESERIAL1\r\n' > "$d/node1.serial"
check "node1.serial with a UTF-8 BOM" 4 "node1\.serial" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); mv "$d/node1.serial" "$d/node1.serial.txt"
check "node1.serial.txt (a near miss)" 4 "node1\.serial\.txt" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); mv "$d/node1.serial" "$d/node1.SERIAL"
check "node1.SERIAL (a near miss)" 4 "node1\.SERIAL" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); echo "To Be Filled By O.E.M." > "$d/node1.serial"
check "a placeholder serial (To Be Filled By O.E.M.)" 4 "placeholder" -- \
  "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh); echo "Default string" > "$d/node1.serial"
check "a placeholder serial (Default string)" 4 "placeholder" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

d=$(fresh)
check "--out inside the nodes folder" 2 "nodes folder" -- "$build" --iso "$iso" --nodes "$d" --out "$d/x.iso"

cp "$repo/examples/first-boot.sh" "$tmp/fb.sh"
check "--out equal to --first-boot" 2 "first-boot" -- \
  "$build" --iso "$iso" --nodes "$(fresh)" --out "$tmp/fb.sh" --first-boot "$tmp/fb.sh"

check "--out a folder name ending in /" 2 "--out" -- "$build" --iso "$iso" --nodes "$(fresh)" --out "$tmp/nosuch/"

# An ISO whose automated block holds one more entry: the build must not drop it silently.
cp "$iso" "$tmp/odd.iso"
xorriso -osirrox on -indev "$iso" -extract /boot/grub/grub.cfg "$tmp/odd-grub.cfg" > /dev/null 2>&1
chmod u+w "$tmp/odd-grub.cfg"
sed -i "/^if \[ -f auto-installer-mode.toml \]; then\$/a menuentry 'Extra' {\n    linux /boot/linux26\n}" "$tmp/odd-grub.cfg"
xorriso -dev "$tmp/odd.iso" -boot_image any keep -map "$tmp/odd-grub.cfg" /boot/grub/grub.cfg > /dev/null 2>&1
check "--iso whose automated block holds another entry" 5 "automated block" -- \
  "$build" --iso "$tmp/odd.iso" --nodes "$(fresh)" --out "$out"
rm -f "$tmp/odd.iso"

mkdir "$tmp/bin-py"
for f in /usr/bin/* /usr/sbin/*; do
  [ "$(basename "$f")" = python3 ] || ln -sf "$f" "$tmp/bin-py/"
done
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin-py/python3"
chmod 755 "$tmp/bin-py/python3"
check "python3 without tomllib (older than 3.11)" 3 "3\.11" -- \
  env PATH="$tmp/bin-py" "$build" --iso "$iso" --nodes "$(fresh)" --out "$out"

# The boot menu shows about 60 characters of a title.
d=$(fresh); mv "$d/node2.toml" "$d/a-node-name-that-is-41-characters-long-xy.toml"
check "a node name longer than 40 characters" 4 "40" -- "$build" --iso "$iso" --nodes "$d" --out "$out"

check "PATH without xorriso" 3 "xorriso" -- \
  env PATH="$tmp/bin" "$build" --iso "$iso" --nodes "$(fresh)" --out "$out"

check "the untouched examples" 0 "checks passed \(2 node\(s\): node1 node2\)" -- \
  "$build" --iso "$iso" --nodes "$repo/examples" --out "$out"

echo "== build"

# A build from a folder whose name has a space, into one whose name has a space.
mkdir "$tmp/my nodes" "$tmp/my out"
cp "$repo"/examples/*.toml "$repo"/examples/*.serial "$tmp/my nodes/"
built="$tmp/my out/multiprox.iso"
mkdir "$tmp/my out/.multiprox-build.OLD"   # as a killed build leaves it
log="$tmp/build.log"
set +e
"$build" --iso "$iso" --nodes "$tmp/my nodes" --out "$built" --first-boot "$repo/examples/first-boot.sh" \
  > "$log" 2>&1
build_rc=$?
set -e
x="$tmp/x"
mkdir "$x"
if [ -f "$built" ]; then
  xorriso -osirrox on -indev "$built" -extract /auto-installer-mode.toml "$x/mode.toml" \
    -extract /boot/grub/grub.cfg "$x/grub.cfg" -extract /boot/multiprox.cpio "$x/multiprox.cpio" \
    > /dev/null 2>&1 || true
  mkdir "$x/cpio"
  if [ -f "$x/multiprox.cpio" ]; then (cd "$x/cpio" && cpio -idm --quiet < "$x/multiprox.cpio" 2>/dev/null) || true; fi
fi

built_ok() {
  [ "$build_rc" = 0 ] || { cat "$log"; return 1; }
  [ -f "$built" ] || { echo "no $built"; return 1; }
  local printed actual
  printed=$(sed -n 's/^build.sh: sha256 //p' "$log")
  actual=$(sha256sum "$built" | cut -d' ' -f1)
  [ "$printed" = "$actual" ] || { echo "printed '$printed', file $actual"; return 1; }
  grep -qxF "build.sh: wrote $built" "$log" || { echo "no 'wrote' line"; return 1; }
}
check "build: exit 0, --out written, sha256 printed and right" 0 "" -- built_ok
check "build: names a work folder left by a stopped build" 0 "" -- \
  grep -qF "build.sh: note: $tmp/my out/.multiprox-build.OLD" "$log"

mode_ok() {
  grep -q 'mode = "partition"' "$x/mode.toml" && grep -q 'partition_label = "proxmox-ais"' "$x/mode.toml"
}
check "build: /auto-installer-mode.toml is partition mode, label proxmox-ais" 0 "" -- mode_ok

# The line number of the first top-level menuentry, and how many top-level entries come before a line.
first_entry() { grep -n '^menuentry ' "$1" | head -n 1 | cut -d: -f1; }
entries_before() { head -n "$(($2 - 1))" "$1" | grep -c '^menuentry ' || true; }

grub_ok() {
  local g="$x/grub.cfg" lines first graphical
  lines=$(grep 'proxmox-multiprox-node=' "$g")
  [ "$(wc -l <<<"$lines")" = 2 ] || { echo "node option lines: $lines"; return 1; }
  grep -q 'proxmox-multiprox-node=node1$' <<<"$lines" && grep -q 'proxmox-multiprox-node=node2$' <<<"$lines" \
    || { echo "node names: $lines"; return 1; }
  ! grep -v '^\s*linux\s' <<<"$lines" | grep -q . || { echo "not on a linux line"; return 1; }
  [ "$(grep -c 'proxmox-start-auto-installer' <<<"$lines")" = 2 ] || { echo "no proxmox-start-auto-installer"; return 1; }
  ! grep -q 'console=' <<<"$lines" || { echo "console= on a node entry"; return 1; }
  [ "$(grep -cE '^\s*initrd\s+/boot/initrd\.img /boot/multiprox\.cpio$' "$g")" = 2 ] || { echo "initrd lines"; return 1; }
  grep -qF "menuentry 'Automated Install: node1'" "$g" || { echo "title node1"; return 1; }
  grep -qF "menuentry 'Automated Install: node2'" "$g" \
    || { echo "title node2"; return 1; }
  grep -qF "menuentry 'Automated Install: node1' --id multiprox-node1 " "$g" \
    || { echo "no --id on node1's entry"; return 1; }
  first=$(first_entry "$g")
  head -n "$first" "$g" | grep -qx '\s*set timeout=-1' || { echo "no set timeout=-1 before the entries"; return 1; }
  ! head -n "$first" "$g" | grep -qE '^\s*set timeout=[0-9]' || { echo "a timeout >= 0 before the entries"; return 1; }
  graphical=$(grep -n "^menuentry 'Install Proxmox VE (Graphical)' --id multiprox-graphical " "$g" | cut -d: -f1)
  [ -n "$graphical" ] || { echo "no --id on the Graphical entry"; return 1; }
  head -n "$first" "$g" | grep -qx '\s*set default=multiprox-graphical' \
    || { echo "set default is not the Graphical entry"; return 1; }
  ! head -n "$graphical" "$g" | grep -qF '(Automated)' || { echo "the stock Automated entry is still there"; return 1; }
  grep -qF "menuentry 'Install Proxmox VE (Terminal UI)'" "$g" && grep -qF "menuentry 'Rescue Boot'" "$g" \
    || { echo "stock entries missing"; return 1; }
}
check "build: grub.cfg has the node entries, no timeout, Graphical default" 0 "" -- grub_ok

cpio_ok() {
  local c="$x/multiprox.cpio" names want
  names=$(cpio -it --quiet < "$c" | sort)
  want=$(printf '%s\n' etc etc/mdev.conf multiprox multiprox/node1.img multiprox/node1.serial multiprox/node2.img \
    multiprox/picker | sort)
  [ "$names" = "$want" ] || { echo "cpio has: $names"; return 1; }
  ! cpio -itv -n --quiet < "$c" | awk '$3 != 0 || $4 != 0' | grep -q . || { echo "not all owned by 0"; return 1; }
  cpio -itv --quiet < "$c" | grep -qE '^-rwx.* multiprox/picker$' || { echo "picker not executable"; return 1; }
  [ "$(cat "$x/cpio/etc/mdev.conf")" = "loop0 0:0 0660 @/multiprox/picker" ] || { echo "mdev.conf"; return 1; }
  [ "$(wc -l < "$x/cpio/etc/mdev.conf")" = 1 ] || { echo "mdev.conf lines"; return 1; }
  sh -n "$x/cpio/multiprox/picker" || return 1
  [ "$(od -An -c "$x/cpio/multiprox/node1.serial" | tr -s ' ')" = " E X A M P L E S E R I A L 1 \n" ] \
    || { echo "node1.serial: $(od -An -c "$x/cpio/multiprox/node1.serial")"; return 1; }
}
check "build: the overlay holds exactly the files, owned by root" 0 "" -- cpio_ok

img_ok() {
  local i="$x/cpio/multiprox/node1.img"
  blkid "$i" | grep -q 'LABEL="proxmox-ais"' || { blkid "$i"; return 1; }
  /usr/sbin/debugfs -R "cat /answer.toml" "$i" 2>/dev/null | cmp - "$repo/examples/node1.toml"
}
check "build: node1.img is labelled proxmox-ais and holds node1.toml" 0 "" -- img_ok

check "build: a second run to the same --out overwrites" 0 "build.sh: wrote" -- \
  "$build" --iso "$iso" --nodes "$tmp/my nodes" --out "$built"

auto="$tmp/auto.iso"
auto_ok() {
  local out g="$tmp/auto-grub.cfg" first n2
  out=$(MULTIPROX_TEST_AUTOBOOT=node2 "$build" --iso "$iso" --nodes "$repo/examples" --out "$auto" 2>&1) \
    || { echo "$out"; return 1; }
  grep -q 'TEST BUILD' <<<"$out" || { echo "no TEST BUILD line"; return 1; }
  rm -f "$g"
  xorriso -osirrox on -indev "$auto" -extract /boot/grub/grub.cfg "$g" > /dev/null 2>&1
  first=$(first_entry "$g")
  head -n "$first" "$g" | grep -qx '\s*set timeout=3' || { echo "no set timeout=3"; return 1; }
  head -n "$first" "$g" | grep -qx '\s*set default=multiprox-node2' || { echo "default not node2"; return 1; }
  [ "$(grep 'proxmox-multiprox-node=' "$g" | grep -c ' console=tty0 console=ttyS0,115200$')" = 2 ] \
    || { echo "console options"; return 1; }
}
check "build: MULTIPROX_TEST_AUTOBOOT=node2 makes a test build" 0 "" -- auto_ok
rm -f "$auto"

check "build: MULTIPROX_TEST_AUTOBOOT=nosuch is refused" 2 "nosuch" -- \
  env MULTIPROX_TEST_AUTOBOOT=nosuch "$build" --iso "$iso" --nodes "$repo/examples" --out "$auto"

mkdir "$tmp/half"
head -c 2097152 /dev/urandom > "$tmp/big-first-boot.sh"
half_ok() {
  local rc=0 msg
  msg=$("$build" --iso "$iso" --nodes "$repo/examples" --out "$tmp/half/x.iso" \
    --first-boot "$tmp/big-first-boot.sh" 2>&1) || rc=$?
  [ "$rc" = 1 ] || { echo "exit $rc, wanted 1"; return 1; }
  # prepare-iso exits 0 on errors (9.2-1); its own reason must still reach the user.
  grep -q '^build.sh: proxmox-auto-install-assistant prepare-iso failed: .*1 MiB' <<<"$msg" \
    || { echo "reason lost: $msg"; return 1; }
  [ -z "$(ls -A "$tmp/half")" ] || { echo "left behind: $(ls -A "$tmp/half")"; return 1; }
}
check "build: stopped half-way, nothing left at --out" 0 "" -- half_ok

finish
