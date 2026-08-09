//! A small supervisor for TOML-defined long-running services.

use serde::Deserialize;
use std::{
    fs, io,
    path::{Path, PathBuf},
    process::{Child, Command},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::Duration,
};

const UNIT_DIRECTORY: &str = "/etc/open-service-manager/services.d";
static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

extern "C" fn request_shutdown(_: libc::c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::Relaxed);
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct UnitFile {
    command: String,
    #[serde(default)]
    args: Vec<String>,
    restart: RestartPolicy,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
enum RestartPolicy {
    Always,
    OnFailure,
    Never,
}

struct Service {
    name: String,
    unit: UnitFile,
    child: Option<Child>,
}

impl Service {
    fn should_restart(&self, status: std::process::ExitStatus) -> bool {
        match self.unit.restart {
            RestartPolicy::Always => true,
            RestartPolicy::OnFailure => !status.success(),
            RestartPolicy::Never => false,
        }
    }

    fn start(&mut self) {
        eprintln!("open-service-manager: starting {}", self.name);
        match Command::new(&self.unit.command)
            .args(&self.unit.args)
            .spawn()
        {
            Ok(child) => self.child = Some(child),
            Err(error) => {
                eprintln!(
                    "open-service-manager: could not start {}: {error}",
                    self.name
                );
            }
        }
    }

    fn poll(&mut self) {
        let Some(child) = self.child.as_mut() else {
            self.start();
            return;
        };

        match child.try_wait() {
            Ok(Some(status)) => {
                eprintln!("open-service-manager: {} exited with {status}", self.name);
                self.child = None;
                if self.should_restart(status) {
                    self.start();
                }
            }
            Ok(None) => {}
            Err(error) => {
                eprintln!(
                    "open-service-manager: could not poll {}: {error}",
                    self.name
                );
                self.child = None;
            }
        }
    }

    fn stop(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };

        eprintln!("open-service-manager: stopping {}", self.name);
        if let Err(error) = child.kill() {
            eprintln!(
                "open-service-manager: could not stop {}: {error}",
                self.name
            );
        }
        if let Err(error) = child.wait() {
            eprintln!(
                "open-service-manager: could not reap {}: {error}",
                self.name
            );
        }
    }
}

fn load_services(directory: &Path) -> io::Result<Vec<Service>> {
    let mut paths: Vec<PathBuf> = fs::read_dir(directory)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<io::Result<_>>()?;
    paths.retain(|path| {
        path.extension()
            .is_some_and(|extension| extension == "toml")
    });
    paths.sort();

    if paths.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("no service units found in {}", directory.display()),
        ));
    }

    paths
        .into_iter()
        .map(|path| {
            let contents = fs::read_to_string(&path)?;
            let unit = toml::from_str(&contents).map_err(|error| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("could not parse {}: {error}", path.display()),
                )
            })?;
            let name = path
                .file_stem()
                .expect("TOML unit paths have a file name")
                .to_string_lossy()
                .into_owned();
            Ok(Service {
                name,
                unit,
                child: None,
            })
        })
        .collect()
}

fn main() -> io::Result<()> {
    unsafe {
        libc::signal(
            libc::SIGTERM,
            request_shutdown as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            request_shutdown as *const () as libc::sighandler_t,
        );
    }

    let mut services = load_services(Path::new(UNIT_DIRECTORY))?;
    eprintln!(
        "open-service-manager: loaded {} service unit(s)",
        services.len()
    );

    while !SHUTDOWN_REQUESTED.load(Ordering::Relaxed) {
        for service in &mut services {
            service.poll();
        }
        thread::sleep(Duration::from_secs(1));
    }

    for service in &mut services {
        service.stop();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{RestartPolicy, UnitFile};

    #[test]
    fn parses_a_service_unit() {
        let unit: UnitFile = toml::from_str(
            r#"
                command = "/usr/bin/example"
                args = ["--foreground"]
                restart = "on-failure"
            "#,
        )
        .unwrap();

        assert_eq!(unit.command, "/usr/bin/example");
        assert_eq!(unit.args, ["--foreground"]);
        assert_eq!(unit.restart, RestartPolicy::OnFailure);
    }

    #[test]
    fn rejects_an_unknown_restart_policy() {
        let result = toml::from_str::<UnitFile>(
            r#"
                command = "/usr/bin/example"
                restart = "sometimes"
            "#,
        );

        assert!(result.is_err());
    }
}
