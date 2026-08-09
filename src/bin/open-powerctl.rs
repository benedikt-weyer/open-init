use std::{env, io, path::Path, process};

fn main() -> io::Result<()> {
    let invocation = env::args_os()
        .next()
        .and_then(|path| Path::new(&path).file_name().map(|name| name.to_owned()))
        .and_then(|name| name.into_string().ok())
        .unwrap_or_else(|| "shutdown".to_owned());
    let signal = match invocation.as_str() {
        "shutdown" => libc::SIGTERM,
        "reboot" => libc::SIGUSR1,
        _ => {
            eprintln!("open-powerctl must be invoked as shutdown or reboot");
            process::exit(2);
        }
    };

    if env::args_os().nth(1).is_some() {
        eprintln!("usage: {invocation}");
        process::exit(2);
    }
    if unsafe { libc::geteuid() } != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{invocation} must be run as root"),
        ));
    }
    if unsafe { libc::kill(1, signal) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
