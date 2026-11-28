#!/usr/bin/env bash
# Check library shared by gate.sh and the hooks in .githooks/.
#
# Each check_* function prints what it found and returns 0 when clean, 1 on a
# violation and 2 when the check itself could not run. A check that cannot run
# never reports clean. A line starting with "note: " is a remark the gate shows
# next to PASS.
#
# The dash characters and the banned names are built from hex at runtime, so
# this file holds none of them literally and the checks never match themselves.

EN_DASH=$(printf '\xe2\x80\x93')
EM_DASH=$(printf '\xe2\x80\x94')
BANNED_PRODUCT=$(printf '\x63\x6c\x61\x75\x64\x65')
BANNED_VENDOR=$(printf '\x61\x6e\x74\x68\x72\x6f\x70\x69\x63')

# Agent instruction files and the project documents that live outside this
# repository. Matched case-insensitively against every path component.
INSTRUCTION_PATH_RE="(^|/)(${BANNED_PRODUCT}\.md|agents?\.md|gemini\.md|\.cursorrules|\.windsurfrules|\.clinerules|\.goosehints|\.roomodes|\.aider[^/]*|spec\.md|decisions\.md|status\.md|prior_work\.md|project-kickoff[^/]*)$"
INSTRUCTION_PATH_RE+="|(^|/)\.(${BANNED_PRODUCT}|cursor|windsurf|gemini|codex|clinerules|roo|kiro|junie|amazonq|augment|continue)/"
INSTRUCTION_PATH_RE+="|(^|/)\.github/(copilot-instructions\.md|instructions/|prompts/)"

CONVENTIONAL_PREFIX_RE='^(feat|fix|docs|test|refactor|chore): [^[:space:]]'
CLEANUP_VERB_RE='^[a-z]+: (fix|clean|clean up|cleanup|tidy|remove|replace|strip|normali[sz]e|correct|run|apply|trim|drop|convert|swap)( |$)'
CLEANUP_NOUN_RE='(^|[^a-z])(formatting|reformat|fmt|rustfmt|whitespace|trailing spaces?|indentation|punctuation|dash|dashes|hyphens?|line endings?)([^a-z]|$)'
FORMAT_ONLY_RE='^[a-z]+: (re)?format( |$)'

# Turns a search status into a check status. grep and git grep exit 0 on a
# match, 1 on no match and above 1 on an error, so a bare negation would turn
# an error into a pass.
search_result() {
    local status=$1 what=$2
    case $status in
        0) return 1 ;;
        1) return 0 ;;
        *)
            echo "$what failed to run (exit $status). Check that git and grep work in this directory."
            return 2
            ;;
    esac
}

# Arguments go to git grep. Pass --cached to search staged content.
check_dashes() {
    LC_ALL=C git grep -n -F -e "$EN_DASH" -e "$EM_DASH" "$@"
    search_result $? "dash search"
}

# Arguments go to git grep. Pass --cached to search staged content.
check_banned_content() {
    LC_ALL=C git grep -n -i -F -e "$BANNED_PRODUCT" -e "$BANNED_VENDOR" "$@"
    search_result $? "banned name search in file contents"
}

# Arguments are a command that prints NUL-separated paths.
check_banned_paths() {
    "$@" | LC_ALL=C grep -z -i -F -e "$BANNED_PRODUCT" -e "$BANNED_VENDOR" | tr '\0' '\n'
    local statuses=("${PIPESTATUS[@]}")
    if ((statuses[0] != 0)); then
        echo "Listing paths with \"$*\" failed (exit ${statuses[0]})."
        return 2
    fi
    search_result "${statuses[1]}" "banned name search in paths"
}

check_banned_messages() {
    local log
    if ! log=$(git log --format='commit %H%n%B'); then
        echo "git log failed. Check that this repository has at least one commit."
        return 2
    fi
    LC_ALL=C grep -i -F -e "$BANNED_PRODUCT" -e "$BANNED_VENDOR" <<<"$log"
    search_result $? "banned name search in commit messages"
}

# Arguments are a command that prints NUL-separated paths.
check_instruction_paths() {
    "$@" | LC_ALL=C grep -z -i -E -e "$INSTRUCTION_PATH_RE" | tr '\0' '\n'
    local statuses=("${PIPESTATUS[@]}")
    if ((statuses[0] != 0)); then
        echo "Listing paths with \"$*\" failed (exit ${statuses[0]})."
        return 2
    fi
    search_result "${statuses[1]}" "instruction file search"
}

# Miri is not set up yet, so no unsafe code may compile in the workspace.
# Forbidding unsafe_code on the command line turns every opt-out into a compile
# error wherever it comes from: an untracked file, a #[path] module or a macro.
# Registry dependencies build with --cap-lints, so the forbid reaches only
# workspace members and path dependencies. Code under cfg(windows) or
# cfg(unix) compiles only for its own target, so the check runs once for each
# platform D23 ships, each in its own target directory. The host run passes no
# --target, because with --target cargo does not pass RUSTFLAGS to build
# scripts and proc macros. Returns 2 when the host is not the Linux target, a
# target is not installed or cargo fails for another reason.
#
# The gate runs on this target only. It is written here once and passed to
# the xtask as NASION_HOST_TARGET. The cross targets come only from the
# targets list in rust-toolchain.toml, read by the xtask (D59).
HOST_TARGET=x86_64-unknown-linux-gnu

