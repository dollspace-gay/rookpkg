#!/usr/bin/env python3
"""
Fix missing dependencies in .rook files based on check_deps.py report.
Reads the dependency report and updates each .rook file with missing dependencies.
"""

import re
import sys
import tomllib
from pathlib import Path
from dataclasses import dataclass, field


@dataclass
class PackageIssues:
    """Issues found for a package."""
    name: str
    missing_depends: list[str] = field(default_factory=list)
    missing_build_depends: list[str] = field(default_factory=list)
    missing_optional: list[str] = field(default_factory=list)


def parse_report(report_path: Path) -> list[PackageIssues]:
    """Parse the dependency report file."""
    packages = []
    current_pkg = None
    current_section = None

    with open(report_path, "r") as f:
        for line in f:
            line = line.rstrip()

            # New package section
            if line.startswith("Package: "):
                if current_pkg:
                    packages.append(current_pkg)
                pkg_name = line[9:].strip()
                current_pkg = PackageIssues(name=pkg_name)
                current_section = None

            # Section headers
            elif "Missing runtime dependencies:" in line:
                current_section = "depends"
            elif "Missing build dependencies:" in line:
                current_section = "build_depends"
            elif "Missing optional dependencies:" in line:
                current_section = "optional"

            # Dependency entries
            elif line.strip().startswith("- ") and current_pkg and current_section:
                dep = line.strip()[2:].strip()
                if current_section == "depends":
                    current_pkg.missing_depends.append(dep)
                elif current_section == "build_depends":
                    current_pkg.missing_build_depends.append(dep)
                elif current_section == "optional":
                    current_pkg.missing_optional.append(dep)

            # Section separator
            elif line.startswith("===="):
                current_section = None

    # Don't forget last package
    if current_pkg:
        packages.append(current_pkg)

    return packages


def read_rook_file(path: Path) -> str:
    """Read a .rook file and return its contents."""
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def find_section_end(content: str, section_name: str) -> tuple[int, int, str]:
    """
    Find the end position of a TOML section and return (start, end, existing_content).
    Returns positions where we can insert new entries.
    """
    # Pattern to match section header
    section_pattern = rf'^\[{re.escape(section_name)}\]\s*$'

    lines = content.split('\n')
    section_start = -1
    section_end = -1

    for i, line in enumerate(lines):
        if re.match(section_pattern, line.strip()):
            section_start = i
        elif section_start >= 0 and line.strip().startswith('[') and not line.strip().startswith('[['):
            # Found next section
            section_end = i
            break

    if section_start >= 0 and section_end < 0:
        # Section goes to end of file
        section_end = len(lines)

    if section_start >= 0:
        # Get existing content in section (skip header)
        section_content = '\n'.join(lines[section_start+1:section_end])
        return section_start, section_end, section_content.strip()

    return -1, -1, ""


def get_existing_deps(content: str, section_name: str) -> set[str]:
    """Get existing dependencies from a section."""
    _, _, section_content = find_section_end(content, section_name)

    existing = set()
    for line in section_content.split('\n'):
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            # Extract package name (before the =)
            pkg_name = line.split('=')[0].strip().strip('"')
            existing.add(pkg_name)

    return existing


