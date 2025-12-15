//! Info command implementation

use anyhow::Result;
use chrono::{TimeZone, Utc};
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;
use crate::repository::RepoManager;

pub fn run(package: &str, deps: bool, config: &Config) -> Result<()> {
    // First try to find installed package
    let db_path = &config.database.path;
    if db_path.exists() {
        let db = Database::open(db_path)?;
        if let Some(pkg) = db.get_package(package)? {
            println!("{}", "Installed Package Information".bold().underline());
            println!();
            println!("  {:<14} {}", "Name:".bold(), pkg.name.cyan());
            println!("  {:<14} {}", "Version:".bold(), pkg.version);
            println!("  {:<14} {}", "Release:".bold(), pkg.release);
            println!("  {:<14} {}", "Full Version:".bold(), pkg.full_version());
            println!("  {:<14} {}", "Size:".bold(), format_size(pkg.size_bytes));

            // Format install date
            let install_date = Utc.timestamp_opt(pkg.install_date, 0)
                .single()
                .map(|dt| dt.format("%Y-%m-%d %H:%M:%S UTC").to_string())
                .unwrap_or_else(|| "Unknown".to_string());
            println!("  {:<14} {}", "Installed:".bold(), install_date);

            if !pkg.checksum.is_empty() {
                println!("  {:<14} {}", "Checksum:".bold(), pkg.checksum.dimmed());
            }

            if deps {
                println!();
                println!("{}", "Dependencies:".bold());
                let dependencies = db.get_dependencies(package)?;
                if dependencies.is_empty() {
                    println!("  {}", "None".dimmed());
                } else {
                    for dep in &dependencies {
                        println!(
                            "  {} {} {}",
                            "→".cyan(),
                            dep.depends_on.bold(),
                            if dep.constraint.is_empty() {
                                String::new()
                            } else {
                                format!("({})", dep.constraint).dimmed().to_string()
                            }
                        );
                    }
                }

                println!();
                println!("{}", "Required by:".bold());
                let rdeps = db.get_reverse_dependencies(package)?;
                if rdeps.is_empty() {
                    println!("  {}", "None".dimmed());
                } else {
                    for rdep in &rdeps {
                        println!("  {} {}", "←".cyan(), rdep.bold());
                    }
                }
            }

            // Show installed files count
            let files = db.get_files(package)?;
            println!();
            println!("  {:<14} {}", "Files:".bold(), files.len());

            return Ok(());
        }
    }

    // Not installed, check repositories
    let mut manager = RepoManager::new(config)?;
    manager.load_caches()?;

    if let Some(result) = manager.find_package(package) {
        let pkg = &result.package;

        println!("{}", "Available Package Information".bold().underline());
        println!();
        println!("  {:<14} {}", "Name:".bold(), pkg.name.cyan());
        println!("  {:<14} {}", "Version:".bold(), pkg.version);
        println!("  {:<14} {}", "Release:".bold(), pkg.release);
        println!("  {:<14} {}", "Repository:".bold(), result.repository.green());
        println!("  {:<14} {}", "Size:".bold(), format_size(pkg.size));

        if !pkg.description.is_empty() {
            println!();
            println!("{}", "Description:".bold());
            println!("  {}", pkg.description);
        }

        if let Some(ref license) = pkg.license {
            if !license.is_empty() {
                println!("  {:<14} {}", "License:".bold(), license);
            }
        }

        if let Some(ref homepage) = pkg.homepage {
            if !homepage.is_empty() {
                println!("  {:<14} {}", "Homepage:".bold(), homepage.underline());
            }
        }

        if deps && !pkg.depends.is_empty() {
            println!();
            println!("{}", "Dependencies:".bold());
            for dep in &pkg.depends {
                println!(
                    "  {} {}",
                    "→".cyan(),
                    dep.bold(),
                );
            }
        }

        println!();
        println!(
            "  {} Install with: {}",
            "→".cyan(),
            format!("rookpkg install {}", package).bold()
        );

        return Ok(());
    }

    // Not found anywhere
    println!("{}: {}", "Package".bold(), package.cyan());
    println!();
    println!("  {}", "Package not found.".red());
    println!();
    println!("  Try {} to refresh package lists.", "rookpkg update".bold());

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
