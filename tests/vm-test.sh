#!/bin/bash
# The VM test: boots test builds in QEMU/KVM (UEFI) and checks the refusals, a full install, the installed
# system, and the menu's timeout (the real stick left in falls through to the disk). Made-up machines only; nothing here touches a real disk or a Proxmox guest.
# Run: MULTIPROX_TEST_ISO=<stock proxmox-ve ISO> tests/vm-test.sh        (about 15 minutes)
# Some tests only: MULTIPROX_VM_TESTS="7 8" (6 and 7 boot the disk test 5 installs, so they bring 5 along).
# Needs: KVM, OVMF (/usr/share/pve-edk2-firmware, or MULTIPROX_OVMF_DIR), `sudo -n kvm` (it calls sudo itself),
# ssh, and 8 GB free in MULTIPROX_TEST_TMP (default /var/tmp). Exit 0 only if every test passed.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
need_iso

ovmf="${MULTIPROX_OVMF_DIR:-/usr/share/pve-edk2-firmware}"
for f in "$ovmf/OVMF_CODE_4M.fd" "$ovmf/OVMF_VARS_4M.fd"; do
  [ -f "$f" ] || { echo "vm-test.sh: no $f (set MULTIPROX_OVMF_DIR)" >&2; exit 2; }
done
[ -e /dev/kvm ] || { echo "vm-test.sh: no /dev/kvm" >&2; exit 2; }
if ! sudo -n kvm --version > /dev/null 2>&1; then
  echo "vm-test.sh: 'sudo -n kvm' does not work; this test starts QEMU with sudo (no password prompt)" >&2
  exit 2
fi

base="${MULTIPROX_TEST_TMP:-/var/tmp}"
free=$(df --output=avail -B1 "$base" | tail -n 1 | tr -d ' ')
[ "$free" -ge $((8 * 1024 * 1024 * 1024)) ] || { echo "vm-test.sh: $base has less than 8 GB free" >&2; exit 2; }
# Which tests run: MULTIPROX_VM_TESTS, default all.
selected=" ${MULTIPROX_VM_TESTS:-1 2 3 4 5 6 7 8} "
for t in $selected; do
  case "$t" in [1-8]) ;; *) echo "vm-test.sh: MULTIPROX_VM_TESTS: no test '$t' (1 to 8)" >&2; exit 2 ;; esac
done
want() { local t; for t in "$@"; do [[ "$selected" == *" $t "* ]] && return 0; done; return 1; }
if want 6 7 && ! want 5; then selected+="5 "; echo "vm-test.sh: tests 6 and 7 boot test 5's install: running 5 too"; fi

