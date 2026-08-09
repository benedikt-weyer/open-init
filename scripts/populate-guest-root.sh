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
    -x "$guest_root/usr/bin/wofi" &&
    -x "$guest_root/usr/bin/alacritty" &&
    -x "$guest_root/usr/bin/sudo" &&
    -x "$guest_root/usr/bin/su" &&
    -x "$guest_root/usr/bin/nix" &&
    -x "$guest_root/usr/bin/nix-daemon" &&
    -x "$guest_root/usr/bin/ip" &&
    -x "$guest_root/bin/sh" &&
    -f "$guest_root/.open-init-populated-v11" &&
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
    nixpkgs#shadow.su \
    nixpkgs#sudo \
    nixpkgs#vanilla-dmz \
    nixpkgs#wofi \
    nixpkgs#alacritty \
    nixpkgs#mesa \
    nixpkgs#nix \
    nixpkgs#cacert \
    nixpkgs#iproute2 >&2

greetd="$(nix eval --raw nixpkgs#greetd.outPath)"
tuigreet="$(nix eval --raw nixpkgs#tuigreet.outPath)"
niri="$(nix eval --raw nixpkgs#niri.outPath)"
pam="$(nix eval --raw nixpkgs#linux-pam.outPath)"
bash="$(nix eval --raw nixpkgs#bash.outPath)"
seatd="$(nix eval --raw nixpkgs#seatd.outPath)"
eudev="$(nix eval --raw nixpkgs#eudev.outPath)"
shadow_su="$(nix eval --raw nixpkgs#shadow.su.outPath)"
sudo="$(nix eval --raw nixpkgs#sudo.outPath)"
cursor_theme="$(nix eval --raw nixpkgs#vanilla-dmz.outPath)"
wofi="$(nix eval --raw nixpkgs#wofi.outPath)"
alacritty="$(nix eval --raw nixpkgs#alacritty.outPath)"
mesa="$(nix eval --raw nixpkgs#mesa.outPath)"
nix_pkg="$(nix eval --raw nixpkgs#nix.outPath)"
cacert="$(nix eval --raw nixpkgs#cacert.outPath)"
iproute2="$(nix eval --raw nixpkgs#iproute2.outPath)"

if [[ -d "$guest_root/nix" ]]; then
    chmod -R u+w "$guest_root/nix"
fi
rm -rf "$guest_root/nix"
mkdir -p "$guest_root/nix/store" "$guest_root/nix/var/nix" "$guest_root/usr/bin" "$guest_root/bin" \
    "$guest_root/etc/greetd" "$guest_root/etc/pam.d" "$guest_root/etc/udev" \
    "$guest_root/etc/sudoers.d" "$guest_root/etc/nix" "$guest_root/etc/ssl/certs" \
    "$guest_root/etc/open-service-manager/services.d" "$guest_root/usr/lib/open-init" \
    "$guest_root/home/open/.config/niri" "$guest_root/usr/share"

nix-store -qR "$greetd" "$tuigreet" "$niri" "$pam" "$bash" "$seatd" "$eudev" \
    "$shadow_su" "$sudo" \
    "$cursor_theme" "$wofi" "$alacritty" "$mesa" \
    "$nix_pkg" "$cacert" "$iproute2" |
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
ln -sfn "$wofi/bin/wofi" "$guest_root/usr/bin/wofi"
ln -sfn "$alacritty/bin/alacritty" "$guest_root/usr/bin/alacritty"
ln -sfn "$bash/bin/bash" "$guest_root/bin/sh"
install -Dm4755 "$shadow_su/bin/su" "$guest_root/usr/lib/open-init/su"
install -Dm4755 "$sudo/bin/sudo" "$guest_root/usr/lib/open-init/sudo"
ln -sfn /usr/lib/open-init/su "$guest_root/usr/bin/su"
ln -sfn /usr/lib/open-init/sudo "$guest_root/usr/bin/sudo"
ln -sfn "$eudev/var/lib/udev/rules.d" "$guest_root/etc/udev/rules.d"
ln -sfn "$cursor_theme/share/icons" "$guest_root/usr/share/icons"

