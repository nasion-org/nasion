//! Cross-checks the D48 scan against the files rustc reads (D50). For every
//! library package and for the host and each cross target, rustc writes a
//! dep-info file listing every file the crate's compilation read, whatever
//! macro led there. Every listed file must be a `.rs` file the D48 walk scans:
//! inside the workspace root and outside its `target`, `.venv` and `.git`.
//!
//! cargo runs with `--profile check`, so rustc emits dep-info and metadata
//! only. The default profile also links, and a cdylib cannot link for the
//! Windows target without the MSVC linker.

use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

/// Directories under the workspace root that hold no workspace source.
pub const SKIPPED_DIRS: [&str; 3] = ["target", ".venv", ".git"];

/// Set by `scripts/checks.sh` from requires-python in pyproject.toml, and
/// passed to PyO3 as `PYO3_CROSS_PYTHON_VERSION` for the cross runs.
const PYTHON_VERSION_VAR: &str = "NASION_PYO3_CROSS_PYTHON_VERSION";

/// Runs the dep-info builds on `host`, with no `--target`, and for each of
/// `cross`, and returns how many dep-info files were read and one line per
/// listed file the D48 walk does not scan. Both lists come from the gate:
/// the host from `scripts/checks.sh`, the cross targets from
/// rust-toolchain.toml (D59).
pub fn check(
    cargo: &OsString,
    root: &Path,
    packages: &[&str],
    host: &str,
    cross: &[String],
    log: &mut dyn std::io::Write,
) -> Result<(usize, Vec<String>), String> {
    let python = std::env::var(PYTHON_VERSION_VAR).map_err(|e| {
        format!(
            "{PYTHON_VERSION_VAR} is not usable ({e}). scripts/checks.sh sets it from requires-python in pyproject.toml, so run this check through gate.sh."
        )
    })?;
    let target_dir = dep_info_target_dir(root, std::env::var_os("CARGO_TARGET_DIR"));
    let files_dir = target_dir.join("files");
    fs::create_dir_all(&files_dir)
        .map_err(|e| format!("{} cannot be created: {e}", files_dir.display()))?;
    let triples: Vec<Option<&str>> = [None]
        .into_iter()
        .chain(cross.iter().map(|target| Some(target.as_str())))
        .collect();
    let runs = Runs {
        cargo,
        root,
        target_dir: &target_dir,
        python: &python,
    };
    let mut count = 0;
    let mut problems = Vec::new();
    for package in packages {
        for triple in &triples {
            let label = triple.unwrap_or(host);
            let file = files_dir.join(format!("{package}-{label}.d"));
            let deps = run(&runs, package, *triple, &file, log)?;
            count += 1;
            for dep in deps {
                if let Some(reason) = unscanned(root, &dep) {
                    problems.push(format!(
                        "the {package} library target for {label} reads {dep}, {reason} (D50)."
                    ));
                }
            }
        }
    }
    Ok((count, problems))
}

/// The build directory for the dep-info runs: `dep-info` under the target
/// directory the gate set in `CARGO_TARGET_DIR`, else under `target/`. A
/// relative target directory resolves against the workspace root, as cargo
/// resolves it.
fn dep_info_target_dir(root: &Path, target: Option<OsString>) -> PathBuf {
    match target.filter(|target| !target.is_empty()) {
        Some(target) => root.join(target).join("dep-info"),
        None => root.join("target").join("dep-info"),
    }
}

/// What every dep-info run of one check shares.
struct Runs<'a> {
    cargo: &'a OsString,
    root: &'a Path,
    target_dir: &'a Path,
    python: &'a str,
}

/// Builds one package for one target and returns the files its dep-info lists.
fn run(
    runs: &Runs<'_>,
    package: &str,
    triple: Option<&str>,
    file: &Path,
    log: &mut dyn std::io::Write,
) -> Result<Vec<String>, String> {
    let file_text = file
        .to_str()
        .filter(|text| !text.contains(','))
        .ok_or_else(|| {
            format!(
                "{} is not UTF-8 or holds a comma, so it cannot be passed to --emit",
                file.display()
            )
        })?;
    match fs::remove_file(file) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => {
            return Err(format!("{} cannot be removed: {e}", file.display()));
        }
        _ => {}
    }
    let emit = format!("--emit=dep-info={file_text},metadata");
    let mut args = vec![
        "rustc",
        "--locked",
        "-p",
        package,
        "--lib",
        "--all-features",
        "--profile",
        "check",
    ];
    let mut command = Command::new(runs.cargo);
    command
        .current_dir(runs.root)
        .env("CARGO_TARGET_DIR", runs.target_dir);
    if let Some(triple) = triple {
        args.extend(["--target", triple]);
        command.env("PYO3_CROSS_PYTHON_VERSION", runs.python);
    }
    args.extend(["--", &emit]);
    let shown = format!("cargo {}", args.join(" "));
    let output = crate::cargo_cmd::run(command.args(&args), &shown, log)?;
    if !output.status.success() {
        return Err(format!(
            "{shown} failed ({}). Its stderr is above.",
            output.status
        ));
    }
    let text = fs::read_to_string(file).map_err(|e| {
        format!(
            "{shown} succeeded but {} cannot be read: {e}. Its stderr is above.",
            file.display()
        )
    })?;
    let deps = parse(&text).map_err(|e| format!("{} {e}", file.display()))?;
    if deps.is_empty() {
        return Err(format!(
            "{shown} wrote {} with no dependencies. Its stderr is above.",
            file.display()
        ));
    }
    Ok(deps)
}

