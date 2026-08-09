//! `open-init` is a deliberately small Linux PID 1.
//!
//! It mounts the kernel filesystems, brings up networking, starts
//! `open-service-manager`, and reaps orphaned children. The manager supervises
//! greetd, which owns login and launches `niri-session` for the configured user.

use std::{
    ffi::CString,
    fs, io,
    os::unix::fs::{PermissionsExt, symlink},
    process::{Child, Command},
    sync::atomic::{AtomicU8, Ordering},
    thread,
    time::Duration,
};

const PAM_HELPER: &str = "/usr/lib/open-init/unix_chkpwd";
const PAM_WRAPPER: &str = "/run/wrappers/bin/unix_chkpwd";
const OPEN_RUNTIME_DIR: &str = "/run/user/1001";
const UDEVADM: &str = "/usr/bin/udevadm";
const UDEVD: &str = "/usr/bin/udevd";
const OPENGL_DRIVER: &str = "/usr/lib/open-init/opengl-driver";
const SERVICE_MANAGER: &str = "/usr/bin/open-service-manager";
const IP: &str = "/usr/bin/ip";
const GUEST_ADDRESS: &str = "10.0.2.15/24";
const GUEST_GATEWAY: &str = "10.0.2.2";
const SHUTDOWN_NONE: u8 = 0;
const SHUTDOWN_POWEROFF: u8 = 1;
const SHUTDOWN_REBOOT: u8 = 2;
static SHUTDOWN_REQUEST: AtomicU8 = AtomicU8::new(SHUTDOWN_NONE);

extern "C" fn request_shutdown(signal: libc::c_int) {
    let action = if signal == libc::SIGUSR1 {
        SHUTDOWN_REBOOT
    } else {
        SHUTDOWN_POWEROFF
    };
    SHUTDOWN_REQUEST.store(action, Ordering::Relaxed);
}

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

fn start_udev() -> io::Result<()> {
    Command::new(UDEVD).arg("--daemon").status()?;

    for args in [
        &["trigger", "--action=add", "--type=subsystems"][..],
        &["trigger", "--action=add", "--type=devices"][..],
        &["settle", "--timeout=5"][..],
    ] {
        let status = Command::new(UDEVADM).args(args).status()?;
        if !status.success() {
            return Err(io::Error::other(format!(
                "udevadm {} exited with {status}",
                args[0]
            )));
        }
    }

    Ok(())
}

fn find_ethernet_interface() -> io::Result<String> {
    for entry in fs::read_dir("/sys/class/net")? {
        let name = entry?.file_name().to_string_lossy().into_owned();
        if name != "lo" {
            return Ok(name);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "no ethernet interface found under /sys/class/net",
    ))
}

fn configure_network() -> io::Result<()> {
    let interface = find_ethernet_interface()?;

    for args in [
        &["link", "set", "lo", "up"][..],
        &["addr", "add", GUEST_ADDRESS, "dev", &interface][..],
        &["link", "set", &interface, "up"][..],
        &[
            "route",
            "add",
            "default",
            "via",
            GUEST_GATEWAY,
            "dev",
            &interface,
        ][..],
    ] {
        let status = Command::new(IP).args(args).status()?;
        if !status.success() {
            return Err(io::Error::other(format!(
                "ip {args:?} exited with {status}"
            )));
        }
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

fn start_service_manager() -> io::Result<Child> {
    eprintln!("open-init: starting service manager");
    Command::new(SERVICE_MANAGER).spawn()
}

fn shutdown(service_manager: Option<&mut Child>, action: u8) -> io::Result<()> {
    let description = if action == SHUTDOWN_REBOOT {
        "reboot"
    } else {
        "power off"
    };
    eprintln!("open-init: preparing to {description}");

    if let Some(service_manager) = service_manager {
        if unsafe { libc::kill(service_manager.id() as libc::pid_t, libc::SIGTERM) } == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                eprintln!("open-init: could not stop service manager: {error}");
            }
        }
        if let Err(error) = service_manager.wait() {
            eprintln!("open-init: could not reap service manager: {error}");
        }
    }

    unsafe {
        libc::sync();
    }
    let command = if action == SHUTDOWN_REBOOT {
        libc::RB_AUTOBOOT
    } else {
        libc::RB_POWER_OFF
    };
    if unsafe { libc::reboot(command) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Err(io::Error::other(
        "kernel reboot request unexpectedly returned",
    ))
}

fn main() -> io::Result<()> {
    if unsafe { libc::getpid() } != 1 {
        eprintln!("open-init: warning: expected to run as PID 1");
    }
    unsafe {
        libc::signal(
            libc::SIGTERM,
            request_shutdown as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            request_shutdown as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGUSR1,
            request_shutdown as *const () as libc::sighandler_t,
        );
    }

    mount_kernel_filesystems();
    if let Err(error) = fs::set_permissions("/dev/ttyS0", fs::Permissions::from_mode(0o666)) {
        eprintln!("open-init: could not configure serial console: {error}");
    }
    if let Err(error) = setup_pam_helper() {
        eprintln!("open-init: could not configure PAM helper: {error}");
    }
    if let Err(error) = symlink(OPENGL_DRIVER, "/run/opengl-driver") {
        eprintln!("open-init: could not configure Mesa driver path: {error}");
    }
    if let Err(error) = setup_open_runtime_dir() {
        eprintln!("open-init: could not configure open runtime directory: {error}");
    }
    for (path, uid, gid) in [("/home/open", 1001, 1001), ("/var/lib/greetd", 1000, 1000)] {
        if let Err(error) = setup_user_dir(path, uid, gid, 0o700) {
            eprintln!("open-init: could not configure {path}: {error}");
        }
    }
    if let Err(error) = start_udev() {
        eprintln!("open-init: could not start or initialize udev: {error}");
    }
    if let Err(error) = configure_network() {
        eprintln!("open-init: could not configure network: {error}");
    }
    let mut service_manager: Option<Child> = None;

    loop {
        let shutdown_request = SHUTDOWN_REQUEST.swap(SHUTDOWN_NONE, Ordering::Relaxed);
        if shutdown_request != SHUTDOWN_NONE {
            return shutdown(service_manager.as_mut(), shutdown_request);
        }
        reap_children();

        if service_manager.as_mut().is_none_or(|child| {
            child
                .try_wait()
                .map(|status| status.is_some())
                .unwrap_or(true)
        }) {
            if !std::path::Path::new(SERVICE_MANAGER).exists() {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "open-service-manager is missing; install it in guest-root/usr/bin",
                ));
            }

            match start_service_manager() {
                Ok(child) => service_manager = Some(child),
                Err(error) => eprintln!("open-init: failed to start service manager: {error}"),
            }
        }

        thread::sleep(Duration::from_secs(1));
    }
}