# The cargo-audit the gate runs, an exact version (D62). The advisory database
# is deliberately not pinned: cargo audit fetches it into the fresh CARGO_HOME
# of every gate run (D55), so each run sees every advisory published so far.
CARGO_AUDIT_VERSION=0.23.0

# Prints the cross targets from rust-toolchain.toml, one per line, through
# the xtask's strict reader, which also fails when the host target is listed
# there (D59). Returns 2 and prints why when that fails, or when the xtask's
# stderr holds a warning line, such as one it forwarded from cargo (D41).
cross_targets() {
    local errors output status
    if ! errors=$(mktemp); then
        echo "mktemp failed, so the cross targets cannot be read. Check that the temporary directory is writable."
        return 2
    fi
    # Without --quiet, because --quiet also hides cargo's warnings while it
    # builds the xtask (D41). The list is on stdout, all of cargo's lines and
    # the xtask's own stderr are in the file.
    output=$(NASION_HOST_TARGET=$HOST_TARGET CARGO_TERM_COLOR=never \
        cargo run --locked -p nasion-xtask -- toolchain-targets 2>"$errors")
    status=$?
    if ((status != 0)); then
        cat "$errors"
        [[ -n $output ]] && echo "$output"
        echo "Reading the cross targets from rust-toolchain.toml failed (exit $status)."
        rm -f "$errors"
        return 2
    fi
    warning_lines "$(<"$errors")" "cargo run -p nasion-xtask -- toolchain-targets"
    status=$?
    rm -f "$errors"
    if ((status != 0)); then
        echo "Reading the cross targets from rust-toolchain.toml printed warnings (D41)."
        return 2
    fi
    echo "$output"
}

# Prints the lowest Python version allowed by requires-python in
# pyproject.toml. PyO3 needs it when it cannot run the target's interpreter.
MIN_PYTHON_PY='
import re, sys, tomllib
try:
    with open("pyproject.toml", "rb") as pyproject:
        requires = tomllib.load(pyproject)["project"]["requires-python"]
except (OSError, KeyError, TypeError, ValueError) as error:
    print("Reading requires-python from pyproject.toml failed:", error)
    sys.exit(2)
match = re.fullmatch(r">=\s*(3\.\d+)", requires)
if match is None:
    print("requires-python in pyproject.toml is", repr(requires) + ", expected the form >=3.N")
    sys.exit(2)
print(match.group(1))
'

