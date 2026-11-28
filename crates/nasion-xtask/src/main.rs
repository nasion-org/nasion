//! Checks the workspace for the gate.
//!
//! - No workspace member has a proc-macro target (D52), and every crate that
//!   runs inside a proc macro is pinned by name, version, source and checksum
//!   (D53). The `proc_macros` module holds that check.
//! - No workspace manifest has a `[patch]` or `[replace]` table, and no cargo
//!   config or environment variable can swap where package code comes from
//!   (D53). The `cargo_sources` module holds that check.
//! - The cross targets come only from rust-toolchain.toml, and the host target
//!   only from `scripts/checks.sh` through `NASION_HOST_TARGET` (D59). The
//!   `toolchain` module reads them, and `nasion-xtask toolchain-targets` prints
//!   the cross targets for the shell, one per line.
//!
//! Exit codes, read by `scripts/checks.sh`: 0 clean, 1 a check found a
//! problem, 2 the check could not run.
mod cargo_cmd;
mod cargo_sources;
mod proc_macros;
mod toolchain;

use std::ffi::OsString;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::{Command, ExitCode};

const CLEAN: u8 = 0;
const VIOLATION: u8 = 1;
const CANNOT_RUN: u8 = 2;

struct Target {
    manifest: PathBuf,
}

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let outcome = match args.as_slice() {
        [] => check_workspace(),
        [command] if command == "toolchain-targets" => print_targets().map(|()| Vec::new()),
        _ => Err(format!(
            "nasion-xtask takes no arguments, or toolchain-targets alone, and got {args:?}."
        )),
    };
    let (code, message) = match outcome {
        Ok(missing) if missing.is_empty() => (CLEAN, None),
        Ok(missing) => (VIOLATION, Some(missing.join("\n"))),
        Err(message) => (CANNOT_RUN, Some(message)),
    };
    let Some(message) = message else {
        return ExitCode::from(code);
    };
    match writeln!(io::stdout().lock(), "{message}") {
        Ok(()) => ExitCode::from(code),
        Err(_) => ExitCode::from(CANNOT_RUN),
    }
}

/// Prints the cross targets from rust-toolchain.toml, one per line, for
/// `scripts/checks.sh` (D59).
fn print_targets() -> Result<(), String> {
    let (root, _) = workspace_targets(&cargo(), &mut io::stderr())?;
    let host = toolchain::host_target(std::env::var(toolchain::HOST_VAR).ok())?;
    let targets = toolchain::cross_targets(&root, &host)?;
    let mut out = io::stdout().lock();
    for target in targets {
        writeln!(out, "{target}")
            .map_err(|e| format!("writing the targets to stdout failed: {e}"))?;
    }
    Ok(())
}

fn cargo() -> OsString {
    std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into())
}

/// Returns one line per problem found.
fn check_workspace() -> Result<Vec<String>, String> {
    let cargo = cargo();
    let mut log = io::stderr();
    let (root, targets) = workspace_targets(&cargo, &mut log)?;
    if targets.is_empty() {
        return Err(
            "cargo metadata listed no targets. Check the workspace members in Cargo.toml.".into(),
        );
    }
    let mut manifests = vec![root.join("Cargo.toml")];
    manifests.extend(targets.iter().map(|target| target.manifest.clone()));
    manifests.sort();
    manifests.dedup();
    let sources = cargo_sources::check(&root, &manifests)?;
    if !sources.configs.is_empty() {
        return Ok(sources
            .manifests
            .into_iter()
            .chain(sources.configs)
            .collect());
    }
    let mut missing = sources.manifests;
    let (proc_macro_count, problems) = proc_macros::check(&cargo, &root, &mut log)?;
    missing.extend(problems);

    if missing.is_empty() {
        writeln!(
            io::stdout().lock(),
            "note: {} targets, {proc_macro_count} proc macros",
            targets.len()
        )
        .map_err(|e| format!("writing the counts to stdout failed: {e}"))?;
    }
    Ok(missing)
}

/// Returns the workspace root and every target of every workspace member. Uses
/// the cargo that ran this tool when there is one, so the pinned toolchain
/// answers.
fn workspace_targets(
    cargo: &OsString,
    log: &mut dyn Write,
) -> Result<(PathBuf, Vec<Target>), String> {
    let output = cargo_cmd::run(
        Command::new(cargo).args(["metadata", "--no-deps", "--format-version", "1"]),
        "cargo metadata --no-deps --format-version 1",
        log,
    )?;
    if !output.status.success() {
        return Err(format!(
            "cargo metadata failed ({}). Check that every Cargo.toml in the workspace parses. Its stderr is above.",
            output.status
        ));
    }
    let metadata: serde_json::Value = serde_json::from_slice(&output.stdout)
        .map_err(|e| format!("cargo metadata output is not JSON: {e}"))?;
    let root = metadata["workspace_root"]
        .as_str()
        .map(PathBuf::from)
        .ok_or("cargo metadata output has no workspace_root")?;
    let packages = metadata["packages"]
        .as_array()
        .ok_or("cargo metadata output has no packages list")?;
    let mut targets = Vec::new();
    for package in packages {
        let name = package["name"]
            .as_str()
            .ok_or("a package in cargo metadata has no name")?;
        let manifest = package["manifest_path"]
            .as_str()
            .map(PathBuf::from)
            .ok_or_else(|| format!("package {name} in cargo metadata has no manifest_path"))?;
        let package_targets = package["targets"]
            .as_array()
            .ok_or_else(|| format!("package {name} in cargo metadata has no targets list"))?;
        for _ in package_targets {
            targets.push(Target {
                manifest: manifest.clone(),
            });
        }
    }
    Ok((root, targets))
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    #[test]
    fn the_workspace_metadata_run_forwards_cargo_stderr() {
        use crate::cargo_cmd::tests::fake::{FakeCargo, assert_forwarded};
        let fake = FakeCargo::new("metadata-no-deps");
        for warn in [true, false] {
            let cargo = fake.script(
                if warn { "warn" } else { "clean" },
                r#"printf '{"workspace_root":"/ws","packages":[]}'"#,
                warn,
            );
            let mut log = Vec::new();
            let (root, targets) = super::workspace_targets(&cargo, &mut log).unwrap();
            assert_eq!(root, std::path::PathBuf::from("/ws"));
            assert!(targets.is_empty());
            assert_forwarded(&log, "metadata --no-deps --format-version 1", warn);
        }
    }
}
