#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
guest_root="${GUEST_ROOT:-$root_dir/guest-root}"

command -v nix >/dev/null ||
    { printf 'Nix is required to populate guest-root automatically\n' >&2; exit 1; }

if [[ "${FORCE_POPULATE:-0}" != "1" &&
    -x "$guest_root/usr/bin/greetd" &&
    -x "$guest_root/usr/bin/niri-session" &&
    -x "$guest_root/usr/bin/seatd" &&
    -x "$guest_root/usr/bin/udevd" &&
    -x "$guest_root/usr/bin/udevadm" &&
    -x "$guest_root/bin/sh" &&
    -f "$guest_root/.open-init-populated-v6" &&
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
    nixpkgs#seatd \
    nixpkgs#eudev \
    nixpkgs#vanilla-dmz \
    nixpkgs#mesa >&2

greetd="$(nix eval --raw nixpkgs#greetd.outPath)"
tuigreet="$(nix eval --raw nixpkgs#tuigreet.outPath)"
niri="$(nix eval --raw nixpkgs#niri.outPath)"
pam="$(nix eval --raw nixpkgs#linux-pam.outPath)"
bash="$(nix eval --raw nixpkgs#bash.outPath)"
seatd="$(nix eval --raw nixpkgs#seatd.outPath)"
eudev="$(nix eval --raw nixpkgs#eudev.outPath)"
cursor_theme="$(nix eval --raw nixpkgs#vanilla-dmz.outPath)"
mesa="$(nix eval --raw nixpkgs#mesa.outPath)"

if [[ -d "$guest_root/nix" ]]; then
    chmod -R u+w "$guest_root/nix"
fi
rm -rf "$guest_root/nix"
mkdir -p "$guest_root/nix/store" "$guest_root/usr/bin" "$guest_root/bin" \
    "$guest_root/etc/greetd" "$guest_root/etc/pam.d" "$guest_root/etc/udev" \
    "$guest_root/home/open" "$guest_root/usr/share"

nix-store -qR "$greetd" "$tuigreet" "$niri" "$pam" "$bash" "$seatd" "$eudev" \
    "$cursor_theme" "$mesa" |
    sort -u |
    while IFS= read -r store_path; do
        cp -a "$store_path" "$guest_root/nix/store/"
    done

ln -sfn "$greetd/bin/greetd" "$guest_root/usr/bin/greetd"
ln -sfn "$tuigreet/bin/tuigreet" "$guest_root/usr/bin/tuigreet"
ln -sfn "$niri/bin/niri" "$guest_root/usr/bin/niri"
ln -sfn "$niri/bin/niri-session" "$guest_root/usr/bin/niri-session"
ln -sfn "$seatd/bin/seatd" "$guest_root/usr/bin/seatd"
ln -sfn "$eudev/bin/udevd" "$guest_root/usr/bin/udevd"
ln -sfn "$eudev/bin/udevadm" "$guest_root/usr/bin/udevadm"
ln -sfn "$bash/bin/bash" "$guest_root/bin/sh"
ln -sfn "$eudev/var/lib/udev/rules.d" "$guest_root/etc/udev/rules.d"
ln -sfn "$cursor_theme/share/icons" "$guest_root/usr/share/icons"

cat > "$guest_root/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
greeter:x:1000:1000:Greeter:/var/lib/greetd:/bin/sh
open:x:1001:1001:Open Init User:/home/open:/bin/sh
EOF
cat > "$guest_root/etc/group" <<'EOF'
root:x:0:
tty:x:5:greeter,open
disk:x:6:
lp:x:7:
kmem:x:15:
dialout:x:20:greeter,open
cdrom:x:24:
tape:x:26:
seat:x:100:open
greeter:x:1000:
open:x:1001:
video:x:27:open
input:x:28:open
audio:x:29:
kvm:x:36:
sgx:x:108:
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
account   required  $pam/lib/security/pam_unix.so
session   required  $pam/lib/security/pam_unix.so
EOF

touch "$guest_root/.open-init-populated-v6"
printf '%s\n' "guest-root populated; log in as 'open' with an empty password"