def add_deps_to_section(content: str, section_name: str, deps: list[str]) -> str:
    """Add dependencies to a section in the .rook file."""
    if not deps:
        return content

    existing = get_existing_deps(content, section_name)

    # Filter out deps that already exist
    new_deps = [d for d in deps if d not in existing]
    if not new_deps:
        return content

    lines = content.split('\n')
    section_start, section_end, section_content = find_section_end(content, section_name)

    if section_start < 0:
        # Section doesn't exist - this shouldn't happen for standard .rook files
        print(f"    Warning: Section [{section_name}] not found")
        return content

    # Common minimum versions for well-known packages
    known_versions = {
        "glibc": "2.39",
        "gcc": "10.0",
        "systemd": "255",
        "glib2": "2.78",
        "gtk3": "3.24",
        "gtk4": "4.12",
        "qt6": "6.6",
        "python": "3.12",
        "perl": "5.38",
        "ncurses": "6.4",
        "readline": "8.2",
        "openssl": "3.0",
        "curl": "8.0",
        "libxml2": "2.12",
        "libxslt": "1.1",
        "zlib": "1.3",
        "bzip2": "1.0",
        "xz": "5.4",
        "zstd": "1.5",
        "dbus": "1.14",
        "polkit": "124",
        "wayland": "1.22",
        "mesa": "24.0",
        "libdrm": "2.4",
        "freetype": "2.13",
        "fontconfig": "2.14",
        "harfbuzz": "8.0",
        "cairo": "1.18",
        "pango": "1.52",
        "libpng": "1.6",
        "libjpeg-turbo": "3.0",
        "sqlite": "3.45",
        "libffi": "3.4",
        "expat": "2.6",
        "pcre2": "10.42",
        "icu": "74",
        "libx11": "1.8",
        "libxcb": "1.16",
        "libxi": "1.8",
        "libxext": "1.3",
        "libxfixes": "6.0",
        "libxrandr": "1.5",
        "libxtst": "1.2",
        "libxkbcommon": "1.6",
        "alsa-lib": "1.2",
        "pulseaudio": "17.0",
        "pipewire": "1.0",
        "ffmpeg": "7.0",
        "gstreamer": "1.24",
        "libcap": "2.69",
        "libsecret": "0.21",
        "libgcrypt": "1.10",
        "libgpg-error": "1.48",
        "json-c": "0.17",
        "libevent": "2.1",
        "libusb": "1.0",
        "libarchive": "3.7",
        "attr": "2.5",
        "acl": "2.3",
        "libinput": "1.25",
        "libevdev": "1.13",
        "bluez": "5.72",
        "cups": "2.4",
        "samba": "4.20",
        "gettext": "0.22",
        "vala": "0.56",
        "libsamplerate": "0.2",
        "fftw": "3.3",
        "pciutils": "3.10",
        "librsvg": "2.58",
        "gdk-pixbuf2": "2.42",
        "gsettings-desktop-schemas": "46.0",
    }

    # Build new dependency lines
    new_lines = []
    for dep in sorted(new_deps):
        version = known_versions.get(dep, "1.0")
        new_lines.append(f'{dep} = ">= {version}"')

    # Find insertion point (after existing deps, before empty lines at end of section)
    insert_at = section_start + 1

    # Skip past existing content
    for i in range(section_start + 1, section_end):
        line = lines[i].strip()
        if line and not line.startswith('#'):
            insert_at = i + 1

    # Insert new dependencies
    for new_line in new_lines:
        lines.insert(insert_at, new_line)
        insert_at += 1

    return '\n'.join(lines)


