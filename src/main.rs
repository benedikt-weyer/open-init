//! `open-init` is a deliberately small Linux PID 1.
//!
//! It mounts the kernel filesystems, supervises greetd, and reaps orphaned
//! children. greetd owns login and launches `niri-session` for the configured
//! user, rather than PID 1 starting a compositor itself.

use std::{
    ffi::CString,
    fs, io,
    os::unix::fs::{symlink, PermissionsExt},
    process::{Child, Command},
    thread,
    time::Duration,
};

const GROOT: &str = "/usr/bin/greetd";
const PAM_HELPER: &str = "/usr/lib/open-init/unix_chkpwd";
const PAM_WRAPPER: &str = "/run/wrappers/bin/unix_chkpwd";
const OPEN_RUNTIME_DIR: &str = "/run/user/1001";

fn mount(source: &str, target: &str, fstype: &str, flags: libc::c_ulong) -> io::Result<()> {
    fs::create_dir_all(target)?;
    let source = CString::new(source)?;
    let target = CString::new(target)?;
    let fstype = CString::new(fstype)?;

    let result = unsafe {
        libc::mount(
            source.as_ptr(),
            target.as_ptr(),
            fstype.as_ptr(),
            flags,
            std::ptr::null(),
        )
    };
    if result == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn mount_kernel_filesystems() {
    for (source, target, fstype, flags) in [
        ("proc", "/proc", "proc", 0),
        ("sysfs", "/sys", "sysfs", 0),
        ("devtmpfs", "/dev", "devtmpfs", libc::MS_NOSUID),
        (
            "devpts",
            "/dev/pts",
            "devpts",
            libc::MS_NOSUID | libc::MS_NOEXEC,
        ),
        ("tmpfs", "/run", "tmpfs", libc::MS_NOSUID | libc::MS_NODEV),
    ] {
        if let Err(error) = mount(source, target, fstype, flags) {
            eprintln!("open-init: could not mount {target}: {error}");
        }
    }
}

fn setup_pam_helper() -> io::Result<()> {
    fs::create_dir_all("/run/wrappers/bin")?;
    symlink(PAM_HELPER, PAM_WRAPPER)
}

fn setup_open_runtime_dir() -> io::Result<()> {
    setup_user_dir(OPEN_RUNTIME_DIR, 1001, 1001, 0o700)
}

fn setup_user_dir(path: &str, uid: u32, gid: u32, mode: u32) -> io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))?;

    let path = CString::new(path)?;
    if unsafe { libc::chown(path.as_ptr(), uid, gid) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn reap_children() {
    loop {
        let mut status = 0;
        let result = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
        if result <= 0 {
            break;
        }
        eprintln!("open-init: reaped child {result} with status {status}");
    }
}

fn start_greetd() -> io::Result<Child> {
    eprintln!("open-init: starting greetd");
    Command::new(GROOT).spawn()
}

fn main() -> io::Result<()> {
    if unsafe { libc::getpid() } != 1 {
        eprintln!("open-init: warning: expected to run as PID 1");
    }

    mount_kernel_filesystems();
    if let Err(error) = fs::set_permissions("/dev/ttyS0", fs::Permissions::from_mode(0o666)) {
        eprintln!("open-init: could not configure serial console: {error}");
    }
    if let Err(error) = setup_pam_helper() {
        eprintln!("open-init: could not configure PAM helper: {error}");
    }
    if let Err(error) = setup_open_runtime_dir() {
        eprintln!("open-init: could not configure open runtime directory: {error}");
    }
    for (path, uid, gid) in [("/home/open", 1001, 1001), ("/var/lib/greetd", 1000, 1000)] {
        if let Err(error) = setup_user_dir(path, uid, gid, 0o700) {
            eprintln!("open-init: could not configure {path}: {error}");
        }
    }
    let mut greetd: Option<Child> = None;

    loop {
        reap_children();

        if greetd.as_mut().is_none_or(|child| {
            child
                .try_wait()
                .map(|status| status.is_some())
                .unwrap_or(true)
        }) {
            if !std::path::Path::new(GROOT).exists() {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "greetd is missing; install it in guest-root/usr/bin/greetd",
                ));
            }

            match start_greetd() {
                Ok(child) => greetd = Some(child),
                Err(error) => eprintln!("open-init: failed to start greetd: {error}"),
            }
        }

        thread::sleep(Duration::from_secs(1));
    }
}
