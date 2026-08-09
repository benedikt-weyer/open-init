#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${OPEN_INIT_CACHE_DIR:-$root_dir/.cache}"
guest_root="${GUEST_ROOT:-$root_dir/guest-root}"
staging_dir="$cache_dir/initramfs-root"
archive="$cache_dir/open-init.cpio.gz"

if [[ ! -x "$guest_root/usr/bin/greetd" ]]; then
    printf 'guest-root must contain an executable usr/bin/greetd\n' >&2
    exit 1
fi
if [[ ! -x "$guest_root/usr/bin/niri-session" ]]; then
    printf 'guest-root must contain an executable usr/bin/niri-session\n' >&2
    exit 1
fi

cargo build --release --manifest-path "$root_dir/Cargo.toml" >&2
init_binary="$root_dir/target/release/open-init"

if [[ -d "$staging_dir" ]]; then
    chmod -R u+w "$staging_dir"
fi
rm -rf "$staging_dir"
mkdir -p "$staging_dir"
cp -a "$guest_root/." "$staging_dir/"
install -Dm755 "$init_binary" "$staging_dir/init"

# PID 1 is intentionally dynamically linked to glibc. Copy its interpreter
# and shared objects at their absolute paths, including Nix-store paths.
ldd "$init_binary" | awk '
    /=> \// { print $3 }
    /^[[:space:]]*\// { print $1 }
' | while IFS= read -r library; do
    [[ -f "$library" ]] || continue
    [[ -e "$staging_dir$library" ]] || install -Dm755 "$library" "$staging_dir$library"
done

mkdir -p "$staging_dir"/{proc,sys,dev/pts,run,tmp}
(
    cd "$staging_dir"
    find . -print0 | cpio --null --quiet -o --format=newc | gzip -9
) > "$archive"

printf '%s\n' "$archive"
