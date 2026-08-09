#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$root_dir/scripts/populate-guest-root.sh"
kernel="$("$root_dir/scripts/build-kernel.sh")"
initramfs="$("$root_dir/scripts/build-initramfs.sh")"

exec qemu-system-x86_64 \
    -machine accel=kvm:tcg \
    -m "${QEMU_MEMORY:-10G}" \
    -smp "${QEMU_CPUS:-4}" \
    -kernel "$kernel" \
    -initrd "$initramfs" \
    -append "console=ttyS0 rdinit=/init" \
    -serial stdio \
    -device virtio-vga-gl \
    -device virtio-keyboard-pci \
    -device virtio-tablet-pci \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -display gtk,gl=on,grab-on-hover=on