def fix_rook_file(specs_dir: Path, pkg: PackageIssues, dry_run: bool = False) -> bool:
    """Fix a single .rook file with missing dependencies."""
    # Find the .rook file
    rook_path = specs_dir / f"{pkg.name}.rook"

    if not rook_path.exists():
        # Try with kf6- prefix stripped
        if pkg.name.startswith("kf6-"):
            alt_name = pkg.name[4:]
            rook_path = specs_dir / f"{alt_name}.rook"

    if not rook_path.exists():
        print(f"  Skipping {pkg.name}: .rook file not found")
        return False

    print(f"  Fixing {rook_path.name}...")

    content = read_rook_file(rook_path)
    original_content = content

    # Map common lib names to their package names for filtering
    lib_to_pkg = {
        "libasound": "alsa-lib",
        "libncursesw": "ncurses",
        "libncurses": "ncurses",
        "libreadline": "readline",
        "libsystemd": "systemd",
        "libudev": "systemd",
        "libxml2": "libxml2",
        "libxslt": "libxslt",
        "libglib-2.0": "glib2",
        "libgio-2.0": "glib2",
        "libgobject-2.0": "glib2",
        "libpng": "libpng",
        "libpng16": "libpng",
        "libjpeg": "libjpeg-turbo",
        "libfreetype": "freetype",
        "libfontconfig": "fontconfig",
        "libharfbuzz": "harfbuzz",
        "libcairo": "cairo",
        "libpango-1.0": "pango",
        "libgtk-3": "gtk3",
        "libgtk-4": "gtk4",
        "libdbus-1": "dbus",
        "libcurl": "curl",
        "libssl": "openssl",
        "libcrypto": "openssl",
        "libz": "zlib",
        "libbz2": "bzip2",
        "liblzma": "xz",
        "libzstd": "zstd",
        "libffi": "libffi",
        "libexpat": "expat",
        "libpcre2-8": "pcre2",
        "libsqlite3": "sqlite",
        "libX11": "libx11",
        "libxcb": "libxcb",
        "libwayland-client": "wayland",
        "libpulse": "pulseaudio",
        "libpipewire-0.3": "pipewire",
    }

    # Get existing deps to avoid duplicates with different names
    existing_depends = get_existing_deps(content, "depends")
    existing_build = get_existing_deps(content, "build_depends")
    existing_optional = get_existing_deps(content, "optional_depends")
    all_existing = existing_depends | existing_build | existing_optional

    def filter_deps(deps: list[str], pkg_name: str) -> list[str]:
        """Filter out self-deps and deps that map to existing packages."""
        filtered = []
        for d in deps:
            # Skip self-references
            if d == pkg_name:
                continue
            # Skip if it's a lib name that maps to an existing package
            if d in lib_to_pkg and lib_to_pkg[d] in all_existing:
                continue
            # Skip if it directly exists
            if d in all_existing:
                continue
            filtered.append(d)
        return filtered

    pkg.missing_depends = filter_deps(pkg.missing_depends, pkg.name)
    pkg.missing_build_depends = filter_deps(pkg.missing_build_depends, pkg.name)
    pkg.missing_optional = filter_deps(pkg.missing_optional, pkg.name)

    # Add missing runtime dependencies
    if pkg.missing_depends:
        print(f"    Adding {len(pkg.missing_depends)} runtime deps: {', '.join(pkg.missing_depends[:5])}{'...' if len(pkg.missing_depends) > 5 else ''}")
        content = add_deps_to_section(content, "depends", pkg.missing_depends)

    # Add missing build dependencies
    if pkg.missing_build_depends:
        print(f"    Adding {len(pkg.missing_build_depends)} build deps: {', '.join(pkg.missing_build_depends[:5])}{'...' if len(pkg.missing_build_depends) > 5 else ''}")
        content = add_deps_to_section(content, "build_depends", pkg.missing_build_depends)

    # Add missing optional dependencies
    if pkg.missing_optional:
        print(f"    Adding {len(pkg.missing_optional)} optional deps: {', '.join(pkg.missing_optional[:5])}{'...' if len(pkg.missing_optional) > 5 else ''}")
        content = add_deps_to_section(content, "optional_depends", pkg.missing_optional)

    if content == original_content:
        print(f"    No changes needed")
        return False

    if dry_run:
        print(f"    [DRY RUN] Would update {rook_path.name}")
        return True

    # Write updated content
    with open(rook_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"    Updated {rook_path.name}")
    return True


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Fix missing dependencies in .rook files")
    parser.add_argument("--report", "-r", default="deps_report_final.txt",
                        help="Path to dependency report file")
    parser.add_argument("--specs-dir", "-s", default="specs",
                        help="Directory containing .rook files")
    parser.add_argument("--package", "-p", help="Fix specific package only")
    parser.add_argument("--dry-run", "-n", action="store_true",
                        help="Show what would be changed without modifying files")
    parser.add_argument("--skip-optional", action="store_true",
                        help="Skip adding optional dependencies")
    parser.add_argument("--skip-build", action="store_true",
                        help="Skip adding build dependencies")
    parser.add_argument("--limit", "-l", type=int,
                        help="Limit number of packages to fix")
    args = parser.parse_args()

    report_path = Path(args.report)
    specs_dir = Path(args.specs_dir)

    if not report_path.exists():
        print(f"Error: Report file not found: {report_path}")
        print("Run check_deps.py first to generate the report.")
        sys.exit(1)

    if not specs_dir.exists():
        print(f"Error: Specs directory not found: {specs_dir}")
        sys.exit(1)

    print(f"Reading report from {report_path}...")
    packages = parse_report(report_path)
    print(f"Found {len(packages)} packages with issues")

    # Filter by package name if specified
    if args.package:
        packages = [p for p in packages if p.name == args.package]
        if not packages:
            print(f"Package '{args.package}' not found in report")
            sys.exit(1)

    # Apply limit
    if args.limit:
        packages = packages[:args.limit]

    # Remove optional/build deps if requested
    if args.skip_optional:
        for pkg in packages:
            pkg.missing_optional = []

    if args.skip_build:
        for pkg in packages:
            pkg.missing_build_depends = []

    fixed_count = 0
    for pkg in packages:
        if fix_rook_file(specs_dir, pkg, dry_run=args.dry_run):
            fixed_count += 1

    print(f"\n{'='*60}")
    print(f"Summary:")
    print(f"  Packages processed: {len(packages)}")
    print(f"  Files {'that would be ' if args.dry_run else ''}modified: {fixed_count}")

    if args.dry_run:
        print("\nRun without --dry-run to apply changes.")


if __name__ == "__main__":
    main()
