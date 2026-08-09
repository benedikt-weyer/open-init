#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${OPEN_INIT_CACHE_DIR:-$root_dir/.cache}"
linux_dir="$cache_dir/linux"
build_dir="$cache_dir/linux-build"
kernel_image="$build_dir/arch/x86/boot/bzImage"
config_version=3
config_stamp="$build_dir/.open-init-kernel-config-version"
kernel_repo="${LINUX_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"

# A standard Linux kernel build needs generated parsers and ELF/BTF tooling.
# Always use the project's Nix shell so split development headers (gelf.h) are
# visible to the Linux host-tool build.
if [[ "${OPEN_INIT_KERNEL_ENV:-}" != "1" ]]; then
    command -v nix >/dev/null ||
        { printf 'Nix is required to build the Linux kernel\n' >&2; exit 1; }
    exec nix develop "$root_dir" --command env OPEN_INIT_KERNEL_ENV=1 \
        bash "${BASH_SOURCE[0]}" "$@"
fi

command -v flock >/dev/null ||
    { printf 'flock is required to serialize Linux kernel builds\n' >&2; exit 1; }
mkdir -p "$cache_dir"
exec 9>"$cache_dir/linux-build.lock"
flock 9

if [[ ! -d "$linux_dir/.git" ]]; then
    git clone --depth=1 "$kernel_repo" "$linux_dir" >&2
fi

if [[ -f "$kernel_image" && -f "$config_stamp" &&
    "$(<"$config_stamp")" == "$config_version" ]]; then
    printf '%s\n' "$kernel_image"
    exit 0
fi

mkdir -p "$build_dir"
make -C "$linux_dir" O="$build_dir" x86_64_defconfig >&2
"$linux_dir/scripts/config" --file "$build_dir/.config" \
    --enable BLK_DEV_INITRD \
    --enable RD_GZIP \
    --enable DEVTMPFS \
    --enable DEVTMPFS_MOUNT \
    --enable PROC_FS \
    --enable SYSFS \
    --enable TMPFS \
    --enable UNIX \
    --enable VT \
    --enable VT_CONSOLE \
    --enable FRAMEBUFFER_CONSOLE \
    --enable VIRTIO \
    --enable VIRTIO_PCI \
    --enable VIRTIO_GPU \
    --enable DRM \
    --enable DRM_FBDEV_EMULATION \
    --enable DRM_VIRTIO_GPU \
    --enable DRM_BOCHS \
    --enable DRM_QXL \
    --enable INPUT \
    --enable INPUT_EVDEV \
    --enable VIRTIO_INPUT >&2
make -C "$linux_dir" O="$build_dir" olddefconfig >&2
make -C "$linux_dir" O="$build_dir" -j"$(nproc)" bzImage >&2

printf '%s\n' "$config_version" > "$config_stamp"
printf '%s\n' "$kernel_image"
