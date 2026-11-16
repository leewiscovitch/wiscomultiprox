#!/bin/bash
# build.sh: one Proxmox VE install ISO for several machines.
# Takes the stock Proxmox VE ISO and a folder of answer files (one per machine) and writes one ISO whose boot
# menu has an unattended-install entry per machine. See readme.md.
set -euo pipefail
export LC_ALL=C

usage="usage: build.sh --iso <stock proxmox-ve ISO> --nodes <folder> --out <file.iso> [--first-boot <script>]"

# Exit codes: 2 usage or a missing input, 3 a missing tool, 4 a bad nodes folder,
# 5 the ISO is not what the method relies on, 1 a tool that failed.
work=""
cleanup() {
  if [ -n "$work" ]; then rm -rf "$work"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
die() {
  echo "build.sh: $2" >&2
  exit "$1"
}
note() {
  echo "build.sh: note: $1" >&2
}

# ---- arguments

iso="" nodes="" out="" first_boot=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$usage"; exit 0 ;;
    --iso|--nodes|--out|--first-boot)
      [ $# -ge 2 ] || die 2 "$1 needs a value; $usage"
      case "$1" in
        --iso) iso="$2" ;;
        --nodes) nodes="$2" ;;
        --out) out="$2" ;;
        --first-boot) first_boot="$2" ;;
      esac
      shift 2 ;;
    *) die 2 "unknown argument '$1'; $usage" ;;
  esac
done
[ -n "$iso" ] && [ -n "$nodes" ] && [ -n "$out" ] || die 2 "$usage"

# ---- tools

for tool in proxmox-auto-install-assistant xorriso cpio zstd python3; do
  command -v "$tool" > /dev/null || die 3 "$tool not found (on Proxmox VE or Debian: apt install $tool)"
done
python3 -c 'import tomllib' 2> /dev/null || die 3 "python3 has no tomllib: it needs Python 3.11 or later"
mke2fs=$(command -v mke2fs || true)
if [ -z "$mke2fs" ] && [ -x /usr/sbin/mke2fs ]; then mke2fs=/usr/sbin/mke2fs; fi
[ -n "$mke2fs" ] || die 3 "mke2fs not found (apt install e2fsprogs)"

# ---- paths

[ -f "$iso" ] || die 2 "--iso $iso: no such file"
[ -d "$nodes" ] || die 2 "--nodes $nodes: no such folder"
if [ -n "$first_boot" ]; then
  [ -f "$first_boot" ] || die 2 "--first-boot $first_boot: no such file"
