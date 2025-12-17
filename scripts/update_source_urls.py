#!/usr/bin/env python3
"""
Update source URLs in .rook files to use the RookerySource mirror.
Changes all source URLs to http://corvidae.social/RookerySource/<filename>
Also resets sha256 hashes to "FIXME".
"""

import re
import sys
from pathlib import Path


MIRROR_BASE = "http://corvidae.social/RookerySource"


def extract_filename_from_url(url: str) -> str:
    """Extract the filename from a URL."""
    # Remove any query parameters
    url = url.split('?')[0]
    # Get the last path component
    return url.rstrip('/').split('/')[-1]


def update_rook_file(path: Path, dry_run: bool = False, reset_sha256: bool = True) -> bool:
    """Update source URLs in a .rook file to use the RookerySource mirror."""
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    original_content = content

    # Pattern to match source entries with URLs
    # Matches: source0 = { url = "https://...", sha256 = "..." }
    # Also handles multiline and various formats
    pattern = r'(source\d+\s*=\s*\{\s*url\s*=\s*")([^"]+)(")'

    def replace_url(match):
        prefix = match.group(1)
        old_url = match.group(2)
        suffix = match.group(3)

        # Skip if already using RookerySource
        if "corvidae.social/RookerySource" in old_url:
            return match.group(0)

        # Extract filename and create new URL
        filename = extract_filename_from_url(old_url)
        new_url = f"{MIRROR_BASE}/{filename}"

        return f"{prefix}{new_url}{suffix}"

    content = re.sub(pattern, replace_url, content)

    # Reset sha256 hashes to FIXME
    if reset_sha256:
        # Pattern to match sha256 values (but not ones already set to FIXME)
        sha256_pattern = r'(sha256\s*=\s*")[^"]+(")'
        content = re.sub(sha256_pattern, r'\1FIXME\2', content)

    if content == original_content:
        return False

    if dry_run:
        # Show what would change
        old_urls = re.findall(r'url\s*=\s*"([^"]+)"', original_content)
        new_urls = re.findall(r'url\s*=\s*"([^"]+)"', content)
        for old, new in zip(old_urls, new_urls):
            if old != new:
                print(f"    URL: {extract_filename_from_url(old)}")
        # Check sha256 changes
        old_hashes = re.findall(r'sha256\s*=\s*"([^"]+)"', original_content)
        new_hashes = re.findall(r'sha256\s*=\s*"([^"]+)"', content)
        for old_h, new_h in zip(old_hashes, new_hashes):
            if old_h != new_h:
                print(f"    sha256: {old_h[:20]}... -> FIXME")
        return True

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    return True


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Update source URLs to use RookerySource mirror")
    parser.add_argument("--specs-dir", "-s", default="specs",
                        help="Directory containing .rook files")
    parser.add_argument("--package", "-p", help="Update specific package only")
    parser.add_argument("--dry-run", "-n", action="store_true",
                        help="Show what would be changed without modifying files")
    parser.add_argument("--limit", "-l", type=int,
                        help="Limit number of packages to update")
    args = parser.parse_args()

    specs_dir = Path(args.specs_dir)

    if not specs_dir.exists():
        print(f"Error: Specs directory not found: {specs_dir}")
        sys.exit(1)

    # Get list of .rook files
    if args.package:
        rook_files = list(specs_dir.glob(f"{args.package}.rook"))
        if not rook_files:
            print(f"Package '{args.package}' not found")
            sys.exit(1)
    else:
        rook_files = sorted(specs_dir.glob("*.rook"))

    if args.limit:
        rook_files = rook_files[:args.limit]

    print(f"Updating source URLs to use {MIRROR_BASE}/")
    print(f"{'='*60}")

    updated_count = 0
    for rook_file in rook_files:
        result = update_rook_file(rook_file, dry_run=args.dry_run)
        if result:
            updated_count += 1
            action = "[DRY RUN] Would update" if args.dry_run else "Updated"
            print(f"  {action} {rook_file.name}")

    print(f"\n{'='*60}")
    print(f"Summary:")
    print(f"  Files processed: {len(rook_files)}")
    print(f"  Files {'that would be ' if args.dry_run else ''}modified: {updated_count}")

    if args.dry_run:
        print("\nRun without --dry-run to apply changes.")


if __name__ == "__main__":
    main()