tmp=$(mktemp -d "$base/multiprox-vm-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---- the test machines' nodes folder and the two test builds

ssh-keygen -q -t ed25519 -N '' -C multiprox-vm-test -f "$tmp/key"
hash=$(openssl passwd -6 "$(head -c 24 /dev/urandom | base64)")
mkdir "$tmp/nodes"
node_toml() { # <name> <mac suffix> <disk serial>
  cat <<EOF
[global]
keyboard = "en-us"
country = "us"
fqdn = "$1.example.org"
mailto = "root@localhost"
timezone = "America/New_York"
root-password-hashed = "$hash"
root-ssh-keys = [ "$(cat "$tmp/key.pub")" ]
reboot-on-error = false

[network]
source = "from-answer"
cidr = "10.0.2.15/24"
dns = "10.0.2.3"
gateway = "10.0.2.2"
filter.ID_NET_NAME_MAC = "enx525400aabb$2"

[disk-setup]
filesystem = "zfs"
zfs.raid = "raid0"
filter.ID_SERIAL = "$3"

[first-boot]
source = "from-iso"
ordering = "before-network"
EOF
}
node_toml vm1 01 VMDISK01 > "$tmp/nodes/vm1.toml"
echo VMSERIAL1 > "$tmp/nodes/vm1.serial"
node_toml vm2 02 VMDISK02 > "$tmp/nodes/vm2.toml" # no vm2.serial: no early check for vm2

for n in vm1 vm2; do
  if [ $n = vm1 ] && ! want 1 2 3 5; then continue; fi
  if [ $n = vm2 ] && ! want 4; then continue; fi
  echo "== building the test ISO that starts $n"
  MULTIPROX_TEST_AUTOBOOT=$n "$repo/build.sh" --iso "$MULTIPROX_TEST_ISO" --nodes "$tmp/nodes" \
    --out "$tmp/$n.iso" --first-boot "$repo/examples/first-boot.sh" | sed 's/^/   /'
done

if want 7; then
  echo "== building the stick as it is written for real (no test option: default timeout)"
  "$repo/build.sh" --iso "$MULTIPROX_TEST_ISO" --nodes "$tmp/nodes" --out "$tmp/real.iso" \
    --first-boot "$repo/examples/first-boot.sh" | sed 's/^/   /'
fi
if want 8; then
  echo "== building a stick with a 10 s timeout (test 8)"
  "$repo/build.sh" --iso "$MULTIPROX_TEST_ISO" --nodes "$tmp/nodes" --out "$tmp/t10.iso" --timeout 10 | sed 's/^/   /'
fi

# ---- running a test machine

disk_size=$((16 * 1024 * 1024 * 1024))
new_disk() { rm -f "$1"; truncate -s "$disk_size" "$1"; }
untouched() { cmp -s -n "$disk_size" "$1" /dev/zero; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# The firmware's boot order: the disk first, the stick second. stick_first=1 (set for one call) puts the stick first.
# vm <test> <iso|none> <dmi serial> <disk file> <disk serial> <mac> <seconds> [<pattern>...]
# Starts QEMU under `timeout`; stops it early once every pattern is in the serial log. Sets vm_rc (QEMU's exit
# code, 124 if timeout stopped it) and leaves the log at $tmp/serial-<test>.log. Never pkill: this host runs real
# guests; only the PID started here is stopped.
vm() {
  local t="$1" iso="$2" dmi="$3" disk="$4" dserial="$5" mac="$6" secs="$7" pid all p
  shift 7
  local log="$tmp/serial-$t.log"
  : > "$log"
  cp "$ovmf/OVMF_VARS_4M.fd" "$tmp/vars-$t.fd"
  local stick=(-device qemu-xhci) disk_index=1 stick_index=2
  if [ "${stick_first:-0}" = 1 ]; then disk_index=2 stick_index=1; fi
  if [ "$iso" != none ]; then
    stick+=(-drive "if=none,id=stick,format=raw,readonly=on,file=$iso"
      -device usb-storage,drive=stick,removable=on,bootindex=$stick_index)
  fi
  timeout "$secs" sudo -n kvm -name "multiprox-vm-test-$t" -machine q35 -m 4096 -smp 4 -cpu host \
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf/OVMF_CODE_4M.fd" \
    -drive "if=pflash,format=raw,file=$tmp/vars-$t.fd" \
    -smbios "type=1,serial=$dmi" \
    -drive "if=none,id=d0,format=raw,file=$disk" -device "virtio-blk-pci,drive=d0,serial=$dserial,bootindex=$disk_index" \
    "${stick[@]}" \
    -netdev "user,id=n0${ssh_port:+,hostfwd=tcp:127.0.0.1:$ssh_port-:22}" -device "virtio-net-pci,netdev=n0,mac=$mac" \
    -display none -serial "file:$log" -no-reboot > "$tmp/qemu-$t.out" 2>&1 &
  pid=$!
  if [ $# -gt 0 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      all=1
      for p in "$@"; do grep -aqF -- "$p" "$log" || all=0; done
      if [ "$all" = 1 ]; then sleep 3; kill "$pid" 2>/dev/null || true; break; fi
      sleep 2
    done
  fi
  vm_rc=0
  wait "$pid" || vm_rc=$?
}

has() { grep -aqF -- "$2" "$tmp/serial-$1.log"; }
show_log() { # the last 30 lines that are not kernel messages
  grep -av '^\[ *[0-9]*\.[0-9]*\]' "$tmp/serial-$1.log" | tr -d '\r' | sed 's/\x1b\[[0-9;=?]*[a-zA-Z]//g' \
    | grep -v '^\s*$' | tail -n 30 | sed 's/^/        | /'
}

results=()
result() { # <test> <pass 0|1> <what>
  if [ "$2" = 0 ]; then
    echo "ok    $1  $3"; test_passed=$((test_passed + 1)); results+=("| $1 | ok | $3 |")
  else
    echo "FAIL  $1  $3"; show_log "$1"; test_failed=$((test_failed + 1)); results+=("| $1 | FAIL | $3 |")
  fi
}

sshq() {
  ssh -q -i "$tmp/key" -p "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 root@127.0.0.1 "$@"
}
disk5="$tmp/disk5.raw"   # test 5 installs vm1 on it; 6 and 7 boot it
refused="REFUSED: this machine's serial number is 'WRONG'"
found="Found answer file on partition"
nomatch="filter did not match any devices"
nic_nomatch="filter did not match any device"

if want 1; then
echo "== 1: wrong machine serial"
d="$tmp/disk1.raw"; new_disk "$d"
vm 1 "$tmp/vm1.iso" WRONG "$d" VMDISK01 52:54:00:aa:bb:01 60 "$refused"
if has 1 "$refused" && untouched "$d"; then r=0; else r=1; fi; result 1 $r "vm1 entry, serial WRONG: picker refuses, disk untouched"
fi

if want 2; then
echo "== 2: right serial, wrong disk"
d="$tmp/disk2.raw"; new_disk "$d"
vm 2 "$tmp/vm1.iso" VMSERIAL1 "$d" OTHERDISK 52:54:00:aa:bb:01 150 "$found" "$nomatch"
if has 2 "$found" && has 2 "$nomatch" && untouched "$d"; then r=0; else r=1; fi; result 2 $r "vm1 entry, wrong disk serial: installer's filter refuses, disk untouched"
fi

if want 3; then
echo "== 3: right serial and disk, wrong MAC"
d="$tmp/disk3.raw"; new_disk "$d"
# The installer words it "any device" for a network card ("any devices" for a disk).
vm 3 "$tmp/vm1.iso" VMSERIAL1 "$d" VMDISK01 52:54:00:aa:bb:99 150 "$found" "$nic_nomatch"
if has 3 "$nic_nomatch" && ! has 3 "$nomatch" && untouched "$d"; then r=0; else r=1; fi; result 3 $r "vm1 entry, wrong MAC: installer's filter refuses, disk untouched"
fi

if want 4; then
echo "== 4: a node without a .serial, wrong disk"
d="$tmp/disk4.raw"; new_disk "$d"
vm 4 "$tmp/vm2.iso" ANYTHING "$d" OTHERDISK 52:54:00:aa:bb:02 150 "[multiprox] vm2: its answer file is on" "$nomatch"
if has 4 "[multiprox] vm2: its answer file is on" && has 4 "$nomatch" && untouched "$d"; then r=0; else r=1; fi
result 4 $r "vm2 entry (no serial file), wrong disk: no early check, installer's filter refuses, disk untouched"
fi

if want 5; then
echo "== 5: the right machine: a full install"
d="$disk5"; new_disk "$d"
start=$SECONDS
vm 5 "$tmp/vm1.iso" VMSERIAL1 "$d" VMDISK01 52:54:00:aa:bb:01 900
if [ "$vm_rc" = 0 ] && has 5 "Installation done"; then r=0; else r=1; fi
result 5 $r "vm1 entry, vm1's machine: installs unattended and reboots ($((SECONDS - start)) s, QEMU exit $vm_rc)"
fi

if want 6; then
echo "== 6: the installed system"
ssh_out="$tmp/ssh-6.txt"
ssh_port=$(free_port)
vm 6 none VMSERIAL1 "$disk5" VMDISK01 52:54:00:aa:bb:01 200 &
vm6=$!
up=1
for _ in $(seq 1 60); do
  if sshq true 2>/dev/null; then up=0; break; fi
  sleep 3
done
check6() {
  [ "$up" = 0 ] || { echo "no SSH"; return 1; }
  sshq 'hostname -f; ip -br -4 addr; zpool status -x; ls /root/multiprox-first-boot-ran; cat /etc/kernel/cmdline /proc/cmdline' \
    > "$ssh_out" 2>&1 || return 1
  grep -qx 'vm1.example.org' "$ssh_out" || return 1
  grep -q '10.0.2.15/24' "$ssh_out" || return 1
  grep -q 'all pools are healthy' "$ssh_out" || return 1
  grep -qx '/root/multiprox-first-boot-ran' "$ssh_out" || return 1
  ! grep -q multiprox <(sshq 'cat /etc/kernel/cmdline /proc/cmdline') || return 1
}
rc6=0; check6 || rc6=$?
sshq poweroff 2>/dev/null || true
wait "$vm6" || true
[ "$rc6" = 0 ] || sed 's/^/        > /' "$ssh_out" 2>/dev/null || true
result 6 "$rc6" "boots from disk: vm1.example.org, 10.0.2.15/24, pool healthy, first-boot ran, no multiprox option left"
fi

if want 7; then
echo "== 7: the real stick left in, booted before the disk: after the timeout it leaves for the disk"
leave="Leave the stick: boot from the local disk"
start=$SECONDS
ssh_port=$(free_port)
stick_first=1 vm 7 "$tmp/real.iso" VMSERIAL1 "$disk5" VMDISK01 52:54:00:aa:bb:01 400 &
vm7=$!
up=1
for _ in $(seq 1 120); do
  if sshq true 2>/dev/null; then up=0; break; fi
  sleep 3
done
took=$((SECONDS - start))
check7() {
  [ "$up" = 0 ] || { echo "no SSH"; return 1; }
  [ "$(sshq 'hostname -f')" = vm1.example.org ] || return 1
  # GRUB's menu goes to the serial console too; nothing of an installer may have started.
  has 7 "$leave" || { echo "no menu"; return 1; }
  has 7 "multiprox: leaving the stick for (hd" || { echo "no chainloaded disk"; return 1; }
  ! has 7 "Loading the Proxmox VE" && ! has 7 "[multiprox]" && ! has 7 "Loading Proxmox VE Installer" \
    || { echo "an installer entry started"; return 1; }
  # It waited the 90 s before leaving.
  [ "$took" -ge 90 ] || { echo "up after $took s, before the timeout"; return 1; }
}
rc7=0; check7 || rc7=$?
sshq poweroff 2>/dev/null || true
wait "$vm7" || true
result 7 "$rc7" "the stick left in, first in the boot order: menu waits 90 s, then vm1 boots from its disk (SSH after $took s)"
fi

if want 8; then
echo "== 8: the stick left in, no disk with a boot loader: back to the firmware, nothing starts"
d="$tmp/disk8.raw"; new_disk "$d"
stick_first=1 vm 8 "$tmp/t10.iso" VMSERIAL1 "$d" VMDISK01 52:54:00:aa:bb:01 90 "Please select boot device"
if has 8 "multiprox: no other disk has a UEFI boot loader" && has 8 "BootManagerMenuApp" \
  && ! has 8 "Loading the Proxmox VE" && ! has 8 "[multiprox]" && ! has 8 "Loading Proxmox VE Installer" \
  && untouched "$d"; then r=0; else r=1; fi
result 8 $r "10 s stick left in, blank disk: no loader found, the firmware's boot menu, nothing installed, disk untouched"
fi

echo
echo "| # | Result | Test |"
echo "|---|---|---|"
printf '%s\n' "${results[@]}"
echo
finish