# Checks that rustc runs on HOST_TARGET and that every cross target in
# rust-toolchain.toml is installed, then prints the lowest Python version from
# requires-python on the first line and the cross targets on the lines after
# it. Returns 2 and prints why when any of that fails.
targets_ready() {
    local version host_lines hosts=() host shown sysroot target found_python cross list=()
    if ! version=$(rustc -vV); then
        echo "rustc -vV failed. Check that the toolchain in rust-toolchain.toml is installed."
        return 2
    fi
    if ! host_lines=$(sed -n '/^host: /p' <<<"$version"); then
        echo "Reading the host line from the rustc -vV output failed. Check that sed works."
        return 2
    fi
    if [[ -n $host_lines ]]; then
        mapfile -t hosts <<<"$host_lines"
    fi
    if ((${#hosts[@]} == 0)); then
        echo "rustc -vV printed no host line. Check which rustc is first on PATH."
        return 2
    fi
    if ((${#hosts[@]} > 1)); then
        echo "rustc -vV printed ${#hosts[@]} host lines, expected exactly one. Check which rustc is first on PATH."
        return 2
    fi
    host=${hosts[0]#host: }
    if ! sysroot=$(rustc --print sysroot); then
        echo "rustc --print sysroot failed. Check that the toolchain in rust-toolchain.toml is installed."
        return 2
    fi
    if [[ $host != "$HOST_TARGET" ]]; then
        printf -v shown '%q' "$host"
        echo "rustc reports host $shown, printed shell-quoted so hidden characters show. The gate runs on $HOST_TARGET, so the host check would not cover that target."
        return 2
    fi
    if ! cross=$(cross_targets); then
        echo "$cross"
        return 2
    fi
    mapfile -t list <<<"$cross"
    for target in "${list[@]}"; do
        if [[ ! -d $sysroot/lib/rustlib/$target/lib ]]; then
            echo "The standard library for $target is not installed in $sysroot. Run rustup target add $target."
            return 2
        fi
    done
    if ! found_python=$(python3 -I -c "$MIN_PYTHON_PY"); then
        echo "$found_python"
        return 2
    fi
    echo "$found_python"
    echo "$cross"
}

check_unsafe_allow() {
    local ready lines python target output status worst=0 unsafe_targets=()
    if ! ready=$(targets_ready); then
        echo "$ready"
        return 2
    fi
    mapfile -t lines <<<"$ready"
    python=${lines[0]}
    for target in "$HOST_TARGET" "${lines[@]:1}"; do
        local target_args=()
        [[ $target != "$HOST_TARGET" ]] && target_args=(--target "$target")
        output=$(PYO3_CROSS_PYTHON_VERSION=$python RUSTFLAGS="-F unsafe_code" \
            CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-target}/forbid-check-$target" CARGO_TERM_COLOR=never \
            cargo check --locked --workspace --all-targets --all-features "${target_args[@]}" 2>&1)
        status=$?
        if ((status == 0)); then
            warning_lines "$output" "cargo check for $target"
            case $? in
                0) ;;
                1) worst=$((worst > 1 ? worst : 1)) ;;
                *) worst=2 ;;
            esac
            continue
        fi
        echo "$output"
        LC_ALL=C grep -q -F 'unsafe_code' <<<"$output"
        case $? in
            0)
                echo "Unsafe code compiles for $target."
                unsafe_targets+=("$target")
                worst=$((worst > 1 ? worst : 1))
                ;;
            1)
                echo "cargo check for $target failed (exit $status) for a reason other than unsafe code. Fix the error above."
                worst=2
                ;;
            *)
                echo "Searching the cargo check output for $target for unsafe_code failed. Check that grep works."
                worst=2
                ;;
        esac
    done
    if ((worst == 0)); then
        echo "note: no unsafe"
        return 0
    fi
    if ((${#unsafe_targets[@]} > 0)); then
        echo "Miri is not set up. Record a decision that pins its nightly toolchain and add it to the gate."
    fi
    return "$worst"
}

# Prints one line for each proc-macro target of a workspace member, read from
# cargo metadata on stdin (D52). Exits 2 when the metadata cannot be read.
PROC_MACRO_TARGETS_PY='
import json, sys
try:
    found = [
        package["name"]
        for package in json.load(sys.stdin)["packages"]
        for target in package["targets"]
        if "proc-macro" in target["kind"]
    ]
except (KeyError, TypeError, ValueError) as error:
    print("Reading cargo metadata failed:", error)
    sys.exit(2)
for name in found:
    print(name, "has a proc-macro target, and no workspace member may have one (D52)")
'

# Prints one line for each workspace member whose Cargo.toml does not set
# [lints] workspace = true, read from cargo metadata on stdin.
LINTS_INHERIT_PY='
import json, sys, tomllib
for package in json.load(sys.stdin)["packages"]:
    with open(package["manifest_path"], "rb") as manifest:
        lints = tomllib.load(manifest).get("lints", {})
    if not (isinstance(lints, dict) and lints.get("workspace") is True):
        print(package["manifest_path"], "does not set [lints] workspace = true")
'

# Prints one line for each Cargo.toml on disk that is neither the workspace
# root manifest nor the manifest of a workspace member, read from cargo metadata
# on stdin. target/ and .venv/ hold build output and .git/ holds no sources, so
# all three are skipped at the root. Exits 0 clean, 1 stray found, 2 failed.
STRAY_MANIFESTS_PY='
import json, os, sys

SKIPPED = {"target", ".venv", ".git"}

# os.walk silently skips a directory it cannot read unless onerror raises.
def raise_error(error):
    raise error

try:
    metadata = json.load(sys.stdin)
    root = metadata["workspace_root"]
    known = {os.path.join(root, "Cargo.toml")}
    known.update(package["manifest_path"] for package in metadata["packages"])
    stray = []
    for directory, subdirectories, files in os.walk(root, onerror=raise_error):
        if directory == root:
            subdirectories[:] = [d for d in subdirectories if d not in SKIPPED]
        manifest = os.path.join(directory, "Cargo.toml")
        if "Cargo.toml" in files and manifest not in known:
            stray.append(manifest)
except (OSError, KeyError, TypeError, ValueError) as error:
    print("Listing Cargo.toml files or reading cargo metadata failed:", error)
    sys.exit(2)
for manifest in sorted(stray):
    print(manifest, "is not the manifest of a workspace member")
sys.exit(1 if stray else 0)
'

# Every workspace member must inherit [workspace.lints] and have no proc-macro
# target (D52). Members come from cargo metadata, never from a fixed list, and
# every Cargo.toml on disk must belong to a member so none escapes that list.
check_deny_unsafe() {
    local meta meta_err missing stray macros status output warned=0
    if ! meta_err=$(mktemp); then
        echo "mktemp failed, so the stderr of cargo metadata cannot be kept. Check that the temporary directory is writable."
        return 2
    fi
    meta=$(CARGO_TERM_COLOR=never cargo metadata --no-deps --format-version 1 2>"$meta_err")
    status=$?
    output=$(<"$meta_err")
    rm -f "$meta_err"
    echo "$output"
    if ((status != 0)); then
        echo "cargo metadata failed. Check that every Cargo.toml in the workspace parses and that every directory under crates/ holds a Cargo.toml."
        return 2
    fi
    warning_lines "$output" "cargo metadata"
    case $? in
        1) warned=1 ;;
        2) return 2 ;;
    esac
    if ! missing=$(python3 -I -c "$LINTS_INHERIT_PY" <<<"$meta"); then
        echo "Reading cargo metadata or a member Cargo.toml failed. Check the output above."
        return 2
    fi
    stray=$(python3 -I -c "$STRAY_MANIFESTS_PY" <<<"$meta")
    status=$?
    if ((status > 1)); then
        echo "$stray"
        return 2
    fi
    missing+=${stray:+${missing:+$'\n'}$stray}
    if ! macros=$(python3 -I -c "$PROC_MACRO_TARGETS_PY" <<<"$meta"); then
        echo "$macros"
        return 2
    fi
    missing+=${macros:+${missing:+$'\n'}$macros}
    # Without --quiet, because --quiet also hides cargo's warnings.
    output=$(CARGO_TERM_COLOR=never cargo run --locked -p nasion-xtask 2>&1)
    status=$?
    echo "$output"
    if ((status > 1)); then
        echo "nasion-xtask could not check the target roots (exit $status). Check the output above."
        return 2
    fi
    warning_lines "$output" "cargo run -p nasion-xtask"
    case $? in
        1) warned=1 ;;
        2) return 2 ;;
    esac
    if [[ -n $missing ]]; then
        echo "$missing"
        return 1
    fi
    ((status == 0)) && return "$warned"
    return "$status"
}

