//! Bridges the local clipboard (via `wl-copy`/`wl-paste`) across a
//! byte-stream transport, syncing content in both directions. The guest
//! side opens a virtio-serial device node; the host side connects to the
//! matching QEMU chardev UNIX socket.

use std::{
    env,
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    os::unix::net::UnixStream,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

const MAX_FRAME_BYTES: u32 = 16 * 1024 * 1024;
const RETRY_DELAY: Duration = Duration::from_secs(1);

struct Config {
    transport: TransportKind,
    path: String,
    copy_cmd: Vec<String>,
    paste_cmd: Vec<String>,
    poll_interval: Duration,
}

enum TransportKind {
    Device,
    UnixSocket,
}

enum Channel {
    Device(File),
    Socket(UnixStream),
}

impl Channel {
    fn try_clone(&self) -> io::Result<Channel> {
        match self {
            Channel::Device(file) => Ok(Channel::Device(file.try_clone()?)),
            Channel::Socket(socket) => Ok(Channel::Socket(socket.try_clone()?)),
        }
    }
}

impl Read for Channel {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Channel::Device(file) => file.read(buf),
            Channel::Socket(socket) => socket.read(buf),
        }
    }
}

impl Write for Channel {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Channel::Device(file) => file.write(buf),
            Channel::Socket(socket) => socket.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Channel::Device(file) => file.flush(),
            Channel::Socket(socket) => socket.flush(),
        }
    }
}

fn parse_args() -> Config {
    let mut transport = None;
    let mut path = None;
    let mut copy_cmd = "wl-copy".to_owned();
    let mut paste_cmd = "wl-paste --no-newline".to_owned();
    let mut poll_interval_ms: u64 = 500;

    let mut args = env::args().skip(1);
    while let Some(flag) = args.next() {
        let mut value = || {
            args.next().unwrap_or_else(|| {
                eprintln!("open-clipboard-agent: {flag} requires a value");
                std::process::exit(2);
            })
        };
        match flag.as_str() {
            "--transport" => {
                transport = Some(match value().as_str() {
                    "device" => TransportKind::Device,
                    "unix-socket" => TransportKind::UnixSocket,
                    other => {
                        eprintln!("open-clipboard-agent: unknown transport {other}");
                        std::process::exit(2);
                    }
                })
            }
            "--path" => path = Some(value()),
            "--copy-cmd" => copy_cmd = value(),
            "--paste-cmd" => paste_cmd = value(),
            "--poll-interval-ms" => {
                poll_interval_ms = value().parse().unwrap_or_else(|_| {
                    eprintln!("open-clipboard-agent: --poll-interval-ms needs an integer");
                    std::process::exit(2);
                })
            }
            other => {
                eprintln!("open-clipboard-agent: unknown argument {other}");
                std::process::exit(2);
            }
        }
    }

    let (Some(transport), Some(path)) = (transport, path) else {
        eprintln!(
            "usage: open-clipboard-agent --transport <device|unix-socket> --path <PATH> \
             [--copy-cmd CMD] [--paste-cmd CMD] [--poll-interval-ms N]"
        );
        std::process::exit(2);
    };

    Config {
        transport,
        path,
        copy_cmd: copy_cmd.split_whitespace().map(str::to_owned).collect(),
        paste_cmd: paste_cmd.split_whitespace().map(str::to_owned).collect(),
        poll_interval: Duration::from_millis(poll_interval_ms),
    }
}

fn open_channel(config: &Config) -> io::Result<Channel> {
    match config.transport {
        TransportKind::Device => {
            let mut last_error = None;
            for _ in 0..10 {
                match OpenOptions::new().read(true).write(true).open(&config.path) {
                    Ok(file) => return Ok(Channel::Device(file)),
                    Err(error) => {
                        last_error = Some(error);
                        thread::sleep(Duration::from_millis(300));
                    }
                }
            }
            Err(last_error.unwrap())
        }
        TransportKind::UnixSocket => {
            let mut last_error = None;
            for _ in 0..10 {
                match UnixStream::connect(&config.path) {
                    Ok(socket) => return Ok(Channel::Socket(socket)),
                    Err(error) => {
                        last_error = Some(error);
                        thread::sleep(Duration::from_millis(300));
                    }
                }
            }
            Err(last_error.unwrap())
        }
    }
}

fn read_frame(channel: &mut Channel) -> io::Result<Vec<u8>> {
    let mut length_bytes = [0u8; 4];
    channel.read_exact(&mut length_bytes)?;
    let length = u32::from_be_bytes(length_bytes);
    if length > MAX_FRAME_BYTES {
        return Err(io::Error::other(format!(
            "clipboard frame of {length} bytes exceeds the {MAX_FRAME_BYTES} byte limit"
        )));
    }
    let mut payload = vec![0u8; length as usize];
    channel.read_exact(&mut payload)?;
    Ok(payload)
}

fn write_frame(channel: &mut Channel, payload: &[u8]) -> io::Result<()> {
    let length = u32::try_from(payload.len())
        .map_err(|_| io::Error::other("clipboard content too large to frame"))?;
    channel.write_all(&length.to_be_bytes())?;
    channel.write_all(payload)?;
    channel.flush()
}

fn run_command_with_stdin(command: &[String], input: &[u8]) -> io::Result<()> {
    let mut child = Command::new(&command[0])
        .args(&command[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()?;
    child
        .stdin
        .take()
        .expect("piped stdin")
        .write_all(input)?;
    let status = child.wait()?;
    if !status.success() {
        eprintln!("open-clipboard-agent: {} exited with {status}", command[0]);
    }
    Ok(())
}

fn run_command_capturing_stdout(command: &[String]) -> io::Result<Option<Vec<u8>>> {
    let output = Command::new(&command[0])
        .args(&command[1..])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Ok(None);
    }
    Ok(Some(output.stdout))
}

fn bridge(config: &Config) -> io::Result<()> {
    let channel = open_channel(config)?;
    let last_value: Arc<Mutex<Option<Vec<u8>>>> = Arc::new(Mutex::new(None));

    let mut reader = channel.try_clone()?;
    let mut writer = channel;

    let reader_last_value = Arc::clone(&last_value);
    let copy_cmd = config.copy_cmd.clone();
    let reader_handle = thread::spawn(move || -> io::Result<()> {
        loop {
            let payload = read_frame(&mut reader)?;
            {
                let mut guard = reader_last_value.lock().unwrap();
                if guard.as_deref() == Some(payload.as_slice()) {
                    continue;
                }
                *guard = Some(payload.clone());
            }
            if let Err(error) = run_command_with_stdin(&copy_cmd, &payload) {
                eprintln!("open-clipboard-agent: could not set local clipboard: {error}");
            }
        }
    });

    loop {
        if reader_handle.is_finished() {
            return reader_handle.join().unwrap();
        }

        thread::sleep(config.poll_interval);
        let payload = match run_command_capturing_stdout(&config.paste_cmd) {
            Ok(Some(payload)) if !payload.is_empty() => payload,
            Ok(_) => continue,
            Err(error) => {
                eprintln!("open-clipboard-agent: could not read local clipboard: {error}");
                continue;
            }
        };

        {
            let mut guard = last_value.lock().unwrap();
            if guard.as_deref() == Some(payload.as_slice()) {
                continue;
            }
            *guard = Some(payload.clone());
        }
        write_frame(&mut writer, &payload)?;
    }
}

fn main() {
    let config = parse_args();
    loop {
        if let Err(error) = bridge(&config) {
            eprintln!("open-clipboard-agent: {error}");
        }
        thread::sleep(RETRY_DELAY);
    }
}
