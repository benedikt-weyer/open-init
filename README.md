# open-init

`open-init` is a small Rust PID 1 for a Linux initramfs. It is dynamically
linked against glibc, mounts the kernel filesystems, reaps orphaned processes,
and restarts `open-service-manager` if it exits. The service manager
supervises `greetd`; the greeter launches `niri-session` after a successful
login.

## Services

`open-service-manager` loads every `*.toml` file in
`/etc/open-service-manager/services.d` and starts its command directly (it
does not invoke a shell). A unit file has this form:

```toml
command = "/usr/bin/example"
args = ["--foreground"] # optional
restart = "always"      # "always", "on-failure", or "never"
```

The initramfs includes units for `greetd` and `seatd`. Add further unit files
under [`guest-root/etc/open-service-manager/services.d`](guest-root/etc/open-service-manager/services.d)
to include them in the guest.

## Run in QEMU

With Nix installed, run:

```sh
./scripts/run-qemu.sh
```

The runner automatically downloads the Nix closures for glibc, greetd,
tuigreet, niri, Mesa, and PAM; copies them to `guest-root/nix/store`; and
creates the users and PAM configuration. The supplied
[`guest-root/etc/greetd/config.toml`](guest-root/etc/greetd/config.toml) tells
greetd to authenticate through tuigreet and start niri for the authenticated
user.

The populated root is cached. Run `FORCE_POPULATE=1
./scripts/populate-guest-root.sh` to replace it after changing package inputs.

The generated demonstration account is `open` with an empty password. It is
appropriate only for a disposable QEMU guest; replace `/etc/shadow` and the
PAM configuration before using it elsewhere.

On its first run the script clones the upstream Linux repository into
`.cache/linux`, builds a minimal x86_64 kernel in `.cache/linux-build`, and
caches its `bzImage`. Later runs reuse that image. Set `OPEN_INIT_CACHE_DIR` to
place the cache elsewhere or `LINUX_REPOSITORY` to use a kernel fork.

The generated initramfs contains `guest-root` and the `open-init` executable
with its glibc dynamic loader and shared-library dependencies. It is rebuilt
each launch so changes to the init program or guest root take effect.

QEMU opens a GTK display using virtio-gpu with OpenGL and mirrors the serial
console to the invoking terminal. A working niri session needs host QEMU OpenGL
support and matching guest Mesa/virtio GPU libraries in `guest-root`.
