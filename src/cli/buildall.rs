//! Buildall command implementation - build all .rook specs in a directory

use std::path::Path;
use std::time::Instant;

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::signing;

/// Result of building a single package
struct BuildResult {
    name: String,
    version: String,
    success: bool,
    duration_secs: f64,
    error: Option<String>,
    package_path: Option<std::path::PathBuf>,
}

pub fn run(
    spec_dir: &Path,
    output: Option<&Path>,
    continue_on_error: bool,
    jobs: Option<usize>,
    config: &Config,
) -> Result<()> {
    let start_time = Instant::now();

    // Validate spec directory
    if !spec_dir.exists() {
        bail!("Spec directory not found: {}", spec_dir.display());
    }
    if !spec_dir.is_dir() {
        bail!("Path is not a directory: {}", spec_dir.display());
    }

    // CRITICAL: Check for signing key FIRST
    println!("{}", "Checking signing key...".cyan());

    let signing_key = match signing::load_signing_key(config) {
        Ok(key) => {
            println!(
                "  {} Signing key: {} <{}>",
                "✓".green(),
                key.name.cyan(),
                key.email.dimmed()
            );
            println!(
                "    Fingerprint: {}",
                signing::get_fingerprint(&key).dimmed()
            );
            key
        }
        Err(e) => {
            eprintln!();
            eprintln!("{}", "FATAL: No signing key found!".red().bold());
            eprintln!();
            eprintln!("Package building requires a cryptographic signing key.");
            eprintln!("This ensures package authenticity and prevents tampering.");
            eprintln!();
            eprintln!("To create a signing key:");
            eprintln!(
                "  {} --name \"Your Name\" --email \"you@example.org\"",
                "rookpkg keygen".cyan()
            );
            eprintln!();
            bail!("Signing key required: {}", e);
        }
    };

    // Find all .rook files in the directory
    println!();
    println!(
        "{} {}",
        "Scanning for spec files in:".cyan(),
        spec_dir.display()
    );

    let mut spec_files: Vec<_> = std::fs::read_dir(spec_dir)?
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            entry.path().extension().map_or(false, |ext| ext == "rook")
        })
        .map(|entry| entry.path())
        .collect();

    if spec_files.is_empty() {
        bail!("No .rook spec files found in {}", spec_dir.display());
    }

    // Sort alphabetically for consistent ordering
    spec_files.sort();

    println!(
        "  {} Found {} spec files",
        "✓".green(),
        spec_files.len()
    );

    // Determine output directory
    let output_dir = output.unwrap_or(Path::new("."));
    if !output_dir.exists() {
        std::fs::create_dir_all(output_dir)?;
    }
    println!(
        "  {} Output directory: {}",
        "→".cyan(),
        output_dir.display()
    );

    // Show parallel jobs if specified
    if let Some(j) = jobs {
        println!("  {} Parallel builds: {}", "→".cyan(), j);
    }

    println!();
    println!(
        "{}",
        format!("Building {} packages...", spec_files.len()).cyan().bold()
    );
    println!();

    // Track results
    let mut results: Vec<BuildResult> = Vec::new();
    let mut success_count = 0;
    let mut fail_count = 0;

    // Build each package
    for (index, spec_path) in spec_files.iter().enumerate() {
        let pkg_start = Instant::now();

        // Parse spec to get name/version for display
        let spec_name = spec_path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "unknown".to_string());

        println!(
            "[{}/{}] {} {}",
            index + 1,
            spec_files.len(),
            "Building".cyan(),
            spec_name.bold()
        );

        // Build the package
        let result = build_single_package(
            spec_path,
            output_dir,
            &signing_key,
            config,
        );

        let duration = pkg_start.elapsed().as_secs_f64();

        match result {
            Ok((name, version, package_path)) => {
                success_count += 1;
                println!(
                    "  {} {}-{} built in {:.1}s",
                    "✓".green(),
                    name,
                    version,
                    duration
                );
                results.push(BuildResult {
                    name,
                    version,
                    success: true,
                    duration_secs: duration,
                    error: None,
                    package_path: Some(package_path),
                });
            }
            Err(e) => {
                fail_count += 1;
                println!(
                    "  {} {} failed: {}",
                    "✗".red(),
                    spec_name,
                    e
                );
                results.push(BuildResult {
                    name: spec_name.clone(),
                    version: "?".to_string(),
                    success: false,
                    duration_secs: duration,
                    error: Some(e.to_string()),
                    package_path: None,
                });

                if !continue_on_error {
                    eprintln!();
                    eprintln!(
                        "{} Use {} to continue building remaining packages on failure.",
                        "Tip:".yellow().bold(),
                        "--continue".cyan()
                    );
                    bail!("Build failed for {}", spec_name);
                }
            }
        }
    }

    // Print summary
    let total_duration = start_time.elapsed().as_secs_f64();

    println!();
    println!("{}", "═".repeat(60));
    println!("{}", "Build Summary".bold());
    println!("{}", "═".repeat(60));
    println!();

    // List successful builds
    if success_count > 0 {
        println!("{} ({}):", "Successful".green().bold(), success_count);
        for result in results.iter().filter(|r| r.success) {
            if let Some(ref path) = result.package_path {
                println!(
                    "  {} {}-{} ({:.1}s) → {}",
                    "✓".green(),
                    result.name,
                    result.version,
                    result.duration_secs,
                    path.display()
                );
            } else {
                println!(
                    "  {} {}-{} ({:.1}s)",
                    "✓".green(),
                    result.name,
                    result.version,
                    result.duration_secs
                );
            }
        }
        println!();
    }

    // List failed builds
    if fail_count > 0 {
        println!("{} ({}):", "Failed".red().bold(), fail_count);
        for result in results.iter().filter(|r| !r.success) {
            println!(
                "  {} {}: {}",
                "✗".red(),
                result.name,
                result.error.as_deref().unwrap_or("Unknown error")
            );
        }
        println!();
    }

    // Overall stats
    if fail_count > 0 {
        println!(
            "Total: {} succeeded, {} failed, {:.1}s elapsed",
            success_count.to_string().green(),
            fail_count.to_string().red(),
            total_duration
        );
    } else {
        println!(
            "Total: {} succeeded, {} failed, {:.1}s elapsed",
            success_count.to_string().green(),
            fail_count.to_string(),
            total_duration
        );
    }

    if fail_count > 0 {
        println!();
        println!(
            "{} {} package(s) failed to build.",
            "Warning:".yellow().bold(),
            fail_count
        );
        if !continue_on_error {
            bail!("{} package(s) failed to build", fail_count);
        }
    } else {
        println!();
        println!(
            "{} All {} packages built successfully!",
            "✓".green().bold(),
            success_count
        );
    }

    Ok(())
}

