#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${OPEN_INIT_CACHE_DIR:-$root_dir/.cache}"
guest_root="${GUEST_ROOT:-$root_dir/guest-root}"
archive="$cache_dir/open-init.cpio.gz"
staging_dir="$(mktemp -d "$cache_dir/initramfs-root.XXXXXX")"
archive_tmp="$(mktemp "$cache_dir/.open-init.cpio.gz.XXXXXX")"

cleanup() {
    chmod -R u+w "$staging_dir" 2>/dev/null || true
    rm -rf "$staging_dir" "$archive_tmp"
}
trap cleanup EXIT

if [[ ! -x "$guest_root/usr/bin/greetd" ]]; then
    printf 'guest-root must contain an executable usr/bin/greetd\n' >&2
    exit 1
fi
if [[ ! -x "$guest_root/usr/bin/niri-session" ]]; then
    printf 'guest-root must contain an executable usr/bin/niri-session\n' >&2
    exit 1
fi

cargo build --release --manifest-path "$root_dir/Cargo.toml" \
    --package open-init \
    --package open-service-manager >&2
init_binary="$root_dir/target/release/open-init"
service_manager_binary="$root_dir/target/release/open-service-manager"
powerctl_binary="$root_dir/target/release/open-powerctl"

printf '%s\n' 'open-init: copying guest runtime closure into initramfs' >&2
cp -a "$guest_root/." "$staging_dir/"
install -Dm755 "$init_binary" "$staging_dir/init"
install -Dm755 "$service_manager_binary" "$staging_dir/usr/bin/open-service-manager"
install -Dm755 "$powerctl_binary" "$staging_dir/usr/lib/open-init/open-powerctl"
mkdir -p "$staging_dir/sbin"
ln -sfn /usr/lib/open-init/open-powerctl "$staging_dir/sbin/shutdown"
ln -sfn /usr/lib/open-init/open-powerctl "$staging_dir/sbin/reboot"
ln -sfn /usr/lib/open-init/open-powerctl "$staging_dir/usr/bin/shutdown"
ln -sfn /usr/lib/open-init/open-powerctl "$staging_dir/usr/bin/reboot"
install -Dm755 "$root_dir/scripts/launch-niri.sh" \
    "$staging_dir/usr/lib/open-init/launch-niri"

# PID 1 is intentionally dynamically linked to glibc. Copy its interpreter
# and shared objects at their absolute paths, including Nix-store paths.
ldd "$init_binary" | awk '
    /=> \// { print $3 }
    /^[[:space:]]*\// { print $1 }
' | while IFS= read -r library; do
    [[ -f "$library" ]] || continue
    [[ -e "$staging_dir$library" ]] || install -Dm755 "$library" "$staging_dir$library"
    # Nix packages sometimes ship libraries as symlinks into other store
    # paths (e.g. gcc's multilib "-lib" wrapper outputs). chmod follows
    # symlinks, so chmod'ing one here would reach through to the host's
    # real, read-only-mounted /nix/store instead of the staged copy.
    [[ -L "$staging_dir$library" ]] || chmod 755 "$staging_dir$library"
done

# pam_unix is configured to invoke /run/wrappers/bin/unix_chkpwd. The /run
# mount is created at boot, so stage its setuid target outside it; PID 1
# creates the expected wrapper symlink after mounting /run.
unix_chkpwd="$(find "$staging_dir/nix/store" -type f -name unix_chkpwd -print -quit)"
if [[ -z "$unix_chkpwd" ]]; then
    printf '%s\n' 'open-init: linux-pam unix_chkpwd helper is missing' >&2
    exit 1
fi
install -Dm4755 "$unix_chkpwd" "$staging_dir/usr/lib/open-init/unix_chkpwd"

mesa_gbm="$(find "$staging_dir/nix/store" -type f -path '*/lib/gbm/dri_gbm.so' -print -quit)"
if [[ -z "$mesa_gbm" ]]; then
    printf '%s\n' 'open-init: Mesa GBM loader is missing' >&2
    exit 1
fi
mesa_root="${mesa_gbm%/lib/gbm/dri_gbm.so}"
ln -sfn "${mesa_root#"$staging_dir"}" "$staging_dir/usr/lib/open-init/opengl-driver"

mkdir -p "$staging_dir"/{proc,sys,dev/pts,run,tmp}
printf '%s\n' 'open-init: creating compressed initramfs archive' >&2
(
    cd "$staging_dir"
    find . -print0 | cpio --null --quiet -o --format=newc --owner=0:0 | gzip -1
) > "$archive_tmp"
mv "$archive_tmp" "$archive"

printf '%s\n' "$archive"
