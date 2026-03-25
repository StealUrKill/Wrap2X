#![windows_subsystem = "windows"]

mod format;

use std::fs;
use std::io::Write;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const CREATE_NO_WINDOW: u32 = 0x08000000;

const DATA_BIN: &[u8] = include_bytes!("../data.bin");

fn log_file() -> PathBuf {
    std::env::temp_dir().join("exe_packer_stub.log")
}

fn log(msg: &str) {
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_file())
    {
        let _ = writeln!(f, "{msg}");
    }
}

fn extract_to(dir: &Path) -> Result<String, String> {
    let (entries, entry_point) = format::parse_data_bin(DATA_BIN)
        .map_err(|e| format!("Parse error: {e}"))?;

    log(&format!("Extracting {} files...", entries.len()));

    for entry in &entries {
        let dest = dir.join(&entry.path);
        if let Some(parent) = dest.parent() {
            let _ = fs::create_dir_all(parent);
        }
        fs::write(&dest, &entry.data)
            .map_err(|e| format!("Write failed {}: {e}", dest.display()))?;
    }

    Ok(entry_point)
}

fn run() -> Result<(), String> {
    // Clear old log
    let _ = fs::remove_file(log_file());
    log("=== Stub starting ===");

    let tmp_base = std::env::temp_dir().join("exe_packer_run");
    let _ = fs::remove_dir_all(&tmp_base);
    fs::create_dir_all(&tmp_base)
        .map_err(|e| format!("Cannot create temp dir: {e}"))?;

    log(&format!("Temp dir: {}", tmp_base.display()));

    let entry_point = extract_to(&tmp_base)?;
    let entry_path = tmp_base.join(&entry_point);

    log(&format!("Entry: {} (exists={})", entry_path.display(), entry_path.is_file()));

    if !entry_path.is_file() {
        return Err(format!("Entry point not found: {entry_point}"));
    }

    // Try the simplest possible launch
    log("Spawning with cmd /C start ...");

    let status = Command::new("cmd")
        .args([
            "/C",
            "start",
            "",  // title (empty)
            "/D",
            &tmp_base.to_string_lossy(),
            "/WAIT",
            &entry_path.to_string_lossy(),
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| format!("Spawn failed: {e}"))?
        .wait()
        .map_err(|e| format!("Wait failed: {e}"))?;

    log(&format!("Exit code: {:?}", status.code()));

    // Cleanup
    let _ = fs::remove_dir_all(&tmp_base);
    log("Done.");

    Ok(())
}

fn main() {
    if let Err(e) = run() {
        log(&format!("FATAL: {e}"));
    }
}