# Records the work tree, or compares it with a recorded state on stdin. The
# state is the output of git status --porcelain=v1 -z --untracked-files=all
# plus a SHA-256 of every tracked file and every untracked file that is not
# ignored, as it is on disk. Ignored paths such as target/ and .venv/ stay out
# because build steps write there by design. Exits 0 unchanged, 1 changed
# (naming each path), 2 when git fails or the state cannot be read.
TREE_STATE_PY='
import hashlib, json, os, subprocess, sys

def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError("git " + " ".join(args) + " failed: " + detail)
    return [entry.decode(errors="surrogateescape") for entry in result.stdout.split(b"\0") if entry]

def content(path):
    if os.path.islink(path):
        return "link:" + os.readlink(path)
    if os.path.isdir(path):
        return "directory"
    if not os.path.exists(path):
        return "missing"
    with open(path, "rb") as tracked_file:
        return "sha256:" + hashlib.sha256(tracked_file.read()).hexdigest()

def snapshot():
    status = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    paths = git("ls-files", "-z") + git("ls-files", "-z", "--others", "--exclude-standard")
    return {"status": sorted(status), "content": {path: content(path) for path in paths}}

# A status record is "XY path". The source path of a rename comes as its own
# record without the XY prefix.
def status_path(record):
    return record[3:] if record[2:3] == " " else record

try:
    if sys.argv[1] == "snapshot":
        print(json.dumps(snapshot()))
        sys.exit(0)
    before = json.loads(sys.stdin.read())
    after = snapshot()
    changed = {status_path(r) for r in set(before["status"]) ^ set(after["status"])}
    for path in before["content"].keys() | after["content"].keys():
        if before["content"].get(path) != after["content"].get(path):
            changed.add(path)
except (OSError, RuntimeError, KeyError, TypeError, ValueError) as error:
    print("Recording the work tree state failed:", error)
    sys.exit(2)
for path in sorted(changed):
    print(path, "changed, appeared or disappeared while the gate ran")
sys.exit(1 if changed else 0)
'

# The argument is the state recorded before the first gate step.
check_tree_unchanged() {
    local status
    python3 -I -c "$TREE_STATE_PY" compare <<<"$1"
    status=$?
    if ((status > 2)); then
        echo "python3 failed to compare the work tree state (exit $status)."
        return 2
    fi
    return "$status"
}

# A warning line as cargo, rustc, rustfmt and uv print it, with an optional
# lint code, or as maturin prints it, after a warning sign emoji.
WARNING_SIGN=$(printf '\xe2\x9a\xa0\xef\xb8\x8f')
WARNING_LINE_RE="^(${WARNING_SIGN} +)?(warning|Warning)(\\[[^]]*\\])?:"

# Prints the warning lines in $1, the output of the command named in $2.
# Returns 0 when there are none, 1 when there are some and 2 when the search
# failed.
warning_lines() {
    local found
    found=$(LC_ALL=C grep -E "$WARNING_LINE_RE" <<<"$1")
    case $? in
        0)
            echo "$2 printed warnings. Fix each one at its source:"
            echo "$found"
            return 1
            ;;
        1) return 0 ;;
        *)
            echo "Searching the output of $2 for warnings failed. Check that grep works."
            return 2
            ;;
    esac
}