/// The files a dep-info file lists, from its rules and its phony `path:` lines,
/// unescaped, each once in the order first seen. rustc writes it in `write_out_deps` and escapes each file name in
/// `escape_dep_filename`, both in compiler/rustc_interface/src/passes.rs of
/// rust-lang/rust at commit 0ef1bc386059596dada8fb65b50425aab2ea637a (tag
/// 1.100.0). Only a space is escaped, as `\ `, so a `#` or a backslash in a
/// name is written as is. A rule is `output: file file ...`, a phony line is
/// `file:`, and lines starting with `#` are comments such as `# env-dep:`.
fn parse(text: &str) -> Result<Vec<String>, String> {
    let mut deps = Vec::new();
    for (number, line) in text.lines().enumerate() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(phony) = line.strip_suffix(':')
            && !phony.contains(": ")
        {
            add_unique(&mut deps, split_unescaped(phony));
            continue;
        }
        let Some(at) = line.find(": ") else {
            return Err(format!(
                "line {} is not a rule, a phony target or a comment: {line:?}",
                number + 1
            ));
        };
        add_unique(&mut deps, split_unescaped(&line[at + 2..]));
    }
    Ok(deps)
}

fn add_unique(deps: &mut Vec<String>, names: Vec<String>) {
    for name in names {
        if !deps.contains(&name) {
            deps.push(name);
        }
    }
}

/// Splits on spaces that are not escaped and turns `\ ` back into a space.
fn split_unescaped(text: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut name = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\\' if chars.peek() == Some(&' ') => {
                name.push(' ');
                chars.next();
            }
            ' ' => {
                if !name.is_empty() {
                    names.push(std::mem::take(&mut name));
                }
            }
            _ => name.push(ch),
        }
    }
    if !name.is_empty() {
        names.push(name);
    }
    names
}

