use std::process::Command;

#[test]
fn binary_runs_and_exits_cleanly() {
    let output = Command::new(env!("CARGO_BIN_EXE_nasion"))
        .output()
        .expect("nasion binary failed to start");
    assert!(output.status.success(), "exit status {:?}", output.status);
    assert!(output.stdout.is_empty());
    assert!(output.stderr.is_empty());
}
