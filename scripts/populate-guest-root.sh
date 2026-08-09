#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
guest_root="${GUEST_ROOT:-$root_dir/guest-root}"

command -v nix >/dev/null ||
    { printf 'Nix is required to populate guest-root automatically\n' >&2; exit 1; }

if [[ "${FORCE_POPULATE:-0}" != "1" &&
    -x "$guest_root/usr/bin/greetd" &&
    -x "$guest_root/usr/bin/niri-session" &&
    -x "$guest_root/bin/sh" &&
    -f "$guest_root/.open-init-populated-v2" &&
    -d "$guest_root/nix/store" ]]; then
    printf '%s\n' 'guest-root already populated'
    exit 0
fi

# Nix preserves all runtime references in /nix/store. Copying the transitive
# closures creates a self-contained guest without relying on host libraries.
nix build --no-link \
    nixpkgs#greetd \
    nixpkgs#tuigreet \
    nixpkgs#niri \
    nixpkgs#linux-pam \
    nixpkgs#bash \
    nixpkgs#mesa >&2

greetd="$(nix eval --raw nixpkgs#greetd.outPath)"
tuigreet="$(nix eval --raw nixpkgs#tuigreet.outPath)"
niri="$(nix eval --raw nixpkgs#niri.outPath)"
pam="$(nix eval --raw nixpkgs#linux-pam.outPath)"
bash="$(nix eval --raw nixpkgs#bash.outPath)"
mesa="$(nix eval --raw nixpkgs#mesa.outPath)"

if [[ -d "$guest_root/nix" ]]; then
    chmod -R u+w "$guest_root/nix"
fi
rm -rf "$guest_root/nix"
mkdir -p "$guest_root/nix/store" "$guest_root/usr/bin" "$guest_root/bin" \
    "$guest_root/etc/greetd" "$guest_root/etc/pam.d" "$guest_root/home/open"

nix-store -qR "$greetd" "$tuigreet" "$niri" "$pam" "$bash" "$mesa" |
    sort -u |
    while IFS= read -r store_path; do
        cp -a "$store_path" "$guest_root/nix/store/"
    done

ln -sfn "$greetd/bin/greetd" "$guest_root/usr/bin/greetd"
ln -sfn "$tuigreet/bin/tuigreet" "$guest_root/usr/bin/tuigreet"
ln -sfn "$niri/bin/niri" "$guest_root/usr/bin/niri"
ln -sfn "$niri/bin/niri-session" "$guest_root/usr/bin/niri-session"
ln -sfn "$bash/bin/bash" "$guest_root/bin/sh"

cat > "$guest_root/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
greeter:x:1000:1000:Greeter:/var/lib/greetd:/bin/sh
open:x:1001:1001:Open Init User:/home/open:/bin/sh
EOF
cat > "$guest_root/etc/group" <<'EOF'
root:x:0:
greeter:x:1000:
open:x:1001:
video:x:27:open
input:x:28:open
EOF
cat > "$guest_root/etc/shadow" <<'EOF'
root:*:1:0:99999:7:::
greeter:!:1:0:99999:7:::
open::1:0:99999:7:::
EOF
chmod 600 "$guest_root/etc/shadow"
cat > "$guest_root/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
EOF
cat > "$guest_root/etc/pam.d/greetd" <<EOF
auth      required  $pam/lib/security/pam_unix.so nullok
account   required  $pam/lib/security/pam_permit.so
session   required  $pam/lib/security/pam_unix.so
EOF

touch "$guest_root/.open-init-populated-v2"
printf '%s\n' "guest-root populated; log in as 'open' with an empty password"
