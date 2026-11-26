#!/usr/bin/env bash
# The project gate. Runs every step, keeps going after a failure, prints one
# PASS or FAIL line per step and exits non-zero if any step failed.
set -u

# The gate takes no arguments. Every cargo, uv and tool command line is built
# here and in scripts/checks.sh, and no step accepts extra arguments from the
# caller, so nothing like cargo's --config can come in from outside (D55).
if (($# > 0)); then
    echo "gate.sh takes no arguments, and got $#. Run it as ./gate.sh."
    exit 2
fi

# The only environment variables the gate keeps from its caller (D55). The
# gate runs again under env -i with these alone, so RUSTC, RUSTC_WRAPPER,
# RUSTFLAGS, CARGO_* and UV_* from the caller's shell never reach a step.
# CARGO_HOME, CARGO_TARGET_DIR, VIRTUAL_ENV and UV_PROJECT_ENVIRONMENT are set
# below by the gate itself, and the steps set their own per-command variables.
GATE_ENV_KEEP=(
    PATH HOME RUSTUP_HOME TMPDIR LANG
    http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE
)
# The check reads the environment this process was started with, not the
# variables bash lists, because bash imports more than compgen -e shows. Read
# in bash 5.2 (the version here, 5.2.21): the manual says functions are
# exported "with the -f option to the export builtin", and
# initialize_shell_variables in variables.c imports every entry named
# BASH_FUNC_<name>%% whose value starts with "() {" as a function, whatever
# the name, and marks it exported. An entry whose name is not a valid
# identifier is kept as an invisible exported variable. Neither shows in
# compgen -e, and both reach child processes. So any entry not on the
# allowlist, an exported function included, makes the gate run again under
# env -i, which passes the allowlisted variables alone. That second run starts
# with nothing else, so it does not run again.
if ! mapfile -d '' -t GATE_ENV_START </proc/$$/environ; then
    echo "Reading /proc/$$/environ failed, so the gate cannot check the environment it started with."
    exit 2
fi
declare -A GATE_ENV_ALLOWED=()
for keep in "${GATE_ENV_KEEP[@]}"; do
    GATE_ENV_ALLOWED[$keep]=1
done
for entry in "${GATE_ENV_START[@]}"; do
    name=${entry%%=*}
    if [[ -z $name || -z ${GATE_ENV_ALLOWED[$name]-} ]]; then
        kept=()
        for keep in "${GATE_ENV_KEEP[@]}"; do
            [[ -v $keep ]] && kept+=("$keep=${!keep}")
        done
        exec env -i "${kept[@]}" "$BASH" "$0"
    fi
done

cd "$(dirname "$0")" || exit 2
# shellcheck source=scripts/checks.sh
source scripts/checks.sh

# A fresh cargo home and target directory for this run alone, removed when
# the gate ends, also on failure or interrupt (D55). Crates are downloaded and
# checksum-verified each run, and no build output from an earlier run, built
# perhaps from an edited cache, is reused.
if ! GATE_TMP=$(mktemp -d); then
    echo "mktemp -d failed, so the gate has no fresh cargo home. Check that TMPDIR is writable."
    exit 2
fi
# shellcheck disable=SC2329 # Called through trap, which shellcheck does not follow.
remove_gate_tmp() {
    rm -rf -- "${GATE_TMP:?}"
}
trap remove_gate_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export CARGO_HOME="$GATE_TMP/cargo-home" CARGO_TARGET_DIR="$GATE_TMP/target"
mkdir -p "$CARGO_HOME" "$CARGO_TARGET_DIR" || exit 2

VENV=.venv
export VIRTUAL_ENV="$PWD/$VENV"
# uv syncs this same directory, whatever the environment says.
export UV_PROJECT_ENVIRONMENT="$VIRTUAL_ENV"
failed=0
last_status=0
python_env_status=2

# On failure the step output follows the FAIL line, indented.
step() {
    local name=$1 output status note
    shift
    output=$("$@" 2>&1)
    status=$?
    last_status=$status
    note=$(grep -m1 '^note: ' <<<"$output" | sed 's/^note: //')
    if ((status == 0)); then
        echo "PASS $name${note:+ ($note)}"
        return
    fi
    echo "FAIL $name (exit $status)"
    printf '    %s\n' "${output//$'\n'/$'\n    '}"
    failed=1
}

# shellcheck disable=SC2329 # Called through step, which shellcheck does not follow.
venv_tool() {
    local tool=$1
    shift
    if ((python_env_status != 0)); then
        echo "The python env step failed, so $VENV is not used. Fix that step first."
        return 2
    fi
    if [[ ! -x $VENV/bin/$tool ]]; then
        echo "$VENV/bin/$tool not found, although the python env step passed. Check that the dev group in pyproject.toml lists it."
        return 2
    fi
    "$VENV/bin/$tool" "$@"
}

# shellcheck disable=SC2329 # Called through step, which shellcheck does not follow.
python_tests() {
    # Without --quiet, because --quiet also hides cargo's warnings.
    fail_on_warnings venv_tool maturin develop --locked --uv || return
    venv_tool pytest -q
}

# Audits uv.lock, exported with hashes and without the local package, which
# is not on PyPI and would otherwise fail the strict audit (D28).
# shellcheck disable=SC2329 # Called through step, which shellcheck does not follow.
python_audit() {
    local requirements status
    if ! requirements=$(mktemp); then
        echo "mktemp failed, so the lock cannot be exported. Check that the temporary directory is writable."
        return 2
    fi
    if ! export_lock >"$requirements"; then
        echo "uv export --locked failed, so the lock cannot be audited."
        rm -f "$requirements"
        return 2
    fi
    venv_tool pip-audit --strict --disable-pip --require-hashes -r "$requirements"
    status=$?
    rm -f "$requirements"
    return "$status"
}

# shellcheck disable=SC2329 # Called through step, which shellcheck does not follow.
banned_names() {
    local status=0
    check_banned_content -- || status=$?
    check_banned_paths git ls-files -z || status=$?
    check_banned_messages || status=$?
    return "$status"
}

# Taken before the first step so the last step can show the gate changed
# nothing it checked.
tree_before=$(python3 -I -c "$TREE_STATE_PY" snapshot 2>&1)

step "cargo env" check_cargo_env "${GATE_ENV_KEEP[*]}"
# Before the cargo steps, because they build nasion-py, whose PyO3 build script
# runs the interpreter in .venv.
step "python env" check_python_env
python_env_status=$last_status
step "cargo fmt" fail_on_warnings cargo fmt --all --check
step "cargo clippy" check_clippy
step "cargo test" fail_on_warnings cargo test --locked --workspace
step "miri" check_unsafe_allow
step "deny unsafe" check_deny_unsafe
step "cargo audit" check_cargo_audit
step "ruff check" venv_tool ruff check python
step "ruff format" venv_tool ruff format --check python
step "mypy" venv_tool mypy --strict python
step "pytest" python_tests
step "pip-audit" python_audit
step "venv matches lock" check_venv_matches_lock
step "dash sweep" check_dashes
step "instruction files" check_instruction_paths git ls-files -z
step "banned names" banned_names
step "manifest hash" check_manifest
step "sdist toolchain" check_sdist_toolchain "$GATE_TMP"
step "tree unchanged" check_tree_unchanged "$tree_before"

exit "$failed"
