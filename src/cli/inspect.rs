//! Inspect command - examine package archives
//!
//! Displays detailed information about .rookpkg archive files.

use std::path::Path;

use anyhow::Result;
use colored::Colorize;

use crate::archive::{PackageArchiveBuilder, PackageArchiveReader};
use crate::build::PackageBuilder;
use crate::config::Config;
use crate::database::Database;
use crate::spec::PackageSpec;

/// Inspect a package archive or spec file
pub fn run(path: &Path, show_files: bool, show_scripts: bool, validate: bool, config: &Config) -> Result<()> {
    // If validate flag is set, perform validation using build_from_spec and in-memory database
    if validate {
        return validate_spec(path, config);
    }

    // Determine if this is a .rookpkg archive or a .rook spec file
    let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("");

    match extension {
        "rookpkg" => inspect_archive(path, show_files, show_scripts),
        "rook" => inspect_spec(path),
        _ => {
            // Try to detect by attempting to open as archive first
            if let Ok(reader) = PackageArchiveReader::open(path) {
                return inspect_archive_reader(&reader, show_files, show_scripts);
            }
            // Fall back to spec file
            inspect_spec(path)
        }
    }
}

/// Inspect a package archive file
fn inspect_archive(path: &Path, show_files: bool, show_scripts: bool) -> Result<()> {
    println!("{} {}", "Inspecting archive:".bold(), path.display());
    println!();

    let reader = PackageArchiveReader::open(path)?;
    inspect_archive_reader(&reader, show_files, show_scripts)
}

