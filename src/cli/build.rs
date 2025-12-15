//! Build command implementation

use std::path::Path;

use anyhow::{bail, Result};
use chrono::Utc;
use colored::Colorize;

use crate::archive::PackageArchiveBuilder;
use crate::build::{PackageBuilder, PhaseResult};
use crate::cli::inspect::validate_built_archive;
use crate::config::Config;
use crate::database::Database;
use crate::delta::DeltaBuilder;
use crate::download::compute_sha256;
use crate::repository::{PackageEntry, PackageIndex};
use crate::signing::{self, sign_file};
use crate::spec::PackageSpec;
use crate::transaction::Transaction;

pub fn run(
    spec_path: &Path,
    install: bool,
    output: Option<&Path>,
    batch: bool,
    update_index: bool,
    delta_from: Option<&Path>,
    config: &Config,
) -> Result<()> {
    // CRITICAL: Check for signing key FIRST
    println!("{}", "Checking signing key...".cyan());

    let signing_key = match signing::load_signing_key(config) {
        Ok(key) => {
            // Show key owner info
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
            eprintln!("For more information:");
            eprintln!("  rookpkg keygen --help");
            eprintln!();
            bail!("Signing key required: {}", e);
        }
    };

    // Parse spec file and create build environment
    println!("{}", "Parsing spec file...".cyan());

    if !spec_path.exists() {
        bail!("Spec file not found: {}", spec_path.display());
    }

    // Read spec first
    let spec = PackageSpec::from_file(spec_path)?;

    // Create build environment using PackageBuilder::build() with the parsed spec
    // (build_from_spec would re-parse, so using build() is more efficient)
    let builder = PackageBuilder::new(config.clone());
    let build_env = builder.build(spec.clone())?;

    println!(
        "  {} {}-{}-{}",
        "✓".green(),
        spec.package.name.bold(),
        spec.package.version,
        spec.package.release
    );

    // Show build directories
    println!("{}", "Setting up build environment...".cyan());
    println!(
        "  {} Build directory: {}",
        "✓".green(),
        build_env.build_dir().display()
    );
    println!(
        "  {} Source directory: {}",
        "✓".green(),
        build_env.src_dir().display()
    );
    println!(
        "  {} Dest directory: {}",
        "✓".green(),
        build_env.dest_dir().display()
    );
    println!(
        "  {} Cache directory: {}",
        "✓".green(),
        build_env.cache_dir().display()
    );
    println!(
        "  {} Parallel jobs: {}",
        "✓".green(),
        build_env.jobs()
    );

    // Build using either batch mode (build_all) or individual phases
    if batch {
        // Batch mode: use build_all for simple sequential execution
        println!("{}", "Building package (batch mode)...".cyan());
        let results = build_env.build_all()?;

        // Report results
        let total_duration: f64 = results.iter().map(|r| r.duration_secs).sum();
        for result in &results {
            let status = if result.success() { "✓".green() } else { "✗".red() };
            println!("  {} {} ({:.1}s)", status, result.phase, result.duration_secs);
        }
        println!("  {} Total build time: {:.1}s", "→".cyan(), total_duration);
    } else {
        // Standard mode: manual control over each phase
        // Download and verify sources
        println!("{}", "Downloading sources...".cyan());
        build_env.fetch_sources()?;
        println!("  {} Sources downloaded", "✓".green());

        // Apply patches
        println!("{}", "Applying patches...".cyan());
        build_env.apply_patches()?;
        println!("  {} Patches applied", "✓".green());

        // Execute build phases individually for better control and reporting
        println!("{}", "Building package...".cyan());

        // Helper to run and report a phase
        fn run_phase(name: &str, result: Result<PhaseResult>) -> Result<()> {
            let result = result?;
            let status = if result.success() {
                "✓".green()
            } else {
                "✗".red()
            };
            println!(
                "  {} {} ({:.1}s)",
                status,
                result.phase,
                result.duration_secs
            );

            if !result.success() {
                eprintln!();
                eprintln!("{}", "Build failed!".red().bold());
                let output = format!("{}\n{}", result.stdout, result.stderr);
                if !output.trim().is_empty() {
                    eprintln!();
                    eprintln!("{}", "Output:".bold());
                    for line in output.lines().take(50) {
                        eprintln!("  {}", line);
                    }
                }
                bail!("Build phase '{}' failed", name);
            }
            Ok(())
        }

        // Run each phase individually
        run_phase("prep", build_env.run_prep())?;
        run_phase("configure", build_env.run_configure())?;
        run_phase("build", build_env.run_build())?;
        run_phase("check", build_env.run_check())?;
        run_phase("install", build_env.run_install())?;
    }

    // Collect installed files
    println!("{}", "Collecting installed files...".cyan());
    let installed_files = build_env.collect_installed_files()?;
    println!(
        "  {} {} files collected",
        "✓".green(),
        installed_files.len()
    );

    // Create package archive
    println!("{}", "Creating package archive...".cyan());

    let output_dir = output.unwrap_or(Path::new("."));
    let mut archive_builder = PackageArchiveBuilder::new(&spec, build_env.dest_dir());
    archive_builder.scan_files()?;

    // Use info() and files() to show what will be packaged
    let pkg_info = archive_builder.info();
    let pkg_files = archive_builder.files();
    println!(
        "  {} Packaging {}-{}-{}",
        "→".cyan(),
        pkg_info.name,
        pkg_info.version,
        pkg_info.release
    );
    println!(
        "  {} {} files, {} installed size",
        "→".cyan(),
        pkg_files.len(),
        format_size(pkg_info.installed_size)
    );

    // Validate archive before building
    validate_built_archive(&archive_builder)?;

    let package_path = archive_builder.build(output_dir)?;
    println!(
        "  {} Package created: {}",
        "✓".green(),
        package_path.display()
    );

    // Sign package
    println!("{}", "Signing package...".cyan());

    let signature = sign_file(&signing_key, &package_path)?;

    // Write signature file
    let sig_path = package_path.with_extension("rookpkg.sig");
    let sig_json = serde_json::to_string_pretty(&signature)?;
    std::fs::write(&sig_path, &sig_json)?;

    println!(
        "  {} Signed with key: {}",
        "✓".green(),
        signing::get_fingerprint(&signing_key).dimmed()
    );
    println!(
        "  {} Signature: {}",
        "✓".green(),
        sig_path.display()
    );

    // Generate delta package if requested
    let delta_path = if let Some(old_package) = delta_from {
        println!("{}", "Generating delta package...".cyan());

        if !old_package.exists() {
            eprintln!(
                "  {} Old package not found: {}",
                "!".yellow(),
                old_package.display()
            );
            None
        } else {
            match DeltaBuilder::new(old_package, &package_path) {
                Ok(delta_builder) => {
                    match delta_builder.build(output_dir) {
                        Ok(delta_file) => {
                            // Calculate savings
                            let delta_size = std::fs::metadata(&delta_file)
                                .map(|m| m.len())
                                .unwrap_or(0);
                            let new_size = std::fs::metadata(&package_path)
                                .map(|m| m.len())
                                .unwrap_or(0);
                            let savings = if new_size > 0 {
                                100.0 - (delta_size as f64 / new_size as f64 * 100.0)
                            } else {
                                0.0
                            };

                            println!(
                                "  {} Delta created: {}",
                                "✓".green(),
                                delta_file.display()
                            );
                            println!(
                                "  {} Size: {} ({:.1}% savings vs full package)",
                                "→".cyan(),
                                format_size(delta_size),
                                savings
                            );

                            // Sign the delta file
                            let delta_signature = sign_file(&signing_key, &delta_file)?;
                            let delta_sig_path = delta_file.with_extension("rookdelta.sig");
                            let delta_sig_json = serde_json::to_string_pretty(&delta_signature)?;
                            std::fs::write(&delta_sig_path, &delta_sig_json)?;
                            println!(
                                "  {} Delta signature: {}",
                                "✓".green(),
                                delta_sig_path.display()
                            );

                            Some(delta_file)
                        }
                        Err(e) => {
                            eprintln!("  {} Delta generation failed: {}", "!".yellow(), e);
                            None
                        }
                    }
                }
                Err(e) => {
                    eprintln!("  {} Failed to initialize delta builder: {}", "!".yellow(), e);
                    None
                }
            }
        }
    } else {
        None
    };

    // Clean up build directory
    println!("{}", "Cleaning up...".cyan());
    build_env.clean()?;
    println!("  {} Build directory cleaned", "✓".green());

    println!();
    println!("{}", "Build complete!".green().bold());
    println!();
    println!("  {}: {}", "Package".bold(), package_path.display());
    println!("  {}: {}", "Signature".bold(), sig_path.display());
    if let Some(ref delta) = delta_path {
        println!("  {}: {}", "Delta".bold(), delta.display());
    }
    println!(
        "  {}: {}",
        "Size".bold(),
        format_size(std::fs::metadata(&package_path)?.len())
    );

    if install {
        println!();
        println!("{}", "Installing built package...".cyan());

        // Open database
        let db_path = &config.database.path;
        let db = Database::open(db_path)?;

        // Check if already installed
        if let Some(existing) = db.get_package(&spec.package.name)? {
            println!(
                "  {} Package {} already installed ({})",
                "!".yellow(),
                spec.package.name.bold(),
                existing.full_version()
            );
            println!("  Use {} to upgrade.", "rookpkg upgrade".bold());
            return Ok(());
        }

        // Install using transaction
        let db = Database::open(db_path)?;
        let root = Path::new("/");
        let mut tx = Transaction::new(root, db)?;

        let version = format!("{}-{}", spec.package.version, spec.package.release);
        tx.install(&spec.package.name, &version, &package_path);

        match tx.execute() {
            Ok(()) => {
                println!(
                    "  {} Package installed successfully",
                    "✓".green().bold()
                );
            }
            Err(e) => {
                println!(
                    "  {} Installation failed: {}",
                    "✗".red().bold(),
                    e
                );
                bail!("Installation failed: {}", e);
            }
        }
    }

    // Update local package index if requested
    if update_index {
        println!();
        println!("{}", "Updating local package index...".cyan());

        let index_path = output_dir.join("packages.json");

        // Load existing index or create new one
        let mut pkg_index = if index_path.exists() {
            let content = std::fs::read_to_string(&index_path)?;
            serde_json::from_str::<PackageIndex>(&content)
                .unwrap_or_else(|_| PackageIndex::new("local"))
        } else {
            PackageIndex::new("local")
        };

        // Create package entry from spec and built package info
        let pkg_size = std::fs::metadata(&package_path)?.len();
        let entry = PackageEntry {
            name: spec.package.name.clone(),
            version: spec.package.version.clone(),
            release: spec.package.release,
            description: spec.package.description.clone(),
            arch: "x86_64".to_string(),
            size: pkg_size,
            sha256: compute_sha256(&package_path)?,
            filename: package_path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            // Convert HashMap<String, String> keys to Vec<String> for dependencies
            depends: spec.depends.keys().cloned().collect(),
            build_depends: spec.build_depends.keys().cloned().collect(),
            provides: Vec::new(),
            conflicts: Vec::new(),
            replaces: Vec::new(),
            license: if spec.package.license.is_empty() {
                None
            } else {
                Some(spec.package.license.clone())
            },
            homepage: if spec.package.url.is_empty() {
                None
            } else {
                Some(spec.package.url.clone())
            },
            maintainer: if spec.package.maintainer.is_empty() {
                None
            } else {
                Some(spec.package.maintainer.clone())
            },
            build_date: Some(Utc::now()),
        };

        // Add package to index (this uses PackageIndex::add_package)
        pkg_index.add_package(entry);

        // Write updated index
        let index_content = serde_json::to_string_pretty(&pkg_index)?;
        std::fs::write(&index_path, &index_content)?;

        println!(
            "  {} Updated {} ({} packages)",
            "✓".green(),
            index_path.display(),
            pkg_index.count
        );

        // Sign the index file
        let sig_path = index_path.with_extension("json.sig");
        let index_sig = signing::sign_file(&signing_key, &index_path)?;
        let sig_json = serde_json::to_string_pretty(&index_sig)?;
        std::fs::write(&sig_path, &sig_json)?;

        println!(
            "  {} Signed index: {}",
            "✓".green(),
            sig_path.display()
        );
    }

    Ok(())
}

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
