//! Remove command implementation

use std::path::Path;

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;
use crate::hooks::HookResult;
use crate::transaction::{Operation, TransactionBuilder};

pub fn run(packages: &[String], cascade: bool, dry_run: bool, config: &Config) -> Result<()> {
    if dry_run {
        println!("{}", "Dry run mode - no changes will be made".yellow());
        println!();
    }

    // Open database
    let db_path = &config.database.path;
    let db = if db_path.exists() {
        Database::open(db_path)?
    } else {
        println!("{}", "No packages installed yet.".yellow());
        return Ok(());
    };

    // Check which packages are installed
    let mut to_remove = Vec::new();
    let mut not_installed = Vec::new();
    let mut blocked = Vec::new();

    for package in packages {
        match db.get_package(package)? {
            Some(pkg) => {
                // Check for reverse dependencies
                let rdeps = db.get_reverse_dependencies(package)?;
                if !rdeps.is_empty() && !cascade {
                    blocked.push((package.clone(), rdeps));
                } else {
                    to_remove.push(pkg);
                }
            }
            None => {
                not_installed.push(package.clone());
            }
        }
    }

    // Report not installed packages
    if !not_installed.is_empty() {
        println!("{}", "Some packages are not installed:".yellow());
        for name in &not_installed {
            println!("  {} {}", "!".yellow(), name);
        }
        println!();
    }

    // Report blocked packages
    if !blocked.is_empty() {
        println!("{}", "Some packages cannot be removed due to dependencies:".red());
        for (name, rdeps) in &blocked {
            println!(
                "  {} {} is required by: {}",
                "✗".red(),
                name.bold(),
                rdeps.join(", ")
            );
        }
        println!();
        println!(
            "Use {} to remove dependent packages too.",
            "--cascade".bold()
        );
        println!();
    }

    if to_remove.is_empty() {
        if blocked.is_empty() && not_installed.is_empty() {
            println!("{}", "Nothing to remove.".yellow());
        }
        return Ok(());
    }

    // Show what will be removed
    println!("{}", "The following packages will be removed:".cyan());
    println!();

    let mut total_size: u64 = 0;
    for pkg in &to_remove {
        println!(
            "  {} {}-{}",
            "✗".red(),
            pkg.name.bold(),
            pkg.full_version()
        );
        total_size += pkg.size_bytes;
    }

    // If cascade mode, add dependent packages
    if cascade {
        let mut additional = Vec::new();
        for (name, _) in &blocked {
            if let Some(pkg) = db.get_package(name)? {
                additional.push(pkg.clone());
                // Recursively get dependencies
                let mut to_check = vec![name.clone()];
                while let Some(check_name) = to_check.pop() {
                    let rdeps = db.get_reverse_dependencies(&check_name)?;
                    for rdep in rdeps {
                        if !additional.iter().any(|p| p.name == rdep)
                            && !to_remove.iter().any(|p| p.name == rdep)
                        {
                            if let Some(rdep_pkg) = db.get_package(&rdep)? {
                                println!(
                                    "  {} {}-{} {}",
                                    "✗".red(),
                                    rdep_pkg.name.bold(),
                                    rdep_pkg.full_version(),
                                    "(cascade)".dimmed()
                                );
                                total_size += rdep_pkg.size_bytes;
                                additional.push(rdep_pkg);
                                to_check.push(rdep);
                            }
                        }
                    }
                }
            }
        }
        to_remove.extend(additional);
    }

    println!();
    println!(
        "Space to be freed: {}",
        format_size(total_size).green()
    );
    println!();

    if dry_run {
        println!("{}", "Dry run complete - no packages removed.".yellow());
        return Ok(());
    }

    // Perform removal using TransactionBuilder for cleaner API
    println!("{}", "Removing packages...".cyan());
    println!();

    // Build remove operations
    let root = Path::new("/");
    let mut builder = TransactionBuilder::new(root);

    for pkg in &to_remove {
        builder = builder.remove(&pkg.name);
    }

    // Log operations using Operation::package_name
    let operations: Vec<Operation> = to_remove
        .iter()
        .map(|p| Operation::Remove { package: p.name.clone() })
        .collect();
    for op in &operations {
        tracing::debug!("Queued operation: remove {}", op.package_name());
    }

    // Execute using Transaction (TransactionBuilder.execute needs db)
    // Re-open database for transaction
    let db = Database::open(db_path)?;

    match builder.execute_with_hooks(db, &config.hooks) {
        Ok((pre_results, post_results)) => {
            print_hook_results("pre-transaction", &pre_results);

            println!(
                "{} {} package(s) removed successfully",
                "✓".green().bold(),
                to_remove.len()
            );

            print_hook_results("post-transaction", &post_results);
        }
        Err(e) => {
            println!(
                "{} Removal failed: {}",
                "✗".red().bold(),
                e
            );
            bail!("Removal transaction failed: {}", e);
        }
    }

    println!();
    println!("{}", "Removal complete!".green());

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
