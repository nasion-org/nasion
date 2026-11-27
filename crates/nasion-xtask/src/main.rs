//! Checks the crate-level unsafe_code attributes of every target root in the
//! workspace. The file is parsed with syn, so attribute text inside a comment
//! or a string literal never counts.
//!
//! - Build scripts and proc macros run on the build machine, so a Linux build
//!   never compiles their `cfg(windows)` code. Their roots need
//!   `#![forbid(unsafe_code)]`, which no `allow` further down can lift.
//! - Every other target root needs `#![deny(unsafe_code)]` or the stricter
//!   `#![forbid(unsafe_code)]` (D29).
//! - Every file rustc reads for a library target, on the host and on each
//!   cross target, is a `.rs` file that check scans (D50). The `dep_info`
//!   module holds that check.
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
//! The target kind comes from cargo metadata, never from the file name.
//!
//! Exit codes, read by `scripts/checks.sh`: 0 clean, 1 a check found a
//! problem, 2 the check could not run.
#![deny(unsafe_code)]

mod cargo_cmd;
mod cargo_sources;
mod dep_info;
mod proc_macros;
mod toolchain;

use std::ffi::OsString;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

const CLEAN: u8 = 0;
const VIOLATION: u8 = 1;
const CANNOT_RUN: u8 = 2;

/// Target kinds that run on the build machine during the build.
const BUILD_MACHINE_KINDS: [&str; 2] = ["custom-build", "proc-macro"];
/// Library target kinds.
const LIBRARY_KINDS: [&str; 6] = ["lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"];

#[derive(Clone, Copy, PartialEq, PartialOrd)]
enum Level {
    Deny,
    Forbid,
}

struct Target {
    package: String,
    manifest: PathBuf,
    kinds: Vec<String>,
    src_path: PathBuf,
}

impl Target {
    fn has_kind(&self, kinds: &[&str]) -> bool {
        self.kinds.iter().any(|kind| kinds.contains(&kind.as_str()))
    }
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
    for target in &targets {
        missing.extend(check_target(target)?);
    }
    let mut library_packages: Vec<&str> = targets
        .iter()
        .filter(|target| target.has_kind(&LIBRARY_KINDS))
        .map(|target| target.package.as_str())
        .collect();
    library_packages.sort_unstable();
    library_packages.dedup();
    let host = toolchain::host_target(std::env::var(toolchain::HOST_VAR).ok())?;
    let cross = toolchain::cross_targets(&root, &host)?;
    let (dep_info_count, problems) =
        dep_info::check(&cargo, &root, &library_packages, &host, &cross, &mut log)?;
    missing.extend(problems);
    let (proc_macro_count, problems) = proc_macros::check(&cargo, &root, &mut log)?;
    missing.extend(problems);

    if missing.is_empty() {
        writeln!(
            io::stdout().lock(),
            "note: {} targets, {dep_info_count} dep-info files, {proc_macro_count} proc macros",
            targets.len()
        )
        .map_err(|e| format!("writing the counts to stdout failed: {e}"))?;
    }
    Ok(missing)
}

fn check_target(target: &Target) -> Result<Vec<String>, String> {
    let path = &target.src_path;
    let file = parse_root(path)?;
    let parse_error = |e: syn::Error| format!("{} does not parse: {e}", path.display());
    let described = format!(
        "{} ({} target of {})",
        path.display(),
        target.kinds.join(", "),
        target.package
    );
    let mut missing = Vec::new();
    let level = unsafe_code_level(&file).map_err(parse_error)?;
    if target.has_kind(&BUILD_MACHINE_KINDS) {
        if level != Some(Level::Forbid) {
            missing.push(format!(
                "{described} lacks a crate-level #![forbid(unsafe_code)], required because it runs on the build machine"
            ));
        }
    } else if level.is_none() {
        missing.push(format!(
            "{described} lacks a crate-level #![deny(unsafe_code)]"
        ));
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
        for target in package_targets {
            let src_path = target["src_path"]
                .as_str()
                .ok_or_else(|| format!("a target of {name} in cargo metadata has no src_path"))?;
            let kinds = target["kind"]
                .as_array()
                .filter(|kinds| !kinds.is_empty())
                .and_then(|kinds| {
                    kinds
                        .iter()
                        .map(|kind| kind.as_str().map(str::to_owned))
                        .collect::<Option<Vec<_>>>()
                })
                .ok_or_else(|| {
                    format!(
                        "target {src_path} of {name} in cargo metadata has no list of kind names"
                    )
                })?;
            targets.push(Target {
                package: name.to_owned(),
                manifest: manifest.clone(),
                kinds,
                src_path: PathBuf::from(src_path),
            });
        }
    }
    Ok((root, targets))
}

fn parse_root(path: &Path) -> Result<syn::File, String> {
    let source =
        fs::read_to_string(path).map_err(|e| format!("{} cannot be read: {e}", path.display()))?;
    syn::parse_file(&source).map_err(|e| format!("{} does not parse: {e}", path.display()))
}

/// The strongest crate-level `deny(unsafe_code)` or `forbid(unsafe_code)`,
/// alone or with other lints. An attribute inside `cfg_attr`, on an item or on
/// a module does not count, because it does not cover the whole crate in every
/// build.
fn unsafe_code_level(file: &syn::File) -> syn::Result<Option<Level>> {
    let mut strongest = None;
    for attr in &file.attrs {
        let level = if attr.path().is_ident("forbid") {
            Level::Forbid
        } else if attr.path().is_ident("deny") {
            Level::Deny
        } else {
            continue;
        };
        let mut found = false;
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("unsafe_code") {
                found = true;
            } else if meta.path.is_ident("reason") {
                meta.value()?.parse::<syn::LitStr>()?;
            }
            Ok(())
        })?;
        if found && strongest < Some(level) {
            strongest = Some(level);
        }
    }
    Ok(strongest)
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

    use super::{Level, unsafe_code_level};

    fn level(source: &str) -> Option<Level> {
        unsafe_code_level(&syn::parse_file(source).unwrap()).unwrap()
    }

    #[test]
    fn plain_deny_is_deny() {
        assert!(level("#![deny(unsafe_code)]\nfn main() {}") == Some(Level::Deny));
    }

    #[test]
    fn combined_lint_list_with_reason_counts() {
        let source = "#![deny(dead_code, unsafe_code, reason = \"spec\")]";
        assert!(level(source) == Some(Level::Deny));
    }

    #[test]
    fn forbid_is_forbid_whatever_the_order() {
        assert!(level("#![forbid(unsafe_code)]") == Some(Level::Forbid));
        assert!(level("#![forbid(unsafe_code)]\n#![deny(unsafe_code)]") == Some(Level::Forbid));
        assert!(level("#![deny(unsafe_code)]\n#![forbid(unsafe_code)]") == Some(Level::Forbid));
    }

    #[test]
    fn text_in_comments_and_strings_does_not_count() {
        for source in [
            "/* #![forbid(unsafe_code)] */",
            "// #![deny(unsafe_code)]",
            "pub const MARK: &str = \"#![forbid(unsafe_code)]\";",
        ] {
            assert!(level(source).is_none(), "{source}");
        }
    }

    #[test]
    fn non_crate_level_or_conditional_does_not_count() {
        for source in [
            "mod inner {\n    #![deny(unsafe_code)]\n}",
            "#[forbid(unsafe_code)]\nfn f() {}",
            "#![cfg_attr(not(test), forbid(unsafe_code))]",
            "#![warn(unsafe_code)]",
            "#![deny(unsafe_op_in_unsafe_fn)]",
        ] {
            assert!(level(source).is_none(), "{source}");
        }
    }
}
