#!/usr/bin/env python3
"""
Update KDE Plasma package versions from 6.2.4 to 6.4.4 as per BLFS 12.4.
Also updates source URLs to reflect the new version.
"""

import re
import sys
from pathlib import Path

OLD_VERSION = "6.2.4"
NEW_VERSION = "6.4.4"

# KDE Plasma packages that should be updated to 6.4.4
PLASMA_PACKAGES = {
    "bluedevil",
    "breeze",
    "breeze-gtk",
    "drkonqi",
    "kactivitymanagerd",
    "kde-cli-tools",
    "kdecoration",
    "kde-gtk-config",
    "kdeplasma-addons",
    "kgamma",
    "kglobalacceld",
    "kinfocenter",
    "kmenuedit",
    "kpipewire",
    "kscreen",
    "kscreenlocker",
    "ksshaskpass",
    "ksystemstats",
    "kwallet-pam",
    "kwayland",
    "kwin",
    "kwrited",
    "layer-shell-qt",
    "libkscreen",
    "libksysguard",
    "libplasma",
    "milou",
    "ocean-sound-theme",
    "oxygen",
    "oxygen-sounds",
    "plasma5support",
    "plasma-activities",
    "plasma-activities-stats",
    "plasma-desktop",
    "plasma-disks",
    "plasma-firewall",
    "plasma-integration",
    "plasma-nm",
    "plasma-pa",
    "plasma-systemmonitor",
    "plasma-thunderbolt",
    "plasma-vault",
    "plasma-welcome",
    "plasma-workspace",
    "plasma-workspace-wallpapers",
    "polkit-kde-agent",
    "powerdevil",
    "print-manager",
    "qqc2-breeze-style",
    "sddm-kcm",
    "spectacle",
    "systemsettings",
    "wacomtablet",
    "xdg-desktop-portal-kde",
}


def update_rook_file(path: Path, dry_run: bool = False) -> bool:
    """Update version and source URLs in a .rook file."""
    pkg_name = path.stem
    if pkg_name not in PLASMA_PACKAGES:
        return False

    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    original_content = content

    # Check if this package has the old version
    if f'version = "{OLD_VERSION}"' not in content:
        return False

    # Update version in [package] section (first occurrence)
    content = content.replace(f'version = "{OLD_VERSION}"', f'version = "{NEW_VERSION}"', 1)

    # Update version in source URLs
    content = content.replace(f"{pkg_name}-{OLD_VERSION}", f"{pkg_name}-{NEW_VERSION}")

    # Update version in [[changelog]] section
    # Find the changelog section and update the version there too
    changelog_pattern = rf'(\[\[changelog\]\]\s*\n\s*version = "){OLD_VERSION}(")'
    content = re.sub(changelog_pattern, rf'\g<1>{NEW_VERSION}\2', content)

    if content == original_content:
        return False

    if dry_run:
        print(f"  Would update {path.name}: {OLD_VERSION} -> {NEW_VERSION}")
        return True

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    return True


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Update KDE Plasma package versions")
    parser.add_argument("--specs-dir", "-s", default="specs",
                        help="Directory containing .rook files")
    parser.add_argument("--package", "-p", help="Update specific package only")
    parser.add_argument("--dry-run", "-n", action="store_true",
                        help="Show what would be changed without modifying files")
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

    print(f"Updating KDE Plasma packages from {OLD_VERSION} to {NEW_VERSION}")
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
    print(f"  Plasma packages found: {len(PLASMA_PACKAGES)}")
    print(f"  Files {'that would be ' if args.dry_run else ''}modified: {updated_count}")

    if args.dry_run:
        print("\nRun without --dry-run to apply changes.")


if __name__ == "__main__":
    main()
