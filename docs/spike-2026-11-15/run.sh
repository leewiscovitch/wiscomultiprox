#!/bin/bash
# run.sh <name> <dmi-serial> <disk-serial> <mac> <seconds> [nostick]
set -u
P=$(dirname "$(readlink -f "$0")"); name=$1
[ -f "$P/disk-$name.raw" ] || truncate -s 16G "$P/disk-$name.raw"
[ -f "$P/vars-$name.fd" ] || cp /usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd "$P/vars-$name.fd"
: > "$P/serial-$name.log"
stick=(-drive "if=none,id=stick,format=raw,readonly=on,file=$P/final.iso" -device qemu-xhci -device usb-storage,drive=stick,removable=on,bootindex=2)
[ "${6:-}" = nostick ] && stick=(-device qemu-xhci)
timeout "$5" sudo -n kvm -name "labx-spike-$name" -machine q35 -m 4096 -smp 4 -cpu host \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$P/vars-$name.fd" \
  -smbios "type=1,serial=$2" \
  -drive "if=none,id=d0,format=raw,file=$P/disk-$name.raw" -device "virtio-blk-pci,drive=d0,serial=$3,bootindex=1" \
  "${stick[@]}" \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device "virtio-net-pci,netdev=n0,mac=$4" \
  -display none -monitor unix:$P/mon-$name.sock,server,nowait -serial "file:$P/serial-$name.log" -no-reboot
echo "qemu exit: $?"