/// Build a single package from a spec file
fn build_single_package(
    spec_path: &Path,
    output_dir: &Path,
    signing_key: &signing::LoadedSigningKey,
    config: &Config,
) -> Result<(String, String, std::path::PathBuf)> {
    use crate::archive::PackageArchiveBuilder;
    use crate::build::PackageBuilder;
    use crate::signing::sign_file;
    use crate::spec::PackageSpec;

    // Parse spec file
    let spec = PackageSpec::from_file(spec_path)?;
    let name = spec.package.name.clone();
    let version = format!("{}-{}", spec.package.version, spec.package.release);

    // Create build environment
    let builder = PackageBuilder::new(config.clone());
    let build_env = builder.build(spec.clone())?;

    // Run build_all for batch execution (quiet mode)
    build_env.fetch_sources()?;
    build_env.apply_patches()?;

    let results = build_env.build_all()?;

    // Check if any phase failed
    for result in &results {
        if !result.success() {
            bail!(
                "Build phase '{}' failed (exit code {})",
                result.phase,
                result.exit_code
            );
        }
    }

    // Collect installed files
    let _installed_files = build_env.collect_installed_files()?;

    // Create package archive
    let mut archive_builder = PackageArchiveBuilder::new(&spec, build_env.dest_dir());
    archive_builder.scan_files()?;

    let package_path = archive_builder.build(output_dir)?;

    // Sign package
    let signature = sign_file(signing_key, &package_path)?;
    let sig_path = package_path.with_extension("rookpkg.sig");
    let sig_json = serde_json::to_string_pretty(&signature)?;
    std::fs::write(&sig_path, &sig_json)?;

    // Clean up build directory
    build_env.clean()?;

    Ok((name, version, package_path))
}