fi
case "$out" in
  */) die 2 "--out $out ends in /; give a file name" ;;
  /dev/*) die 2 "--out $out is a device; the tool writes a file, never a device (see readme: writing the stick)" ;;
esac
if [ -b "$out" ] || [ -c "$out" ]; then
  die 2 "--out $out is a device; the tool writes a file, never a device"
fi
[ ! -d "$out" ] || die 2 "--out $out is a folder; give a file name"
if [ -e "$out" ] && [ "$out" -ef "$iso" ]; then die 2 "--out is the stock ISO itself; give another file"; fi
if [ "$(realpath -m "$out")" = "$(realpath -m "$iso")" ]; then die 2 "--out is the stock ISO itself; give another file"; fi
if [ -n "$first_boot" ] && [ "$(realpath -m "$out")" = "$(realpath -m "$first_boot")" ]; then
  die 2 "--out is the --first-boot script; give another file"
fi
out_dir=$(dirname "$out")
if [ "$(realpath -m "$out_dir")" = "$(realpath -m "$nodes")" ]; then
  die 2 "--out is inside the nodes folder; the tool never writes there"
fi
[ -d "$out_dir" ] && [ -w "$out_dir" ] || die 2 "--out $out: folder $out_dir does not exist or is not writable"

# ---- the nodes folder

shopt -s nullglob dotglob
names=()
declare -A has_toml=()
serials=()
for path in "$nodes"/*; do
  file=$(basename "$path")
  lower="${file,,}"
  near_miss="$file looks like a node's .toml or .serial but is not one (exactly <name>.toml or <name>.serial, a file)"
  if [ -d "$path" ]; then
    case "$lower" in *.toml*|*.serial*) die 4 "$near_miss" ;; esac
    note "ignored folder $file in $nodes"; continue
  fi
  case "$file" in
    *.toml)
      name="${file%.toml}"
      [[ "$name" =~ ^[a-z0-9-]+$ ]] || die 4 "$file: a node name is lowercase letters, digits and '-' only"
      # The boot menu shows about 60 characters of "Automated Install: <name>".
      [ "${#name}" -le 40 ] || die 4 "$file: a node name is at most 40 characters (the boot menu cuts longer titles)"
      names+=("$name"); has_toml[$name]=1 ;;
    *.serial)
      name="${file%.serial}"
      [[ "$name" =~ ^[a-z0-9-]+$ ]] || die 4 "$file: a node name is lowercase letters, digits and '-' only"
      serials+=("$name") ;;
    *)
      # A typo here (node1.serial.txt, node1.SERIAL) would silently drop a check: refused, not ignored.
      case "$lower" in *.toml*|*.serial*) die 4 "$near_miss" ;; esac
      note "ignored $file (only <name>.toml and <name>.serial are read)" ;;
  esac
done
shopt -u nullglob dotglob
[ "${#names[@]}" -gt 0 ] || die 4 "no node in $nodes (no <name>.toml)"
for name in "${serials[@]}"; do
  [ -n "${has_toml[$name]:-}" ] || die 4 "$name.serial has no $name.toml beside it (a typo would silently drop the serial check)"
done

read_filters='
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    a = tomllib.load(f)
for keys in (("network", "filter", "ID_NET_NAME_MAC"), ("disk-setup", "filter", "ID_SERIAL")):
    v = a
    for k in keys:
        v = v.get(k) if isinstance(v, dict) else None
    print(v if isinstance(v, str) else "")
# Each filter table holds exactly its one key: another key (ID_MODEL = "Samsung*") could match another machine.
problems = []
for table, key in (("network", "ID_NET_NAME_MAC"), ("disk-setup", "ID_SERIAL")):
    f = a.get(table, {}).get("filter", {})
    extra = sorted(k for k in f if k != key) if isinstance(f, dict) else []
    if extra:
        names = ", ".join("filter." + k for k in extra)
        problems.append(f"[{table}] has {names}; give only filter.{key}")
for k in ("disk-list", "disk_list"):
    if k in a.get("disk-setup", {}):
        problems.append(f"[disk-setup] has {k}; give only filter.ID_SERIAL")
print("; ".join(problems))
'
declare -A mac_of=() disk_of=() serial_of=() mac_owner=() disk_owner=() serial_owner=()
for name in "${names[@]}"; do
  toml="$nodes/$name.toml"
  # validate-answer exits 0 even when it finds issues (9.2-1): its success line is what counts.
  msg=$(proxmox-auto-install-assistant validate-answer "$toml" 2>&1 || true)
  if ! grep -q 'no errors found' <<<"$msg"; then
    die 4 "$toml does not pass proxmox-auto-install-assistant validate-answer: $(head -n 1 <<<"$msg")"
  fi
  filters=$(python3 -c "$read_filters" "$toml") || die 4 "$toml: could not be read as TOML"
  mac=$(sed -n 1p <<<"$filters")
  disk=$(sed -n 2p <<<"$filters")
  problems=$(sed -n 3p <<<"$filters")
  [ -z "$problems" ] || die 4 "$toml: $problems (only the exact MAC and disk serial select a machine)"
  [ -n "$mac" ] || die 4 "$toml: no network filter.ID_NET_NAME_MAC (each node must match exactly one network card)"
  [ -n "$disk" ] || die 4 "$toml: no disk-setup filter.ID_SERIAL (each node must match exactly one disk)"
  for v in "$mac" "$disk"; do
    case "$v" in
      *[*?[]*) die 4 "$toml: filter '$v' has a wildcard; give the exact value (a pattern could match another machine)" ;;
    esac
  done
  if [ -n "${mac_owner[$mac]:-}" ]; then die 4 "${mac_owner[$mac]} and $name have the same MAC filter '$mac'"; fi
  if [ -n "${disk_owner[$disk]:-}" ]; then die 4 "${disk_owner[$disk]} and $name have the same disk serial '$disk'"; fi
  mac_owner[$mac]=$name; disk_owner[$disk]=$name
  mac_of[$name]=$mac; disk_of[$name]=$disk
  if [ -f "$nodes/$name.serial" ]; then
    # Only printable ASCII: a BOM or UTF-16 (PowerShell 5.1's ">") would never match the machine.
    if [ "$(tr -d ' -~\r\n\t' < "$nodes/$name.serial" | wc -c)" != 0 ]; then
      die 4 "$name.serial is not plain ASCII text (a BOM, or UTF-16?); save it as UTF-8 without BOM, or ASCII"
    fi
    # Trim CR (a file saved on Windows) and blanks at both ends.
    serial=$(tr -d '\r' < "$nodes/$name.serial" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d')
    [ -n "$serial" ] || die 4 "$name.serial is empty (delete it, or put the machine's serial number in it)"
    [ "$(wc -l <<<"$serial")" = 1 ] || die 4 "$name.serial has more than one line; it holds one serial number"
    case "${serial,,}" in
      "to be filled by o.e.m."|"default string"|"system serial number"|"chassis serial number"|"serial number"|\
      "not specified"|"not applicable"|"not available"|"none"|"n/a"|"na"|"invalid"|"unknown"|"0"|"0123456789"|\
      "123456789"|"1234567890"|"00000000")
        die 4 "$name.serial holds a placeholder ('$serial'), the same on many machines; delete the file (the filters still hold)" ;;
    esac
    if [ -n "${serial_owner[$serial]:-}" ]; then die 4 "${serial_owner[$serial]} and $name have the same serial '$serial'"; fi
    serial_owner[$serial]=$name; serial_of[$name]=$serial
  fi
done

# ---- the ISO

for old in "$out_dir"/.multiprox-build.*; do
  if [ -d "$old" ]; then note "$old is left over from a stopped build; delete it (it can be as big as two ISOs)"; fi
done
work=$(mktemp -d "$out_dir/.multiprox-build.XXXXXX")
give_stock="give the stock Proxmox VE ISO, as downloaded"
listing=$(xorriso -indev "$iso" -lsd /.pve-cd-id.txt /boot/linux26 /boot/initrd.img /boot/grub/grub.cfg \
  /auto-installer-mode.toml 2>/dev/null) || die 5 "$iso cannot be read as an ISO; $give_stock"
for f in /.pve-cd-id.txt /boot/linux26 /boot/initrd.img /boot/grub/grub.cfg; do
  grep -qxF "'$f'" <<<"$listing" || die 5 "$iso has no $f: not a Proxmox VE ISO; $give_stock"
done
if grep -qxF "'/auto-installer-mode.toml'" <<<"$listing"; then
  die 5 "$iso was already prepared (it has /auto-installer-mode.toml); $give_stock"
fi
xorriso -osirrox on -indev "$iso" -extract /boot/grub/grub.cfg "$work/grub.cfg" \
  -extract /boot/initrd.img "$work/initrd.img" > /dev/null 2>&1 || die 1 "xorriso could not extract from $iso"
chmod u+w "$work/grub.cfg" "$work/initrd.img"

relies="this Proxmox VE release does not have what the method relies on (readme: what it relies on)"
initrd_list=$(zstd -dc "$work/initrd.img" | cpio -it 2>/dev/null) || die 5 "the ISO's initrd cannot be unpacked (zstd, cpio); $relies"
zstd -dc "$work/initrd.img" | cpio -i --quiet --to-stdout init 2>/dev/null | grep -q 'mdev -s' \
  || die 5 "the initrd's /init does not run 'mdev -s'; $relies"
! grep -qx 'etc/mdev.conf' <<<"$initrd_list" || die 5 "the initrd has its own /etc/mdev.conf; $relies"
grep -qxE '(s?bin)/losetup' <<<"$initrd_list" || die 5 "the initrd has no losetup; $relies"

anchor_auto='if [ -f auto-installer-mode.toml ]; then'
anchor_graphical="menuentry 'Install Proxmox VE (Graphical)'"
auto_lines=$(grep -nxF "$anchor_auto" "$work/grub.cfg" | cut -d: -f1 || true)
graphical_lines=$(grep -n "^$anchor_graphical" "$work/grub.cfg" | cut -d: -f1 || true)
[ -n "$auto_lines" ] && [ "$(wc -l <<<"$auto_lines")" = 1 ] \
  || die 5 "grub.cfg has not exactly one line '$anchor_auto'; $relies"
[ -n "$graphical_lines" ] && [ "$(wc -l <<<"$graphical_lines")" = 1 ] \
  || die 5 "grub.cfg has not exactly one line starting \"$anchor_graphical\"; $relies"
[ "$auto_lines" -lt "$graphical_lines" ] || die 5 "grub.cfg: the automated block is not before the Graphical entry; $relies"
# What is replaced must be only the stock block: one entry, then its closing `fi`. Anything more would be lost.
block=$(sed -n "${auto_lines},$((graphical_lines - 1))p" "$work/grub.cfg")
[ "$(grep -c '^\s*menuentry ' <<<"$block")" = 1 ] && [ "$(grep . <<<"$block" | tail -n 1)" = "fi" ] \
  || die 5 "grub.cfg: the automated block holds more than the stock Automated entry; $relies"

auto_line=$(sed -n "${auto_lines},$((graphical_lines - 1))p" "$work/grub.cfg" \
  | grep -E '^\s*linux\s+/boot/linux26 .*proxmox-start-auto-installer' || true)
[ "$(grep -c . <<<"$auto_line")" = 1 ] \
  || die 5 "grub.cfg: the automated block has no single 'linux /boot/linux26 ... proxmox-start-auto-installer' line; $relies"
linux_options=$(sed -E 's/^\s*linux\s+\/boot\/linux26\s+//' <<<"$auto_line")

echo "build.sh: checks passed (${#names[@]} node(s): ${names[*]})"

# ---- the build

autoboot="${MULTIPROX_TEST_AUTOBOOT:-}"
if [ -n "$autoboot" ] && [ -z "${has_toml[$autoboot]:-}" ]; then
  die 2 "MULTIPROX_TEST_AUTOBOOT=$autoboot: no such node (have: ${names[*]})"
fi

# The copy of the ISO and prepare-iso's result both live beside --out until the end.
iso_bytes=$(stat -c %s "$iso")
need=$((iso_bytes * 2 + 64 * 1024 * 1024))
free=$(df --output=avail -B1 "$work" | tail -n 1 | tr -d ' ')
[ "$free" -ge "$need" ] || die 2 "$out_dir has $((free / 1048576)) MiB free; the build needs $((need / 1048576)) MiB there"

# From here on a failure leaves nothing at --out (not even an older build).
rm -f "$out"

# The overlay: /etc/mdev.conf starts the picker; per node an answer image and the optional serial.
here=$(cd "$(dirname "$0")" && pwd)
overlay="$work/overlay"
mkdir -p "$overlay/etc" "$overlay/multiprox"
echo "loop0 0:0 0660 @/multiprox/picker" > "$overlay/etc/mdev.conf"
install -m 0755 "$here/picker" "$overlay/multiprox/picker"
for name in "${names[@]}"; do
  mkdir "$work/answer-$name"
  install -m 0644 "$nodes/$name.toml" "$work/answer-$name/answer.toml"
  "$mke2fs" -q -t ext2 -L proxmox-ais -d "$work/answer-$name" "$overlay/multiprox/$name.img" 1024 \
    || die 1 "mke2fs could not make the answer image for $name"
  chmod 0644 "$overlay/multiprox/$name.img"
  if [ -n "${serial_of[$name]:-}" ]; then
    printf '%s\n' "${serial_of[$name]}" > "$overlay/multiprox/$name.serial"
    chmod 0644 "$overlay/multiprox/$name.serial"
  fi
done
chmod 0755 "$overlay/etc" "$overlay/multiprox"
(cd "$overlay" && find . -mindepth 1 | sed 's|^\./||' | sort | cpio -o -H newc -R 0:0 --quiet) \
  > "$work/multiprox.cpio" || die 1 "cpio could not make the overlay"

# The menu: the stock grub.cfg with its automated block replaced by one entry per node. No timeout; the default is
# the stock Graphical entry, which asks before it does anything.
# Entries are chosen by --id, not by position.
timeout=-1
default=multiprox-graphical
extra=""
if [ -n "$autoboot" ]; then
  timeout=3
  default="multiprox-$autoboot"
  extra=" console=tty0 console=ttyS0,115200"
fi
{
  head -n "$((auto_lines - 1))" "$work/grub.cfg"
  echo "# multiprox: one entry per machine; no timeout, the default is the Graphical entry below."
  echo "set timeout-style=menu"
  echo "set timeout=$timeout"
  echo "set default=$default"
  echo
  for name in "${names[@]}"; do
    echo "menuentry 'Automated Install: $name' --id multiprox-$name --class debian --class gnu-linux --class gnu --class os {"
    echo "    echo        'Loading the Proxmox VE automatic installer for $name ...'"
    echo "    linux       /boot/linux26 $linux_options proxmox-multiprox-node=$name$extra"
    echo "    echo        'Loading initial ramdisk ...'"
    echo "    initrd      /boot/initrd.img /boot/multiprox.cpio"
    echo "}"
    echo
  done
  tail -n "+$graphical_lines" "$work/grub.cfg" \
    | sed "1s/^$anchor_graphical /$anchor_graphical --id multiprox-graphical /"
} > "$work/grub.cfg.new"

# A copy of the stock ISO, edited in place (keeping its boot setup), then prepared for partition mode. This order
# and these options are the ones that work on this ISO (readme: how it works).
cp "$iso" "$work/copy.iso"
chmod u+w "$work/copy.iso"
if ! msg=$(xorriso -dev "$work/copy.iso" -boot_image any keep -map "$work/grub.cfg.new" /boot/grub/grub.cfg \
  -map "$work/multiprox.cpio" /boot/multiprox.cpio 2>&1); then
  die 1 "xorriso could not add the menu and the overlay: $(tail -n 1 <<<"$msg")"
fi
prepare=(proxmox-auto-install-assistant prepare-iso "$work/copy.iso" --fetch-from partition
  --partition-label proxmox-ais --tmp "$work" --output "$work/final.iso")
if [ -n "$first_boot" ]; then prepare+=(--on-first-boot "$first_boot"); fi
# prepare-iso exits 0 even on errors (9.2-1): an "Error:" line or a missing result is a failure too.
rc=0
msg=$("${prepare[@]}" 2>&1) || rc=$?
if [ "$rc" != 0 ] || grep -q '^Error' <<<"$msg" || [ ! -f "$work/final.iso" ]; then
  die 1 "proxmox-auto-install-assistant prepare-iso failed: $(grep . <<<"$msg" | tail -n 1)"
fi
mv -f "$work/final.iso" "$out"

if [ -n "$autoboot" ]; then
  echo "build.sh: TEST BUILD: starts $autoboot by itself after 3 s; never write it to a stick"
fi
echo "build.sh: wrote $out"
echo "build.sh: sha256 $(sha256sum "$out" | cut -d' ' -f1)"
