#!/usr/bin/env python3
"""
Create a data.bin from a folder, with support for cached dependency packing.

Modes:
  Full pack (default):
    python pack_bin.py <folder>
    python pack_bin.py <folder> -l 6 -j 4

  Partial pack (for caching deps separately from exes):
    python pack_bin.py <folder> --exclude run.exe app.exe -o deps.bin --partial
    python pack_bin.py <folder> --only run.exe app.exe -o exes.bin --partial

  Merge partials into a complete data.bin:
    python pack_bin.py --merge deps.bin exes.bin -o data.bin --exe run.exe

  List contents of a bin:
    python pack_bin.py --list data.bin
    python pack_bin.py --list deps.bin

Options:
    -l, --level N       Brotli compression level 0-11 (default: 11)
    -j, --jobs N        Thread count (default: CPU count)
    -o, --output PATH   Output path (default: data.bin next to script)
    --exe NAME          Executable name in footer (default: run.exe)
    --partial           Write raw entries only (no header/footer) for merging
    --exclude F [F...]  Skip these filenames
    --only F [F...]     Pack only these filenames
    --merge A [B...]    Merge partial bins into a complete data.bin
    --list BIN          List contents of a data.bin or partial bin
"""

import os
import sys
import argparse
import time
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from hashlib import md5

try:
    import brotli
except ImportError:
    print("Error: brotli not installed. Run: pip install brotli")
    sys.exit(1)

LENGTH_BYTES = 4
ENCODING = "utf-8"
IDENTIFIER = "EXEPACKER"  # 9 bytes — must match format.rs


def compress_file(full_path: str, folder: str, level: int):
    """Compress a single file. Returns (relative_path, compressed, digest, original_size)."""
    with open(os.path.join(folder, full_path), "rb") as f:
        content = f.read()
    compressed = brotli.compress(content, quality=level)
    digest = md5(content).hexdigest().encode(ENCODING)
    return full_path, compressed, digest, len(content)


def pack_folder(folder: str, level: int, workers: int,
                exclude: set = None, only: set = None) -> OrderedDict:
    """Walk folder, brotli-compress files in parallel, return ordered results."""
    file_paths = []
    saved = os.getcwd()
    os.chdir(folder)
    for root, _, files in os.walk("."):
        for fname in sorted(files):
            if exclude and fname in exclude:
                continue
            if only and fname not in only:
                continue
            file_paths.append(os.path.join(root, fname))
    os.chdir(saved)

    total = len(file_paths)
    if total == 0:
        print("  No files to pack.")
        return OrderedDict()

    print(f"  Found {total} files, compressing with {workers} threads...\n")

    results = {}
    start = time.time()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(compress_file, fp, folder, level): fp
            for fp in file_paths
        }
        done = 0
        for future in as_completed(futures):
            path, compressed, digest, orig_size = future.result()
            results[path] = (compressed, digest)
            done += 1
            ratio = len(compressed) / orig_size * 100 if orig_size else 0
            print(f"  [{done}/{total}] {path}  {orig_size:,} -> {len(compressed):,} ({ratio:.1f}%)")

    elapsed = time.time() - start
    print(f"\n  Compressed {total} files in {elapsed:.1f}s")

    ordered = OrderedDict()
    for fp in file_paths:
        ordered[fp] = results[fp]
    return ordered


def encode_entries(md5_table: OrderedDict) -> bytes:
    """Encode file entries into raw bytes (no header/footer)."""
    chunks = []
    for path, (compressed, digest) in md5_table.items():
        path_bytes = path.encode(ENCODING)
        chunks.append(len(path_bytes).to_bytes(length=LENGTH_BYTES, byteorder="big"))
        chunks.append(path_bytes)
        chunks.append(len(compressed).to_bytes(length=LENGTH_BYTES, byteorder="big"))
        chunks.append(compressed)
        chunks.append(digest)
    return b"".join(chunks)


def write_partial(md5_table: OrderedDict, output_path: str):
    """Write raw entry bytes only (no header/footer) for later merging."""
    data = encode_entries(md5_table)
    with open(output_path, "wb") as f:
        f.write(data)
    print(f"\nWrote partial {output_path} ({os.path.getsize(output_path):,} bytes)")


def write_full(md5_table: OrderedDict, output_path: str, exe: str):
    """Write a complete data.bin with header and footer."""
    with open(output_path, "wb") as f:
        f.write(IDENTIFIER.encode(ENCODING))
        f.write(encode_entries(md5_table))
        f.write(IDENTIFIER.encode(ENCODING))
        f.write(exe.encode(ENCODING))
    print(f"\nWrote {output_path} ({os.path.getsize(output_path):,} bytes)")


def merge_bins(partial_paths: list, output_path: str, exe: str):
    """Merge partial bins into a complete data.bin."""
    with open(output_path, "wb") as f:
        f.write(IDENTIFIER.encode(ENCODING))
        for p in partial_paths:
            if not os.path.isfile(p):
                print(f"Error: partial bin not found: {p}")
                sys.exit(1)
            with open(p, "rb") as pf:
                f.write(pf.read())
            print(f"  Merged {p} ({os.path.getsize(p):,} bytes)")
        f.write(IDENTIFIER.encode(ENCODING))
        f.write(exe.encode(ENCODING))
    print(f"\nWrote {output_path} ({os.path.getsize(output_path):,} bytes)")


