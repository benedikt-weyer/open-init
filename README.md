# open-init

`open-init` is a small Rust PID 1 for a Linux initramfs. It is dynamically
linked against glibc, mounts the kernel filesystems, reaps orphaned processes,
and restarts `greetd` if it exits. The greeter launches `niri-session` after a
successful login.

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
