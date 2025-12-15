//! Autoremove command implementation
//!
//! Find and remove orphan packages (dependencies no longer needed).

use std::path::Path;

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;
use crate::hooks::HookResult;
use crate::transaction::Transaction;

/// Run the autoremove command
pub fn run(dry_run: bool, config: &Config) -> Result<()> {
    if dry_run {
        println!("{}", "Dry run mode - no changes will be made".yellow());
        println!();
    }

    println!("{}", "Finding orphan packages...".cyan());
    println!();

    // Open database
    let db_path = &config.database.path;
    let db = if db_path.exists() {
        Database::open(db_path)?
    } else {
        println!("{}", "No packages installed yet.".yellow());
        return Ok(());
    };

    // Find orphans
    let orphans = db.find_orphans()?;

    if orphans.is_empty() {
        println!("{}", "No orphan packages found.".green());
        println!();
        println!("All dependency packages are still needed by at least one explicitly installed package.");
        return Ok(());
    }

    // Show orphans
    println!(
        "{} {} orphan package(s) found:",
        "→".cyan(),
        orphans.len()
    );
    println!();

    let mut total_size: u64 = 0;
    for pkg in &orphans {
        total_size += pkg.size_bytes;
        println!(
            "  {} {}-{}-{} ({})",
            "✗".red(),
            pkg.name.bold(),
            pkg.version,
            pkg.release,
            format_size(pkg.size_bytes).dimmed()
        );
    }

    println!();
    println!(
        "Total size to free: {}",
        format_size(total_size).cyan()
    );
    println!();

    if dry_run {
        println!("{}", "Dry run complete - no packages removed.".yellow());
        return Ok(());
    }

    // Remove orphans using transaction
    println!("{}", "Removing orphan packages...".cyan());
    println!();

    let root = Path::new("/");

    // Re-open database for transaction
    let db = Database::open(db_path)?;
    let mut tx = Transaction::new(root, db)?;

    for pkg in &orphans {
        tx.remove(&pkg.name);
    }

    match tx.execute_with_hooks(&config.hooks) {
        Ok((pre_results, post_results)) => {
            print_hook_results("pre-transaction", &pre_results);

            println!();
            println!(
                "{} {} orphan package(s) removed, freed {}",
                "✓".green().bold(),
                orphans.len(),
                format_size(total_size)
            );

            print_hook_results("post-transaction", &post_results);
        }
        Err(e) => {
            println!(
                "{} Removal failed: {}",
                "✗".red().bold(),
                e
            );
            bail!("Autoremove transaction failed: {}", e);
        }
    }

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

/// Mark a package as explicitly installed (won't be autoremoved)
pub fn mark_explicit(packages: &[String], config: &Config) -> Result<()> {
    use crate::package::InstallReason;

    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    println!("{}", "Marking packages as explicitly installed...".cyan());
    println!();

    let mut marked = 0;
    let mut not_found = Vec::new();
    let mut already_explicit = Vec::new();

    for name in packages {
        match db.get_install_reason(name)? {
            Some(InstallReason::Explicit) => {
                already_explicit.push(name.clone());
            }
            Some(InstallReason::Dependency) => {
                db.set_install_reason(name, InstallReason::Explicit)?;
                marked += 1;
                println!(
                    "  {} {} marked as explicit",
                    "✓".green(),
                    name.bold()
                );
            }
            None => {
                not_found.push(name.clone());
            }
        }
    }

    println!();

    if !not_found.is_empty() {
        println!("{}", "Not installed:".yellow());
        for name in &not_found {
            println!("  {} {}", "!".yellow(), name);
        }
        println!();
    }

    if !already_explicit.is_empty() {
        println!("{}", "Already explicit:".dimmed());
        for name in &already_explicit {
            println!("  {} {}", "→".dimmed(), name);
        }
        println!();
    }

    if marked > 0 {
        println!(
            "{} {} package(s) marked as explicitly installed",
            "✓".green().bold(),
            marked
        );
    } else if not_found.is_empty() && already_explicit.is_empty() {
        println!("{}", "No packages to mark.".yellow());
    }

    Ok(())
}

/// Mark a package as a dependency (can be autoremoved)
pub fn mark_dependency(packages: &[String], config: &Config) -> Result<()> {
    use crate::package::InstallReason;

    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    println!("{}", "Marking packages as dependencies...".cyan());
    println!();

    let mut marked = 0;
    let mut not_found = Vec::new();
    let mut already_dep = Vec::new();

    for name in packages {
        match db.get_install_reason(name)? {
            Some(InstallReason::Dependency) => {
                already_dep.push(name.clone());
            }
            Some(InstallReason::Explicit) => {
                db.set_install_reason(name, InstallReason::Dependency)?;
                marked += 1;
                println!(
                    "  {} {} marked as dependency",
                    "✓".green(),
                    name.bold()
                );
            }
            None => {
                not_found.push(name.clone());
            }
        }
    }

    println!();

    if !not_found.is_empty() {
        println!("{}", "Not installed:".yellow());
        for name in &not_found {
            println!("  {} {}", "!".yellow(), name);
        }
        println!();
    }

    if !already_dep.is_empty() {
        println!("{}", "Already marked as dependency:".dimmed());
        for name in &already_dep {
            println!("  {} {}", "→".dimmed(), name);
        }
        println!();
    }

    if marked > 0 {
        println!(
            "{} {} package(s) marked as dependency",
            "✓".green().bold(),
            marked
        );
        println!();
        println!("These packages may be removed by {} if no longer needed.", "rookpkg autoremove".bold());
    } else if not_found.is_empty() && already_dep.is_empty() {
        println!("{}", "No packages to mark.".yellow());
    }

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