for binary in "$nix_pkg"/bin/*; do
    ln -sfn "$binary" "$guest_root/usr/bin/$(basename "$binary")"
done
ln -sfn "$iproute2/bin/ip" "$guest_root/usr/bin/ip"
ln -sfn "$cacert/etc/ssl/certs/ca-bundle.crt" \
    "$guest_root/etc/ssl/certs/ca-certificates.crt"

mkdir -p "$guest_root/usr/share/applications"
ln -sfn "$alacritty/share/applications/Alacritty.desktop" \
    "$guest_root/usr/share/applications/Alacritty.desktop"

cat > "$guest_root/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
greeter:x:1000:1000:Greeter:/var/lib/greetd:/bin/sh
open:x:1001:1001:Open Init User:/home/open:/bin/sh
nixbld1:x:30001:30000:Nix build user 1:/var/empty:/bin/sh
nixbld2:x:30002:30000:Nix build user 2:/var/empty:/bin/sh
nixbld3:x:30003:30000:Nix build user 3:/var/empty:/bin/sh
nixbld4:x:30004:30000:Nix build user 4:/var/empty:/bin/sh
nixbld5:x:30005:30000:Nix build user 5:/var/empty:/bin/sh
nixbld6:x:30006:30000:Nix build user 6:/var/empty:/bin/sh
nixbld7:x:30007:30000:Nix build user 7:/var/empty:/bin/sh
nixbld8:x:30008:30000:Nix build user 8:/var/empty:/bin/sh
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
nixbld:x:30000:nixbld1,nixbld2,nixbld3,nixbld4,nixbld5,nixbld6,nixbld7,nixbld8
EOF
cat > "$guest_root/etc/shadow" <<'EOF'
root:$6$open-init-root$APaycsMA.T7KWL3c0rDr9h6vsWEL4AL9vczr0TiIOMCnhhXDaY80HisHbmt.6n5fjNyHOTsF/BWvbMm5fR9Tu0:1:0:99999:7:::
greeter:!:1:0:99999:7:::
open::1:0:99999:7:::
nixbld1:!:1:0:99999:7:::
nixbld2:!:1:0:99999:7:::
nixbld3:!:1:0:99999:7:::
nixbld4:!:1:0:99999:7:::
nixbld5:!:1:0:99999:7:::
nixbld6:!:1:0:99999:7:::
nixbld7:!:1:0:99999:7:::
nixbld8:!:1:0:99999:7:::
EOF
chmod 600 "$guest_root/etc/shadow"
cat > "$guest_root/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
EOF
cat > "$guest_root/etc/resolv.conf" <<'EOF'
nameserver 10.0.2.3
EOF
cat > "$guest_root/etc/nix/nix.conf" <<'EOF'
build-users-group = nixbld
sandbox = true
experimental-features = nix-command flakes
trusted-users = root open
EOF
cat > "$guest_root/etc/pam.d/greetd" <<EOF
auth      required  $pam/lib/security/pam_unix.so nullok
account   required  $pam/lib/security/pam_unix.so
session   required  $pam/lib/security/pam_unix.so
EOF
cat > "$guest_root/etc/pam.d/su" <<EOF
auth      required  $pam/lib/security/pam_unix.so
account   required  $pam/lib/security/pam_unix.so
session   required  $pam/lib/security/pam_unix.so
EOF
cat > "$guest_root/etc/pam.d/sudo" <<EOF
auth      required  $pam/lib/security/pam_permit.so
account   required  $pam/lib/security/pam_permit.so
session   required  $pam/lib/security/pam_permit.so
EOF
chmod u+w "$guest_root/etc/sudoers" "$guest_root/etc/sudoers.d/open" 2>/dev/null || true
cat > "$guest_root/etc/sudoers.d/open" <<'EOF'
open ALL=(ALL) NOPASSWD: ALL
EOF
cat > "$guest_root/etc/sudoers" <<'EOF'
#includedir /etc/sudoers.d
EOF
chmod 440 "$guest_root/etc/sudoers.d/open"
chmod 440 "$guest_root/etc/sudoers"

cat > "$guest_root/home/open/.config/niri/config.kdl" <<'EOF'
environment {
    XDG_DATA_DIRS "/usr/share"
    NIX_SSL_CERT_FILE "/etc/ssl/certs/ca-certificates.crt"
}

binds {
    Super+Space { spawn "wofi" "--show" "drun"; }
    Super+C { spawn "alacritty"; }
    Super+X { close-window; }
}
EOF

touch "$guest_root/.open-init-populated-v11"
printf '%s\n' "guest-root populated; log in as 'open' with an empty password"