# Runs a command with cargo colour off, so colour codes cannot hide a warning,
# and fails it when it prints one. Returns 2 when the search failed, else the
# command's status when it failed, else 1 when it printed a warning.
fail_on_warnings() {
    local output status warned
    output=$(CARGO_TERM_COLOR=never "$@" 2>&1)
    status=$?
    echo "$output"
    warning_lines "$output" "$*"
    warned=$?
    ((warned == 2)) && return 2
    ((status != 0)) && return "$status"
    return "$warned"
}

# Like fail_on_warnings, and names the fix when cargo warns that a member does
# not inherit [workspace.lints].
check_cargo_lints_warning() {
    local output status
    output=$(fail_on_warnings "$@")
    status=$?
    echo "$output"
    LC_ALL=C grep -F "missing \`[lints]\` to inherit \`[workspace.lints]\`" <<<"$output" >/dev/null
    search_result $? "search for the cargo [lints] warning" || {
        local search=$?
        ((search == 1)) && echo "A member does not inherit [workspace.lints]. Add [lints] workspace = true to its Cargo.toml."
        ((search == 2)) && return 2
    }
    return "$status"
}

# Fails when rustdoc lists any doctest in the workspace (D70), counted from
# the "N tests, M benchmarks" lines of the listing, one per doctest run.
# nasion-py is left out: it is a cdylib only, which rustdoc does not test, and
# listing it makes cargo warn.
check_no_doctests() {
    local output status counts count
    output=$(fail_on_warnings cargo test --doc --locked --workspace --exclude nasion-py -- --list)
    status=$?
    echo "$output"
    ((status != 0)) && return "$status"
    counts=$(sed -nE 's/^([0-9]+) tests?, [0-9]+ benchmarks?$/\1/p' <<<"$output")
    if [[ -z $counts ]]; then
        echo "The doctest listing has no \"N tests, M benchmarks\" line, so the doctests cannot be counted (D70)."
        return 2
    fi
    for count in $counts; do
        if ((count > 0)); then
            echo "rustdoc lists the doctests above. Doctests are not allowed; examples go under tests/ (D70)."
            return 1
        fi
    done
}

# Runs clippy with -D warnings once on the host and once for each cross target
# (D38), the same split as check_unsafe_allow, each in its own target
# directory. Each run fails on warnings and on the [lints] warning, and a
# failure names the target.
check_clippy() {
    local ready lines python target status worst=0 target_args
    if ! ready=$(targets_ready); then
        echo "$ready"
        return 2
    fi
    mapfile -t lines <<<"$ready"
    python=${lines[0]}
    for target in "$HOST_TARGET" "${lines[@]:1}"; do
        target_args=()
        [[ $target != "$HOST_TARGET" ]] && target_args=(--target "$target")
        PYO3_CROSS_PYTHON_VERSION=$python CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-target}/clippy-$target" \
            check_cargo_lints_warning cargo clippy --locked --workspace --all-targets --all-features \
            "${target_args[@]}" -- -D warnings
        status=$?
        ((status == 0)) && continue
        echo "cargo clippy for $target failed (exit $status)."
        if ((status == 2)); then
            worst=2
        else
            worst=$((worst > 1 ? worst : 1))
        fi
    done
    return "$worst"
}

