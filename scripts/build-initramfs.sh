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
    printf '%s\n' 'open-init: removing previous initramfs staging tree' >&2
    chmod -R u+w "$staging_dir"
fi
rm -rf "$staging_dir"
mkdir -p "$staging_dir"
printf '%s\n' 'open-init: copying guest runtime closure into initramfs' >&2
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

# pam_unix invokes this helper after greetd drops to the greeter account.
# Nix store files cannot carry setuid bits, so add the required guest-only
# privilege after copying the runtime closure.
find "$staging_dir/nix/store" -type f -name unix_chkpwd -exec chmod 4755 {} +

mkdir -p "$staging_dir"/{proc,sys,dev/pts,run,tmp}
printf '%s\n' 'open-init: creating compressed initramfs archive' >&2
(
    cd "$staging_dir"
    find . -print0 | cpio --null --quiet -o --format=newc --owner=0:0 | gzip -1
) > "$archive"

printf '%s\n' "$archive"