/// Why the D48 walk would not scan a listed file, or None when it would.
/// Relative names resolve against the workspace root, where cargo runs rustc.
fn unscanned(root: &Path, dep: &str) -> Option<&'static str> {
    let path: PathBuf = root.join(dep);
    let Ok(relative) = path.strip_prefix(root) else {
        return Some("which is outside the workspace root");
    };
    if !relative
        .components()
        .all(|component| matches!(component, Component::Normal(_)))
    {
        return Some("which is not a plain path below the workspace root");
    }
    if relative
        .components()
        .next()
        .is_some_and(|first| SKIPPED_DIRS.iter().any(|dir| first.as_os_str() == *dir))
    {
        return Some("which is under a directory the D48 scan skips");
    }
    if path.extension().is_none_or(|ext| ext != "rs") {
        return Some("which is not a .rs file");
    }
    if !path.is_file() {
        return Some("which is not a file on disk");
    }
    None
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    #[test]
    fn the_dep_info_run_forwards_cargo_stderr() {
        use crate::cargo_cmd::tests::fake::{FakeCargo, assert_forwarded};
        let fake = FakeCargo::new("rustc-dep-info");
        let body = r#"for a in "$@"; do case $a in --emit=dep-info=*) f=${a#--emit=dep-info=}; f=${f%,metadata}; printf 'out.rmeta: src/lib.rs\n' >"$f";; esac; done"#;
        for warn in [true, false] {
            let cargo = fake.script(if warn { "warn" } else { "clean" }, body, warn);
            let mut log = Vec::new();
            let file = fake.0.join("out.d");
            let target = fake.0.join("target");
            let runs = super::Runs {
                cargo: &cargo,
                root: &fake.0,
                target_dir: &target,
                python: "3.11",
            };
            let deps = super::run(
                &runs,
                "core",
                Some("x86_64-pc-windows-msvc"),
                &file,
                &mut log,
            )
            .unwrap();
            assert_eq!(deps, ["src/lib.rs"]);
            assert_forwarded(&log, "rustc --locked -p core --lib", warn);
        }
    }

    use std::fs;
    use std::path::PathBuf;

    use std::ffi::OsString;
    use std::path::Path;

    use super::{dep_info_target_dir, parse, unscanned};

    #[test]
    fn the_dep_info_build_follows_the_target_directory() {
        let root = Path::new("/ws");
        assert_eq!(
            dep_info_target_dir(root, None),
            Path::new("/ws/target/dep-info")
        );
        assert_eq!(
            dep_info_target_dir(root, Some(OsString::new())),
            Path::new("/ws/target/dep-info")
        );
        assert_eq!(
            dep_info_target_dir(root, Some(OsString::from("/tmp/run/target"))),
            Path::new("/tmp/run/target/dep-info")
        );
        assert_eq!(
            dep_info_target_dir(root, Some(OsString::from("out"))),
            Path::new("/ws/out/dep-info")
        );
    }

    #[test]
    fn rules_and_phony_lines_give_every_listed_file() {
        let text = "/abs/target/out.rmeta: crates/a/src/lib.rs /abs/other/x.rs\n\n/abs/target/out.d: crates/a/src/lib.rs\n\ncrates/a/src/lib.rs:\n/abs/other/x.rs:\n\n# env-dep:CARGO_PKG_VERSION=0.1.0\n# env-dep:NO_VALUE\n";
        assert_eq!(
            parse(text).unwrap(),
            ["crates/a/src/lib.rs", "/abs/other/x.rs"]
        );
    }

    #[test]
    fn escaped_spaces_and_raw_hashes_are_read_as_rustc_writes_them() {
        assert_eq!(
            parse("out.rmeta: a/my\\ file.rs b/#x.rs c\\d.rs\n").unwrap(),
            ["a/my file.rs", "b/#x.rs", "c\\d.rs"]
        );
        assert_eq!(parse("a/my\\ file.rs:\n").unwrap(), ["a/my file.rs"]);
        assert_eq!(parse("a/x:y.rs:\n").unwrap(), ["a/x:y.rs"]);
        assert_eq!(
            parse("b.rs:\nout.rmeta: a.rs b.rs\n").unwrap(),
            ["b.rs", "a.rs"]
        );
        assert_eq!(parse("out.rmeta: a.rs  b.rs \n").unwrap(), ["a.rs", "b.rs"]);
    }

    #[test]
    fn blank_lines_comments_and_empty_rules_list_nothing() {
        assert!(parse("").unwrap().is_empty());
        assert!(parse("\n\n# env-dep:X=1\n#x.rs:\n").unwrap().is_empty());
        assert!(parse("out.rmeta: \n").unwrap().is_empty());
    }

    #[test]
    fn unknown_lines_are_errors() {
        for text in [
            "garbage\n",
            "out.rmeta:a.rs\n",
            " leading space\n",
            "out.rmeta: a.rs\nnot a rule\n",
        ] {
            let error = parse(text).unwrap_err();
            assert!(
                error.contains("is not a rule, a phony target or a comment"),
                "{text:?}: {error}"
            );
        }
        assert!(parse("ok.rs:\nbad\n").unwrap_err().starts_with("line 2 "));
    }

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let dir =
                std::env::temp_dir().join(format!("nasion-d50-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn write(&self, path: &str) {
            let path = self.0.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, "").unwrap();
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn only_rs_files_the_walk_scans_are_accepted() {
        let scratch = Scratch::new("checker");
        let root = scratch.0.join("ws");
        for file in [
            "ws/crates/a/src/lib.rs",
            "ws/crates/a/src/inc.in",
            "ws/crates/a/target/nested.rs",
            "ws/target/debug/out.rs",
            "ws/.venv/lib/x.rs",
            "ws/.git/x.rs",
            "outside.rs",
        ] {
            scratch.write(file);
        }
        let absolute = root.join("crates/a/src/lib.rs");
        let outside = scratch.0.join("outside.rs");
        let climbing = root.join("crates/../../outside.rs");
        assert_eq!(unscanned(&root, "crates/a/src/lib.rs"), None);
        assert_eq!(unscanned(&root, absolute.to_str().unwrap()), None);
        assert_eq!(unscanned(&root, "crates/a/target/nested.rs"), None);
        assert_eq!(unscanned(&root, "crates/./a/src/lib.rs"), None);
        assert_eq!(
            unscanned(&root, climbing.to_str().unwrap()),
            Some("which is not a plain path below the workspace root")
        );
        for (dep, reason) in [
            ("crates/a/src/inc.in", "which is not a .rs file"),
            (
                outside.to_str().unwrap(),
                "which is outside the workspace root",
            ),
            (
                "target/debug/out.rs",
                "which is under a directory the D48 scan skips",
            ),
            (
                ".venv/lib/x.rs",
                "which is under a directory the D48 scan skips",
            ),
            (".git/x.rs", "which is under a directory the D48 scan skips"),
            (
                "../outside.rs",
                "which is not a plain path below the workspace root",
            ),
            ("crates/a/src/missing.rs", "which is not a file on disk"),
            ("crates/a/src", "which is not a .rs file"),
        ] {
            assert_eq!(unscanned(&root, dep), Some(reason), "{dep}");
        }
    }
}
