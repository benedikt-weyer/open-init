//! `open-init` is a deliberately small Linux PID 1.
//!
//! It mounts the kernel filesystems, supervises greetd, and reaps orphaned
//! children. greetd owns login and launches `niri-session` for the configured
//! user, rather than PID 1 starting a compositor itself.

use std::{
    ffi::CString,
    fs, io,
    process::{Child, Command},
    thread,
    time::Duration,
};

const GROOT: &str = "/usr/bin/greetd";

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
