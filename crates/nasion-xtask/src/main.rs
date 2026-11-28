//! The cross targets come only from rust-toolchain.toml, and the host target
//! only from `scripts/checks.sh` through `NASION_HOST_TARGET` (D59). The
//! `toolchain` module reads them, and `nasion-xtask toolchain-targets` prints
//! the cross targets for the shell, one per line.
//!
//! Exit codes, read by `scripts/checks.sh`: 0 printed, 2 failed.
mod toolchain;

use std::ffi::OsString;
use std::io::{self, Write};
use std::path::Path;
use std::process::ExitCode;

const CANNOT_RUN: u8 = 2;

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let outcome = match args.as_slice() {
        [command] if command == "toolchain-targets" => print_targets(),
        _ => Err(format!(
            "nasion-xtask takes toolchain-targets alone, and got {args:?}."
        )),
    };
    let Err(message) = outcome else {
        return ExitCode::SUCCESS;
    };
    match writeln!(io::stdout().lock(), "{message}") {
        Ok(()) | Err(_) => ExitCode::from(CANNOT_RUN),
    }
}

/// Prints the cross targets from rust-toolchain.toml in the current
/// directory, the workspace root where `scripts/checks.sh` runs, one per line
/// (D59).
fn print_targets() -> Result<(), String> {
    let host = toolchain::host_target(std::env::var(toolchain::HOST_VAR).ok())?;
    let targets = toolchain::cross_targets(Path::new(""), &host)?;
    let mut out = io::stdout().lock();
    for target in targets {
        writeln!(out, "{target}")
            .map_err(|e| format!("writing the targets to stdout failed: {e}"))?;
    }
    Ok(())
}
