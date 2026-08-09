#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$root_dir/scripts/populate-guest-root.sh"
kernel="$("$root_dir/scripts/build-kernel.sh")"
initramfs="$("$root_dir/scripts/build-initramfs.sh")"

# The clipboard bridge connects the guest's niri session to the host
# clipboard over a dedicated virtio-serial port. QEMU owns the UNIX socket
# (server=on); the host-side agent below is the client.
clipboard_socket="$(mktemp -u "${TMPDIR:-/tmp}/open-init-clipboard.XXXXXX")"
clipboard_agent_binary="$root_dir/target/release/open-clipboard-agent"
clipboard_agent_pid=""

cleanup() {
    [[ -n "$clipboard_agent_pid" ]] && kill "$clipboard_agent_pid" 2>/dev/null || true
    rm -f "$clipboard_socket"
}
trap cleanup EXIT

"$clipboard_agent_binary" --transport unix-socket --path "$clipboard_socket" \
    --copy-cmd "${OPEN_INIT_CLIPBOARD_COPY_CMD:-wl-copy}" \
    --paste-cmd "${OPEN_INIT_CLIPBOARD_PASTE_CMD:-wl-paste --no-newline}" &
clipboard_agent_pid=$!

qemu-system-x86_64 \
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
    -device virtio-serial-pci \
    -chardev socket,path="$clipboard_socket",server=on,wait=off,id=clipboard0 \
    -device virtserialport,chardev=clipboard0,name=org.open-init.clipboard \
    -display gtk,gl=on,grab-on-hover=on