def list_bin(bin_path: str):
    """List contents of a data.bin or partial bin."""
    with open(bin_path, "rb") as f:
        data = f.read()

    base = 0
    is_full = False

    # Check for header
    id_len = len(IDENTIFIER.encode(ENCODING))
    if len(data) >= id_len and data[:id_len].decode(ENCODING, errors="ignore") == IDENTIFIER:
        is_full = True
        base = id_len

    total_compressed = 0
    count = 0
    print(f"{'Type':<6} {'File':<50} {'Compressed':>12} {'MD5'}")
    print("-" * 105)

    while base + 4 < len(data):
        # Check for footer
        if is_full and base + id_len <= len(data):
            tag = data[base:base + id_len].decode(ENCODING, errors="ignore")
            if tag == IDENTIFIER:
                exe_name = data[base + id_len:].decode(ENCODING, errors="ignore")
                print("-" * 105)
                print(f"{'exe':<6} {exe_name}")
                break

        # Read path
        path_len = int.from_bytes(data[base:base + 4], "big")
        base += 4
        if base + path_len > len(data):
            break
        path = data[base:base + path_len].decode(ENCODING, errors="ignore")
        base += path_len

        # Read compressed data
        if base + 4 > len(data):
            break
        data_len = int.from_bytes(data[base:base + 4], "big")
        base += 4
        base += data_len  # skip compressed bytes

        # Read MD5
        if base + 32 > len(data):
            break
        md5_hex = data[base:base + 32].decode(ENCODING, errors="ignore")
        base += 32

        total_compressed += data_len
        count += 1

        def fmt_size(n):
            if n >= 1024 * 1024:
                return f"{n / 1024 / 1024:.1f} MB"
            elif n >= 1024:
                return f"{n / 1024:.1f} KB"
            return f"{n} B"

        print(f"{'file':<6} {path:<50} {fmt_size(data_len):>12} {md5_hex}")

    print()
    print(f"Files: {count}")
    print(f"Total compressed: {total_compressed / 1024 / 1024:.1f} MB")
    print(f"Bin size: {len(data) / 1024 / 1024:.1f} MB")
    kind = "full (header+footer)" if is_full else "partial (raw entries)"
    print(f"Format: {kind}")


def main():
    ap = argparse.ArgumentParser(description="Pack a folder into data.bin")
    ap.add_argument("folder", nargs="?", help="Folder to pack")
    ap.add_argument("-l", "--level", type=int, default=11,
                    help="Brotli compression level 0-11 (default: 11)")
    ap.add_argument("-o", "--output", default=None,
                    help="Output path (default: data.bin next to script)")
    ap.add_argument("--exe", default="run.exe",
                    help="Executable name in footer (default: run.exe)")
    ap.add_argument("-j", "--jobs", type=int, default=None,
                    help="Number of compression threads (default: CPU count)")
    ap.add_argument("--partial", action="store_true",
                    help="Write raw entries only (no header/footer) for merging")
    ap.add_argument("--exclude", nargs="+", default=None,
                    help="Filenames to exclude from packing")
    ap.add_argument("--only", nargs="+", default=None,
                    help="Pack only these filenames")
    ap.add_argument("--merge", nargs="+", default=None, metavar="BIN",
                    help="Merge partial bins into a complete data.bin")
    ap.add_argument("--list", dest="list_bin", default=None, metavar="BIN",
                    help="List contents of a data.bin or partial bin")
    args = ap.parse_args()

    output = args.output or os.path.join(os.path.dirname(os.path.abspath(__file__)), "data.bin")

    # List mode
    if args.list_bin:
        list_bin(args.list_bin)
        return

    # Merge mode
    if args.merge:
        print(f"Merging {len(args.merge)} partial bins -> {output}")
        merge_bins(args.merge, output, args.exe)
        return

    # Pack mode
    if not args.folder:
        print("Error: folder argument required (or use --merge)")
        sys.exit(1)

    folder = args.folder.rstrip("/\\")
    if not os.path.isdir(folder):
        print(f"Error: '{folder}' is not a directory")
        sys.exit(1)

    workers = args.jobs or os.cpu_count() or 4
    exclude = set(args.exclude) if args.exclude else None
    only = set(args.only) if args.only else None

    mode = "partial" if args.partial else "full"
    print(f"Source  : {os.path.abspath(folder)}")
    print(f"Output  : {output}")
    print(f"Level   : {args.level}")
    print(f"Threads : {workers}")
    print(f"Mode    : {mode}")
    if exclude:
        print(f"Exclude : {', '.join(sorted(exclude))}")
    if only:
        print(f"Only    : {', '.join(sorted(only))}")
    print()

    table = pack_folder(folder, args.level, workers, exclude, only)

    if args.partial:
        write_partial(table, output)
    else:
        write_full(table, output, args.exe)
    print(f"Files   : {len(table)}")


if __name__ == "__main__":
    main()