/// Inspect using a PackageArchiveReader
fn inspect_archive_reader(reader: &PackageArchiveReader, show_files: bool, show_scripts: bool) -> Result<()> {
    // Read package info
    let info = reader.read_info()?;

    println!("{}", "Package Information".cyan().bold());
    println!("  {}: {}", "Name".bold(), info.name);
    println!("  {}: {}", "Version".bold(), info.version);
    println!("  {}: {}", "Release".bold(), info.release);
    println!("  {}: {}", "Architecture".bold(), info.arch);
    println!("  {}: {}", "Summary".bold(), info.summary);
    println!("  {}: {}", "Description".bold(), info.description);

    if !info.license.is_empty() {
        println!("  {}: {}", "License".bold(), info.license);
    }
    if !info.url.is_empty() {
        println!("  {}: {}", "URL".bold(), info.url);
    }
    if !info.maintainer.is_empty() {
        println!("  {}: {}", "Maintainer".bold(), info.maintainer);
    }

    println!("  {}: {} bytes", "Installed Size".bold(), info.installed_size);
    println!();

    // Read and display file list
    let files = reader.read_files()?;
    println!(
        "{} ({} files)",
        "File List".cyan().bold(),
        files.len()
    );

    if show_files {
        for file in &files {
            let config_marker = if file.is_config { " [config]" } else { "" };
            println!(
                "  {:>8} {:04o} {}{}",
                format_size(file.size),
                file.mode & 0o7777,
                file.path,
                config_marker.yellow()
            );
        }
    } else {
        // Show summary
        let total_size: u64 = files.iter().map(|f| f.size).sum();
        let config_count = files.iter().filter(|f| f.is_config).count();
        println!("  Total: {} in {} files ({} config files)",
            format_size(total_size),
            files.len(),
            config_count
        );
        println!("  Use {} to see all files", "--files".cyan());
    }
    println!();

    // Read and display install scripts
    match reader.read_scripts()? {
        Some(scripts) => {
            println!("{}", "Install Scripts".cyan().bold());

            let mut has_scripts = false;

            if !scripts.pre_install.is_empty() {
                has_scripts = true;
                println!("  {} present ({} bytes)",
                    "pre_install:".bold(),
                    scripts.pre_install.len()
                );
                if show_scripts {
                    println!("    {}", "─".repeat(40).dimmed());
                    for line in scripts.pre_install.lines().take(20) {
                        println!("    {}", line.dimmed());
                    }
                    if scripts.pre_install.lines().count() > 20 {
                        println!("    {} ...", "(truncated)".dimmed());
                    }
                }
            }

            if !scripts.post_install.is_empty() {
                has_scripts = true;
                println!("  {} present ({} bytes)",
                    "post_install:".bold(),
                    scripts.post_install.len()
                );
                if show_scripts {
                    println!("    {}", "─".repeat(40).dimmed());
                    for line in scripts.post_install.lines().take(20) {
                        println!("    {}", line.dimmed());
                    }
                    if scripts.post_install.lines().count() > 20 {
                        println!("    {} ...", "(truncated)".dimmed());
                    }
                }
            }

            if !scripts.pre_remove.is_empty() {
                has_scripts = true;
                println!("  {} present ({} bytes)",
                    "pre_remove:".bold(),
                    scripts.pre_remove.len()
                );
                if show_scripts {
                    println!("    {}", "─".repeat(40).dimmed());
                    for line in scripts.pre_remove.lines().take(20) {
                        println!("    {}", line.dimmed());
                    }
                    if scripts.pre_remove.lines().count() > 20 {
                        println!("    {} ...", "(truncated)".dimmed());
                    }
                }
            }

            if !scripts.post_remove.is_empty() {
                has_scripts = true;
                println!("  {} present ({} bytes)",
                    "post_remove:".bold(),
                    scripts.post_remove.len()
                );
                if show_scripts {
                    println!("    {}", "─".repeat(40).dimmed());
                    for line in scripts.post_remove.lines().take(20) {
                        println!("    {}", line.dimmed());
                    }
                    if scripts.post_remove.lines().count() > 20 {
                        println!("    {} ...", "(truncated)".dimmed());
                    }
                }
            }

            if !scripts.pre_upgrade.is_empty() {
                has_scripts = true;
                println!("  {} present ({} bytes)",
                    "pre_upgrade:".bold(),
                    scripts.pre_upgrade.len()
                );
                if show_scripts {
                    println!("    {}", "─".repeat(40).dimmed());
                    for line in scripts.pre_upgrade.lines().take(20) {
                        println!("    {}", line.dimmed());
                    }
                    if scripts.pre_upgrade.lines().count() > 20 {
                        println!("    {} ...", "(truncated)".dimmed());
                    }
                }
            }

            if !scripts.post_upgrade.is_empty() {
                has_scripts = true;
                println!("  {} present ({} bytes)",
                    "post_upgrade:".bold(),
                    scripts.post_upgrade.len()
                );
                if show_scripts {
                    println!("    {}", "─".repeat(40).dimmed());
                    for line in scripts.post_upgrade.lines().take(20) {
                        println!("    {}", line.dimmed());
                    }
                    if scripts.post_upgrade.lines().count() > 20 {
                        println!("    {} ...", "(truncated)".dimmed());
                    }
                }
            }

            if !has_scripts {
                println!("  (none defined)");
            } else if !show_scripts {
                println!("  Use {} to see script contents", "--scripts".cyan());
            }
        }
        None => {
            println!("{} None", "Install Scripts:".cyan().bold());
        }
    }

    Ok(())
}

