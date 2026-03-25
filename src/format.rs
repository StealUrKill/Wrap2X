// Binary format for data.bin (matches Python packer format from pack_bin.py):
//
// IDENTIFIER              (magic bytes)
// [repeated entries]:
// path_len              (4 bytes, big-endian)
// path_bytes            (utf-8 encoded relative path)
// compressed_len        (4 bytes, big-endian)
// compressed_data       (brotli compressed)
// md5_digest            (32 bytes, hex-encoded string)
// IDENTIFIER            (magic bytes, marks end of entries)
// entry_point           (utf-8 string, e.g. "setup.exe" or "run.bat")

pub const IDENTIFIER: &[u8] = b"EXEPACKER";
pub const LENGTH_BYTES: usize = 4;
pub const MD5_LEN: usize = 32; // hex-encoded MD5 string, matching Python format

pub struct FileEntry {
    pub path: String,
    pub data: Vec<u8>,
}

/// Parse data.bin bytes into file entries + entry point name.
pub fn parse_data_bin(data: &[u8]) -> anyhow::Result<(Vec<FileEntry>, String)> {
    use anyhow::{bail, Context};

    let id_len = IDENTIFIER.len();

    // Check header
    if data.len() < id_len || &data[..id_len] != IDENTIFIER {
        bail!("Invalid data.bin: missing header identifier");
    }

    let mut pos = id_len;
    let mut entries = Vec::new();

    loop {
        // Check if we hit the footer identifier
        if pos + id_len <= data.len() && &data[pos..pos + id_len] == IDENTIFIER {
            pos += id_len;
            break;
        }

        if pos + LENGTH_BYTES > data.len() {
            bail!("Unexpected end of data.bin while reading path length");
        }

        // Read path
        let path_len =
            u32::from_be_bytes(data[pos..pos + LENGTH_BYTES].try_into()?) as usize;
        pos += LENGTH_BYTES;

        if pos + path_len > data.len() {
            bail!("Unexpected end of data.bin while reading path");
        }
        let path = std::str::from_utf8(&data[pos..pos + path_len])
            .context("Invalid UTF-8 in path")?
            .to_string();
        pos += path_len;

        // Read compressed data
        if pos + LENGTH_BYTES > data.len() {
            bail!("Unexpected end of data.bin while reading compressed length");
        }
        let compressed_len =
            u32::from_be_bytes(data[pos..pos + LENGTH_BYTES].try_into()?) as usize;
        pos += LENGTH_BYTES;

        if pos + compressed_len > data.len() {
            bail!("Unexpected end of data.bin while reading compressed data");
        }
        let compressed = &data[pos..pos + compressed_len];
        pos += compressed_len;

        // Read MD5 digest (32-byte hex string)
        if pos + MD5_LEN > data.len() {
            bail!("Unexpected end of data.bin while reading MD5 digest");
        }
        let expected_hex = std::str::from_utf8(&data[pos..pos + MD5_LEN])
            .context("Invalid UTF-8 in MD5 hex digest")?;
        pos += MD5_LEN;

        // Decompress
        let mut decompressed = Vec::new();
        brotli::BrotliDecompress(&mut &compressed[..], &mut decompressed)
            .context(format!("Failed to decompress: {}", path))?;

        // Verify MD5
        let actual_hex = format!("{:x}", md5::compute(&decompressed));
        if actual_hex != expected_hex {
            bail!(
                "MD5 mismatch for {}: expected {}, got {}",
                path,
                expected_hex,
                actual_hex,
            );
        }

        entries.push(FileEntry {
            path,
            data: decompressed,
        });
    }

    // Remaining bytes are the entry point name
    let entry_point = std::str::from_utf8(&data[pos..])
        .context("Invalid UTF-8 in entry point")?
        .to_string();

    Ok((entries, entry_point))
}
