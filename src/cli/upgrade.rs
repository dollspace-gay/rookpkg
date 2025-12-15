//! Upgrade command implementation

use std::path::Path;

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;
use crate::hooks::HookResult;
use crate::repository::{RepoManager, SignatureStatus};
use crate::signing::TrustLevel;
use crate::transaction::TransactionBuilder;

/// Upgradeable package info
struct UpgradeCandidate {
    name: String,
    installed_version: String,
    installed_release: u32,
    available_version: String,
    available_release: u32,
    repo_name: String,
}

impl UpgradeCandidate {
    fn installed_full(&self) -> String {
        format!("{}-{}", self.installed_version, self.installed_release)
    }

    fn available_full(&self) -> String {
        format!("{}-{}", self.available_version, self.available_release)
    }
}

pub fn run(dry_run: bool, config: &Config) -> Result<()> {
    if dry_run {
        println!("{}", "Dry run mode - no changes will be made".yellow());
        println!();
    }

    println!("{}", "Checking for upgrades...".cyan());
    println!();

    // Open database
    let db_path = &config.database.path;
    let db = if db_path.exists() {
        Database::open(db_path)?
    } else {
        println!("{}", "No packages installed yet.".yellow());
        return Ok(());
    };

    // Get installed packages
    let installed = db.list_packages()?;
    if installed.is_empty() {
        println!("{}", "No packages installed.".yellow());
        return Ok(());
    }

    println!(
        "  {} {} package(s) installed",
        "✓".green(),
        installed.len()
    );

    // Load repository data
    let mut manager = RepoManager::new(config)?;
    manager.load_caches()?;

    if config.repositories.is_empty() {
        println!();
        println!("{}", "No repositories configured.".yellow());
        println!("Run {} to add repositories.", "rookpkg update".bold());
        return Ok(());
    }

    // Find upgradeable packages
    let mut upgrades: Vec<UpgradeCandidate> = Vec::new();
    let mut held_packages: Vec<(String, String)> = Vec::new();

    for pkg in &installed {
        // Check if package is held
        if db.is_package_held(&pkg.name)? {
            if let Some(result) = manager.find_package(&pkg.name) {
                let available = &result.package;
                // Only report if there's actually an upgrade available
                let needs_upgrade = if available.version != pkg.version {
                    available.version > pkg.version
                } else {
                    available.release > pkg.release
                };
                if needs_upgrade {
                    let available_full = format!("{}-{}", available.version, available.release);
                    held_packages.push((pkg.name.clone(), available_full));
                }
            }
            continue;  // Skip held packages
        }

        if let Some(result) = manager.find_package(&pkg.name) {
            let available = &result.package;

            // Compare versions (simple string comparison for now)
            // TODO: Use proper semver comparison
            let needs_upgrade = if available.version != pkg.version {
                available.version > pkg.version
            } else {
                available.release > pkg.release
            };

            if needs_upgrade {
                upgrades.push(UpgradeCandidate {
                    name: pkg.name.clone(),
                    installed_version: pkg.version.clone(),
                    installed_release: pkg.release,
                    available_version: available.version.clone(),
                    available_release: available.release,
                    repo_name: result.repository.clone(),
                });
            }
        }
    }

    println!();

    // Show held packages that have updates available
    if !held_packages.is_empty() {
        println!("{}", "Held packages (skipped):".yellow());
        for (name, available) in &held_packages {
            println!(
                "  {} {} ({} available)",
                "⏸".yellow(),
                name.bold(),
                available.dimmed()
            );
        }
        println!();
        println!(
            "Use {} to release holds.",
            "rookpkg unhold <package>".bold()
        );
        println!();
    }

    if upgrades.is_empty() {
        println!("{}", "All packages are up to date.".green());
        return Ok(());
    }

    // Show upgrades
    println!(
        "{} {} package(s) can be upgraded:",
        "→".cyan(),
        upgrades.len()
    );
    println!();

    for upgrade in &upgrades {
        println!(
            "  {} {} {} → {} (from {})",
            "↑".cyan(),
            upgrade.name.bold(),
            upgrade.installed_full().dimmed(),
            upgrade.available_full().green(),
            upgrade.repo_name.cyan()
        );
    }

    println!();

    // Calculate download size
    let total_size: u64 = upgrades
        .iter()
        .filter_map(|u| manager.find_package(&u.name))
        .map(|r| r.package.size)
        .sum();

    println!(
        "Total download size: {}",
        format_size(total_size).cyan()
    );
    println!();

    if dry_run {
        println!("{}", "Dry run complete - no packages downloaded.".yellow());
        return Ok(());
    }

    // Download and verify packages
    println!("{}", "Downloading and verifying packages...".cyan());
    println!();

    let mut verified_packages = Vec::new();

    for upgrade in &upgrades {
        let result = manager.find_package(&upgrade.name).unwrap();

        print!(
            "  {} {}-{}... ",
            "↓".cyan(),
            result.package.name,
            result.package.version
        );

        match manager.download_and_verify_package(&result.package, &result.repository, config) {
            Ok(verified) => {
                // Use SignatureStatus methods for consistent display
                let sig_desc = verified.signature_status.description();
                if let SignatureStatus::Verified { signer, trust_level, fingerprint } = &verified.signature_status {
                    let trust_color = match trust_level {
                        TrustLevel::Ultimate => "ultimate".green(),
                        TrustLevel::Full => "full".green(),
                        TrustLevel::Marginal => "marginal".yellow(),
                        TrustLevel::Unknown => "unknown".red(),
                    };
                    println!("{} [signed by {} ({}) - {}]", "✓".green(), signer.cyan(), trust_color, fingerprint.dimmed());
                    tracing::debug!("Signature status: {}", sig_desc);
                }

                verified_packages.push((upgrade, verified, result.repository.clone()));
            }
            Err(e) => {
                println!("{}", "✗".red());
                bail!("Failed to download/verify {}: {}", upgrade.name, e);
            }
        }
    }

    println!();

    // Perform upgrades using TransactionBuilder for cleaner API
    println!("{}", "Installing upgrades...".cyan());
    println!();

    // Build upgrade operations
    let root = Path::new("/");
    let mut builder = TransactionBuilder::new(root);

    for (upgrade, verified, _repo) in &verified_packages {
        builder = builder.upgrade(
            &upgrade.name,
            &upgrade.installed_full(),
            &upgrade.available_full(),
            &verified.path,
        );
    }

    // Re-open database for transaction execution
    let db = Database::open(db_path)?;

    match builder.execute_with_hooks(db, &config.hooks) {
        Ok((pre_results, post_results)) => {
            print_hook_results("pre-transaction", &pre_results);

            println!(
                "{} {} package(s) upgraded successfully",
                "✓".green().bold(),
                verified_packages.len()
            );

            print_hook_results("post-transaction", &post_results);
        }
        Err(e) => {
            println!(
                "{} Upgrade failed: {}",
                "✗".red().bold(),
                e
            );
            bail!("Upgrade transaction failed: {}", e);
        }
    }

    println!();
    println!("{}", "Upgrade complete!".green());

    Ok(())
}

/// Print hook execution results
fn print_hook_results(phase: &str, results: &[HookResult]) {
    if results.is_empty() {
        return;
    }

    let success_count = results.iter().filter(|r| r.success).count();
    let fail_count = results.len() - success_count;

    if fail_count == 0 {
        println!(
            "  {} {} hook(s) ran successfully",
            "→".cyan(),
            results.len()
        );
    } else {
        println!(
            "  {} {} {} hook(s): {} succeeded, {} failed",
            "!".yellow(),
            results.len(),
            phase,
            success_count,
            fail_count
        );
        for result in results {
            if !result.success {
                println!(
                    "    {} {} (exit code: {:?})",
                    "✗".red(),
                    result.name,
                    result.exit_code
                );
                // Show stderr if available
                if !result.stderr.is_empty() {
                    for line in result.stderr.lines().take(3) {
                        println!("      {}", line.dimmed());
                    }
                }
                // Show stdout if stderr is empty but stdout has content
                else if !result.stdout.is_empty() {
                    for line in result.stdout.lines().take(3) {
                        println!("      {}", line.dimmed());
                    }
                }
            }
        }
    }
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