# Runs cargo audit once its version is the pinned one (D62). `cargo audit
# --version` prints "cargo-audit-audit <version>" and nothing else: read in
# rustsec/rustsec at tag cargo-audit/v0.23.0, where commands/audit.rs puts
# #[command(version)] on the audit subcommand, so clap prints that
# subcommand's name, cargo-audit-audit, then the crate version. Any other
# output, a different version or no cargo-audit at all returns 2 before the
# audit runs.
check_cargo_audit() {
    local output shown found install="cargo install cargo-audit --locked --version $CARGO_AUDIT_VERSION"
    if ! command -v cargo-audit >/dev/null; then
        echo "cargo-audit is not on PATH. The gate pins $CARGO_AUDIT_VERSION (D62). Install it: $install"
        return 2
    fi
    if ! output=$(CARGO_TERM_COLOR=never cargo audit --version 2>&1); then
        echo "$output"
        echo "cargo audit --version failed. The gate pins cargo-audit $CARGO_AUDIT_VERSION (D62). Install it: $install"
        return 2
    fi
    if [[ ! $output =~ ^cargo-audit-audit\ ([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        printf -v shown '%q' "$output"
        echo "cargo audit --version printed $shown, shell-quoted, not \"cargo-audit-audit <version>\". The gate pins cargo-audit $CARGO_AUDIT_VERSION (D62). Install it: $install"
        return 2
    fi
    found=${BASH_REMATCH[1]}
    if [[ $found != "$CARGO_AUDIT_VERSION" ]]; then
        echo "cargo-audit is $found, but the gate pins $CARGO_AUDIT_VERSION (D62). Install it: $install"
        return 2
    fi
    fail_on_warnings cargo audit --deny warnings --file Cargo.lock
}

# With a fresh CARGO_HOME, the only cargo config files left are .cargo/config
# and .cargo/config.toml in the working directory and each parent (walk_tree
# in src/context/mod.rs of cargo 1.100.0). The gate allows none of them,
# whatever they hold (D55). $1 is the gate's environment allowlist, shown in
# the note so a run records what it kept.
check_cargo_env() {
    local dir=$PWD name found=()
    while :; do
        for name in config config.toml; do
            if [[ -e $dir/.cargo/$name || -L $dir/.cargo/$name ]]; then
                found+=("$dir/.cargo/$name")
            fi
        done
        [[ $dir == / ]] && break
        dir=$(dirname "$dir")
    done
    if ((${#found[@]} > 0)); then
        printf '%s\n' "${found[@]}"
        echo "Cargo reads the config files above for every build from this directory, and the gate allows none (D55). Move them out of the repository and its parent directories."
        return 1
    fi
    echo "note: env $1; set by the gate: CARGO_HOME CARGO_TARGET_DIR VIRTUAL_ENV UV_PROJECT_ENVIRONMENT"
}

# The Python environment is locked and built by the gate (D28, D54). uv.lock
# holds every package with its file hashes; uv itself is pinned by
# required-version in pyproject.toml and the interpreter by .python-version.
# Read in astral-sh/uv at tag 0.12.1:
# - docs/concepts/projects/sync.md: uv lock --check fails when uv.lock does not
#   match pyproject.toml ("equivalent to the --locked flag"), --locked never
#   updates uv.lock, and uv sync is exact by default, removing packages that
#   are not in the lockfile.
# - docs/concepts/python-versions.md: uv reads the .python-version file in the
#   project to choose the interpreter.
# - crates/uv-settings/src/settings.rs, required-version: a uv that does not
#   meet it exits with an error.
# - docs/concepts/indexes.md: uv records one hash per distribution in the
#   lockfile when the index advertises it. The docs do not promise one for
#   every file, so UV_LOCK_HASHES_PY checks that every registry file has one.
UV_LOCK_HASHES_PY='
import re
import sys
import tomllib

try:
    with open("uv.lock", "rb") as lock:
        packages = tomllib.load(lock).get("package")
except (OSError, tomllib.TOMLDecodeError) as error:
    print("Reading uv.lock failed:", error)
    sys.exit(2)
if not isinstance(packages, list) or not packages:
    print("uv.lock has no [[package]] entries. Run uv lock.")
    sys.exit(2)
sha256 = re.compile(r"sha256:[0-9a-f]{64}")
problems = []
for package in packages:
    name = package.get("name", "an unnamed package")
    version = package.get("version", "with no version")
    if "registry" not in package.get("source", {}):
        continue
    files = [("sdist", package["sdist"])] if "sdist" in package else []
    files += [("wheel", wheel) for wheel in package.get("wheels", [])]
    if not files:
        problems.append(f"{name} {version} comes from a registry, but uv.lock lists no file for it.")
    for kind, entry in files:
        digest = entry.get("hash") if isinstance(entry, dict) else None
        url = entry.get("url", "with no url") if isinstance(entry, dict) else entry
        if not isinstance(digest, str) or sha256.fullmatch(digest) is None:
            problems.append(f"{name} {version} has a {kind} without a sha256 hash in uv.lock: {url}")
for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
'

# Builds .venv from uv.lock: the lock must match pyproject.toml and carry a
# hash for every registry file, the sync is exact and never rewrites uv.lock,
# and the interpreter must be the one .python-version pins. The local package
# is left to maturin develop in the pytest step.
check_python_env() {
    local pinned found status
    if ! command -v uv >/dev/null; then
        echo "uv is not on PATH. Install the uv version that required-version in pyproject.toml names."
        return 2
    fi
    fail_on_warnings uv lock --check
    status=$?
    if ((status != 0)); then
        echo "uv lock --check failed (exit $status). If pyproject.toml changed on purpose, run uv lock and commit uv.lock."
        return 1
    fi
    python3 -I -c "$UV_LOCK_HASHES_PY" || return
    fail_on_warnings uv sync --locked --no-install-project --no-default-groups --group dev
    status=$?
    if ((status != 0)); then
        echo "uv sync --locked failed (exit $status), so .venv does not match uv.lock."
        return 1
    fi
    if ! pinned=$(<.python-version); then
        echo "Reading .python-version failed. It pins the interpreter for .venv."
        return 2
    fi
    pinned=${pinned%$'\n'}
    if ! found=$("$VIRTUAL_ENV/bin/python" -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'); then
        echo "Running $VIRTUAL_ENV/bin/python failed, so its version is unknown."
        return 2
    fi
    if [[ $found != "$pinned" ]]; then
        echo "$VIRTUAL_ENV runs Python $found, but .python-version pins $pinned. Remove .venv and run the gate again, and check that UV_PYTHON is not set."
        return 1
    fi
    echo "note: Python $found"
}

# Prints the locked dev group, without the local project, as a requirements
# file. With hashes for pip-audit, without them for the venv comparison.
export_lock() {
    uv export --locked --quiet --format requirements-txt --no-emit-project --no-default-groups --group dev --no-header --no-annotate "$@"
}

# Compares .venv with the exported lock: every package whose marker holds here
# must be installed at its locked version, nothing else may be installed, and
# the local package must be installed from this tree. Run with the venv's
# interpreter, which has packaging from the lock.
VENV_MATCHES_LOCK_PY='
import json
import re
import sys
from importlib import metadata
from pathlib import Path

try:
    from packaging.markers import Marker
    from packaging.version import Version
except ImportError as error:
    print("packaging is not importable in .venv:", error)
    sys.exit(2)


def normal(name):
    return re.sub(r"[-_.]+", "-", name).lower()


export_path, root = sys.argv[1], Path(sys.argv[2]).resolve()
try:
    lines = Path(export_path).read_text().splitlines()
except OSError as error:
    print("Reading the exported lock failed:", error)
    sys.exit(2)
expected = {}
for line in lines:
    if not line.strip():
        continue
    requirement, _, marker = line.partition(";")
    name, separator, version = requirement.strip().partition("==")
    if not separator or not name or not version or " " in version:
        print("The exported lock has a line this check cannot read:", line)
        sys.exit(2)
    if marker.strip() and not Marker(marker.strip()).evaluate():
        continue
    expected[normal(name)] = version
installed = {}
local = []
problems = []
for dist in metadata.distributions():
    name = normal(dist.metadata["Name"])
    if name == "nasion":
        local.append(dist)
    elif name in installed:
        problems.append(f"{name} is installed twice in .venv.")
    else:
        installed[name] = dist.version
for name in sorted(expected.keys() - installed.keys()):
    problems.append(f"{name} {expected[name]} is locked but not installed in .venv.")
for name in sorted(installed.keys() - expected.keys()):
    problems.append(f"{name} {installed[name]} is installed in .venv but not locked.")
for name in sorted(expected.keys() & installed.keys()):
    if Version(expected[name]) != Version(installed[name]):
        problems.append(f"{name} is locked at {expected[name]}, but .venv has {installed[name]}.")
if len(local) != 1:
    problems.append(f"The local package nasion is installed {len(local)} times in .venv, expected once. The pytest step installs it with maturin develop.")
else:
    direct = local[0].read_text("direct_url.json")
    try:
        url = json.loads(direct).get("url") if direct else None
    except json.JSONDecodeError as error:
        print("Reading direct_url.json of nasion failed:", error)
        sys.exit(2)
    if url != root.as_uri():
        problems.append(f"nasion in .venv comes from {url}, not from this tree at {root.as_uri()}.")
for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
'

check_venv_matches_lock() {
    local requirements status
    if ! requirements=$(mktemp); then
        echo "mktemp failed, so the lock cannot be exported. Check that the temporary directory is writable."
        return 2
    fi
    if ! export_lock --no-hashes >"$requirements"; then
        echo "uv export --locked failed, so .venv cannot be compared with uv.lock."
        rm -f "$requirements"
        return 2
    fi
    venv_tool python -I -c "$VENV_MATCHES_LOCK_PY" "$requirements" "$PWD"
    status=$?
    rm -f "$requirements"
    return "$status"
}

# Checks one sdist in the directory $1 for rust-toolchain.toml at its root,
# with the same bytes as the file in the current directory. Exits 0 when it
# is there once and identical, 1 when it is missing, differs, is not a
# regular file or is there more than once, 2 when the sdist cannot be read.
SDIST_TOOLCHAIN_PY='
import pathlib
import sys
import tarfile

out = pathlib.Path(sys.argv[1])
name = "rust-toolchain.toml"
archives = sorted(out.glob("*.tar.gz"))
if len(archives) != 1:
    print(f"maturin sdist wrote {len(archives)} .tar.gz files to {out}, expected one (D66).")
    sys.exit(2)
try:
    want = pathlib.Path(name).read_bytes()
    with tarfile.open(archives[0]) as sdist:
        members = sdist.getmembers()
        tops = {member.name.split("/", 1)[0] for member in members}
        if len(tops) != 1:
            print(f"The sdist {archives[0].name} has {len(tops)} top directories, expected one (D66).")
            sys.exit(2)
        path = tops.pop() + "/" + name
        found = [member for member in members if member.name == path]
        if not found:
            print(f"The sdist {archives[0].name} has no {path}, so a wheel built from it compiles with the builder default toolchain, not the pin. Add {name} to include in [tool.maturin] in pyproject.toml (D66).")
            sys.exit(1)
        if len(found) > 1:
            print(f"The sdist {archives[0].name} holds {path} {len(found)} times, expected once (D66).")
            sys.exit(1)
        member = found[0]
        if not member.isfile():
            print(f"{path} in the sdist {archives[0].name} is not a regular file (D66).")
            sys.exit(1)
        extracted = sdist.extractfile(member)
        got = extracted.read() if extracted else b""
except (OSError, tarfile.TarError) as error:
    print("Reading the sdist failed:", error)
    sys.exit(2)
if got != want:
    print(f"{path} in the sdist {archives[0].name} differs from {name} in the repository, so a wheel built from it does not use the pinned toolchain (D66).")
    sys.exit(1)
'

# Builds the sdist into $1. A failed maturin prints the D66 line and returns 3,
# so that through fail_on_warnings 1 still means a warning and 2 a failed
# warning search.
maturin_sdist() {
    local status
    CARGO_NET_OFFLINE=true venv_tool maturin sdist --out "$1"
    status=$?
    ((status == 0)) && return 0
    echo "maturin sdist failed (exit $status), so the sdist cannot be checked for rust-toolchain.toml (D66). Its output is above."
    return 3
}

# Builds the sdist with the venv's locked maturin into a fresh directory under
# $1, the gate's temporary directory, never into the tree, and checks that it
# carries rust-toolchain.toml unchanged, so a wheel built from it compiles with
# the pinned toolchain (D66). cargo runs offline on the crates the earlier
# steps fetched into the gate's cargo home. A warning from maturin or cargo
# fails the step (D67).
check_sdist_toolchain() {
    local out output status
    if ! out=$(mktemp -d "$1/sdist.XXXXXX"); then
        echo "mktemp -d under $1 failed, so the sdist has nowhere to go (D66)."
        return 2
    fi
    output=$(fail_on_warnings maturin_sdist "$out")
    status=$?
    if ((status != 0)); then
        echo "$output"
        rm -rf -- "$out"
        if ((status == 1)); then
            echo "maturin sdist printed a warning, so the sdist step fails. Fix the warning at its source (D67)."
            return 1
        fi
        return 2
    fi
    python3 -I -c "$SDIST_TOOLCHAIN_PY" "$out"
    status=$?
    rm -rf -- "$out"
    return "$status"
}

# The dataset manifest does not exist yet, so neither does its hash check. A
# manifest that appears before the check is written fails the gate.
check_manifest() {
    local tracked found
    if ! tracked=$(git ls-files); then
        echo "git ls-files failed. Check that this is a git work tree."
        return 2
    fi
    found=$(grep -i 'manifest' <<<"$tracked")
    if [[ -z $found ]]; then
        echo "note: no manifest yet"
        return 0
    fi
    echo "$found"
    echo "A manifest is tracked but the manifest hash check is not written yet."
    return 1
}

check_msg_single_line() {
    if [[ -z $1 ]]; then
        echo "Commit message is empty."
        return 1
    fi
    if [[ $1 == *$'\n'* ]]; then
        echo "Commit message has more than one line. Use one line with no body."
        return 1
    fi
}

check_msg_prefix() {
    local subject=${1%%$'\n'*}
    if [[ ! $subject =~ $CONVENTIONAL_PREFIX_RE ]]; then
        echo "Subject \"$subject\" must start with feat, fix, docs, test, refactor or chore, then \": \" and text."
        return 1
    fi
}

check_msg_trailers() {
    local rest
    [[ $1 == *$'\n'* ]] || return 0
    rest=${1#*$'\n'}
    grep -E '^[A-Za-z][A-Za-z0-9-]*:( |$)' <<<"$rest"
    search_result $? "trailer search in the commit message" || {
        local status=$?
        ((status == 1)) && echo "Commit message has a trailer line. Remove it."
        return "$status"
    }
}

check_msg_banned() {
    LC_ALL=C grep -i -F -e "$BANNED_PRODUCT" -e "$BANNED_VENDOR" <<<"$1"
    search_result $? "banned name search in the commit message" || {
        local status=$?
        ((status == 1)) && echo "Commit message names a banned tool or vendor."
        return "$status"
    }
}

check_msg_dashes() {
    LC_ALL=C grep -F -e "$EN_DASH" -e "$EM_DASH" <<<"$1"
    search_result $? "dash search in the commit message" || {
        local status=$?
        ((status == 1)) && echo "Commit message has an em dash or en dash."
        return "$status"
    }
}

# A subject that only describes a formatting, dash, punctuation or whitespace
# cleanup. Such fixes ride inside a commit that changes the file for a real
# reason.
check_msg_cleanup() {
    local subject
    subject=$(tr '[:upper:]' '[:lower:]' <<<"${1%%$'\n'*}")
    if [[ $subject =~ $FORMAT_ONLY_RE ]] || { [[ $subject =~ $CLEANUP_VERB_RE ]] && [[ $subject =~ $CLEANUP_NOUN_RE ]]; }; then
        echo "Subject \"$subject\" only describes a formatting, dash, punctuation or whitespace cleanup."
        return 1
    fi
}
