#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${OPEN_INIT_CACHE_DIR:-$root_dir/.cache}"
linux_dir="$cache_dir/linux"
build_dir="$cache_dir/linux-build"
kernel_image="$build_dir/arch/x86/boot/bzImage"
kernel_repo="${LINUX_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"

# A standard Linux kernel build needs generated parsers and ELF/BTF tooling.
# On Nix hosts obtain them transiently instead of requiring global installs.
if ! command -v flex >/dev/null || ! command -v bison >/dev/null || ! command -v bc >/dev/null; then
    command -v nix >/dev/null ||
        { printf 'flex, bison, and bc are required to build the Linux kernel\n' >&2; exit 1; }
    exec nix shell --impure \
        nixpkgs#bc \
        nixpkgs#bison \
        nixpkgs#flex \
        nixpkgs#openssl \
        nixpkgs#elfutils \
        nixpkgs#pahole \
        nixpkgs#perl \
        nixpkgs#gcc \
        nixpkgs#binutils \
        --command bash "${BASH_SOURCE[0]}" "$@"
fi

if [[ ! -d "$linux_dir/.git" ]]; then
    mkdir -p "$cache_dir"
    git clone --depth=1 "$kernel_repo" "$linux_dir" >&2
fi

if [[ -f "$kernel_image" ]]; then
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
    --enable VIRTIO \
    --enable VIRTIO_PCI \
    --enable VIRTIO_GPU \
    --enable DRM \
    --enable DRM_VIRTIO_GPU \
    --enable DRM_BOCHS \
    --enable DRM_QXL >&2
make -C "$linux_dir" O="$build_dir" olddefconfig >&2
make -C "$linux_dir" O="$build_dir" -j"$(nproc)" bzImage >&2

printf '%s\n' "$kernel_image"