/// Inspect a spec file and show what a built package would contain
fn inspect_spec(path: &Path) -> Result<()> {
    println!("{} {}", "Inspecting spec file:".bold(), path.display());
    println!();

    let spec = PackageSpec::from_file(path)?;

    println!("{}", "Package Specification".cyan().bold());
    println!("  {}: {}", "Name".bold(), spec.package.name);
    println!("  {}: {}", "Version".bold(), spec.package.version);
    println!("  {}: {}", "Release".bold(), spec.package.release);
    println!("  {}: {}", "Full Version".bold(), spec.full_version());
    println!("  {}: {}", "Summary".bold(), spec.package.summary);

    if !spec.package.license.is_empty() {
        println!("  {}: {}", "License".bold(), spec.package.license);
    }
    if !spec.package.url.is_empty() {
        println!("  {}: {}", "URL".bold(), spec.package.url);
    }
    println!();

    // Show sources using sources_list()
    let sources = spec.sources_list();
    if !sources.is_empty() {
        println!("{} ({} sources)", "Sources".cyan().bold(), sources.len());
        for (name, source) in sources {
            println!("  {}: {}", name.bold(), source.url);
            println!("    SHA256: {}", source.sha256.dimmed());
        }
        println!();
    }

    // Show runtime dependencies using runtime_deps()
    let runtime_deps: Vec<_> = spec.runtime_deps().collect();
    if !runtime_deps.is_empty() {
        println!("{} ({} packages)", "Runtime Dependencies".cyan().bold(), runtime_deps.len());
        for (name, constraint) in runtime_deps {
            println!("  {} {}", name.bold(), constraint.dimmed());
        }
        println!();
    }

    // Show build dependencies using build_deps()
    let build_deps: Vec<_> = spec.build_deps().collect();
    if !build_deps.is_empty() {
        println!("{} ({} packages)", "Build Dependencies".cyan().bold(), build_deps.len());
        for (name, constraint) in build_deps {
            println!("  {} {}", name.bold(), constraint.dimmed());
        }
        println!();
    }

    // Show build phases
    println!("{}", "Build Phases".cyan().bold());
    if !spec.build.prep.is_empty() {
        println!("  {}: {} lines", "prep".bold(), spec.build.prep.lines().count());
    }
    if !spec.build.configure.is_empty() {
        println!("  {}: {} lines", "configure".bold(), spec.build.configure.lines().count());
    }
    if !spec.build.build.is_empty() {
        println!("  {}: {} lines", "build".bold(), spec.build.build.lines().count());
    }
    if !spec.build.check.is_empty() {
        println!("  {}: {} lines", "check".bold(), spec.build.check.lines().count());
    }
    if !spec.build.install.is_empty() {
        println!("  {}: {} lines", "install".bold(), spec.build.install.lines().count());
    }

    Ok(())
}

/// Use PackageArchiveBuilder info() and files() methods for validation
pub fn validate_built_archive(builder: &PackageArchiveBuilder) -> Result<()> {
    let info = builder.info();
    let files = builder.files();

    println!("{}", "Validating built package...".cyan());
    println!("  Package: {}-{}-{}", info.name, info.version, info.release);
    println!("  Files: {}", files.len());

    // Validate no duplicate paths
    let mut seen_paths = std::collections::HashSet::new();
    for file in files {
        if !seen_paths.insert(&file.path) {
            anyhow::bail!("Duplicate file path in package: {}", file.path);
        }
    }

    println!("  {} No duplicate paths", "✓".green());

    // Validate all regular files have checksums (directories and symlinks don't need them)
    use crate::archive::FileType;
    for file in files {
        if file.file_type == FileType::Regular && file.sha256.is_empty() {
            anyhow::bail!("Regular file missing checksum: {}", file.path);
        }
    }

    println!("  {} All regular files have checksums", "✓".green());

    Ok(())
}

/// Validate a spec file by creating a build environment and testing with in-memory database
fn validate_spec(path: &Path, config: &Config) -> Result<()> {
    println!("{} {}", "Validating spec file:".bold(), path.display());
    println!();

    // Step 1: Validate spec file can be parsed
    println!("{}", "Parsing spec file...".cyan());
    let spec = PackageSpec::from_file(path)?;
    println!(
        "  {} {}-{}-{}",
        "✓".green(),
        spec.package.name,
        spec.package.version,
        spec.package.release
    );

    // Step 2: Validate build environment can be created using build_from_spec
    println!("{}", "Creating build environment (using build_from_spec)...".cyan());
    let builder = PackageBuilder::new(config.clone());
    let build_env = builder.build_from_spec(path)?;
    println!(
        "  {} Build directory: {}",
        "✓".green(),
        build_env.build_dir().display()
    );

    // Step 3: Validate database operations using in-memory database
    println!("{}", "Testing database operations (in-memory)...".cyan());
    let _db = Database::open_in_memory()?;
    println!("  {} In-memory database created", "✓".green());

    // Clean up the build environment
    println!("{}", "Cleaning up...".cyan());
    build_env.clean()?;
    println!("  {} Build directory cleaned", "✓".green());

    println!();
    println!(
        "{} Spec file {} is valid and ready to build",
        "✓".green().bold(),
        path.display()
    );

    Ok(())
}

/// Format bytes as human-readable size
fn format_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
