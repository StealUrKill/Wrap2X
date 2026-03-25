use anyhow::{bail, Context, Result};
use rayon::prelude::*;
use serde::Deserialize;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;
use walkdir::WalkDir;

/// Matches format.rs constants
const IDENTIFIER: &[u8] = b"EXEPACKER";

#[derive(Deserialize)]
struct Config {
    entry_point: String,
    #[serde(default = "default_level")]
    brotli_level: u32,
    #[serde(default = "default_input")]
    input_dir: String,
    #[serde(default = "default_output")]
    output: String,
}

fn default_level() -> u32 { 6 }
fn default_input() -> String { "packer_files".into() }
fn default_output() -> String { "data.bin".into() }

struct CompressedFile {
    relative_path: String,
    compressed: Vec<u8>,
    digest: String, // 32-char hex string matching Python format
    original_size: usize,
}

fn compress_file(base: &Path, full_path: &Path, level: u32) -> Result<CompressedFile> {
    let relative = full_path
        .strip_prefix(base)?
        .to_string_lossy()
        .replace('\\', "/");

    let raw = fs::read(full_path)
        .with_context(|| format!("Failed to read {}", full_path.display()))?;

    let original_size = raw.len();
    let digest = format!("{:x}", md5::compute(&raw));

    let mut compressed = Vec::new();
    {
        let mut encoder = brotli::CompressorWriter::new(
            &mut compressed,
            4096,
            level,
            22,
        );
        encoder.write_all(&raw)?;
        encoder.flush()?;
    }

    Ok(CompressedFile {
        relative_path: relative,
        compressed,
        digest,
        original_size,
    })
}

fn collect_files(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for entry in WalkDir::new(dir) {
        let entry = entry?;
        if entry.file_type().is_file() {
            files.push(entry.into_path());
        }
    }
    files.sort();
    Ok(files)
}

fn main() -> Result<()> {
    let config_path = "packer.toml";
    let config_str = fs::read_to_string(config_path)
        .with_context(|| format!("Cannot read {config_path}. Create it with entry_point, brotli_level, input_dir, output."))?;
    let config: Config = toml::from_str(&config_str)?;

    let input_dir = PathBuf::from(&config.input_dir);
    if !input_dir.is_dir() {
        bail!("Input directory not found: {}", input_dir.display());
    }

    let files = collect_files(&input_dir)?;
    if files.is_empty() {
        bail!("No files found in {}", input_dir.display());
    }

    let total = files.len();
    let total_bytes: u64 = files.iter()
        .filter_map(|f| fs::metadata(f).ok())
        .map(|m| m.len())
        .sum();
    let num_threads = rayon::current_num_threads();
    println!(
        "Compressing {} files ({}) with {} threads (brotli level {})...\n",
        total,
        format_size(total_bytes as usize),
        num_threads,
        config.brotli_level,
    );

    let start = Instant::now();
    let done_count = AtomicUsize::new(0);

    // Compress all files in parallel with live progress - Implement Progress Bar Later
    let entries: Vec<Result<CompressedFile>> = files
        .par_iter()
        .map(|path| {
            let result = compress_file(&input_dir, path, config.brotli_level);
            let done = done_count.fetch_add(1, Ordering::Relaxed) + 1;
            let elapsed = start.elapsed().as_secs_f64();

            match &result {
                Ok(entry) => {
                    let ratio = if entry.original_size > 0 {
                        entry.compressed.len() as f64 / entry.original_size as f64 * 100.0
                    } else {
                        0.0
                    };
                    println!(
                        "  [{:>3}/{}] {:>10} -> {:>10} ({:>5.1}%)  {:.1}s  {}",
                        done,
                        total,
                        format_size(entry.original_size),
                        format_size(entry.compressed.len()),
                        ratio,
                        elapsed,
                        entry.relative_path,
                    );
                }
                Err(e) => {
                    println!(
                        "  [{:>3}/{}] ERROR: {}",
                        done, total, e,
                    );
                }
            }

            result
        })
        .collect();

    // Check for errors and collect
    let mut good_entries = Vec::with_capacity(total);
    for result in entries {
        good_entries.push(result?);
    }

    let elapsed = start.elapsed();
    let total_compressed: usize = good_entries.iter().map(|e| e.compressed.len()).sum();
    let overall_ratio = if total_bytes > 0 {
        total_compressed as f64 / total_bytes as f64 * 100.0
    } else {
        0.0
    };

    println!(
        "\nCompressed {} files in {:.1}s  ({} -> {} = {:.1}%)",
        total,
        elapsed.as_secs_f64(),
        format_size(total_bytes as usize),
        format_size(total_compressed),
        overall_ratio,
    );

    // Write data.bin
    let mut out = fs::File::create(&config.output)?;

    // Header
    out.write_all(IDENTIFIER)?;

    // Entries
    for entry in &good_entries {
        let path_bytes = entry.relative_path.as_bytes();
        out.write_all(&(path_bytes.len() as u32).to_be_bytes())?;
        out.write_all(path_bytes)?;
        out.write_all(&(entry.compressed.len() as u32).to_be_bytes())?;
        out.write_all(&entry.compressed)?;
        out.write_all(entry.digest.as_bytes())?;
    }

    // Footer
    out.write_all(IDENTIFIER)?;
    out.write_all(config.entry_point.as_bytes())?;

    out.flush()?;
    drop(out);

    let output_size = fs::metadata(&config.output)?.len();
    println!("Wrote {} ({})", config.output, format_size(output_size as usize));

    Ok(())
}

fn format_size(bytes: usize) -> String {
    if bytes >= 1_048_576 {
        format!("{:.1} MB", bytes as f64 / 1_048_576.0)
    } else if bytes >= 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{bytes} B")
    }
}
