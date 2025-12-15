//! Check command implementation - verify integrity of installed packages

use std::path::Path;

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;
use crate::download::compute_sha256;

pub fn run(package: Option<&str>, config: &Config) -> Result<()> {
    let db_path = &config.database.path;
    if !db_path.exists() {
        println!("{}", "No packages installed.".yellow());
        return Ok(());
    }

    let db = Database::open(db_path)?;

    match package {
        Some(name) => check_package(&db, name),
        None => check_all_packages(&db),
    }
}

fn check_package(db: &Database, name: &str) -> Result<()> {
    println!("{} {}...", "Checking package".cyan(), name.bold());
    println!();

    let pkg = match db.get_package(name)? {
        Some(p) => p,
        None => {
            println!("  {} Package {} is not installed", "✗".red(), name.bold());
            return Ok(());
        }
    };

    let files = db.get_files(name)?;

    if files.is_empty() {
        println!("  {} No files recorded for package", "!".yellow());
        return Ok(());
    }

    let mut ok_count = 0;
    let mut missing_count = 0;
    let mut modified_count = 0;

    for file in &files {
        let path = Path::new(&file.path);

        if !path.exists() {
            println!("  {} {} (missing)", "✗".red(), file.path);
            missing_count += 1;
            continue;
        }

        // Skip directories
        if path.is_dir() {
            ok_count += 1;
            continue;
        }

        // Verify checksum if available
        if !file.checksum.is_empty() {
            match compute_sha256(path) {
                Ok(actual) => {
                    if actual != file.checksum {
                        println!(
                            "  {} {} (modified)",
                            "!".yellow(),
                            file.path
                        );
                        modified_count += 1;
                    } else {
                        ok_count += 1;
                    }
                }
                Err(e) => {
                    println!(
                        "  {} {} (error: {})",
                        "?".yellow(),
                        file.path,
                        e
                    );
                }
            }
        } else {
            // No checksum, just verify existence
            ok_count += 1;
        }
    }

    println!();
    println!("{}", "Summary:".bold());
    println!(
        "  {} {}-{}",
        "Package:".dimmed(),
        pkg.name.bold(),
        pkg.full_version()
    );
    println!("  {} {} files OK", "✓".green(), ok_count);

    if missing_count > 0 {
        println!("  {} {} files missing", "✗".red(), missing_count);
    }

    if modified_count > 0 {
        println!("  {} {} files modified", "!".yellow(), modified_count);
    }

    if missing_count == 0 && modified_count == 0 {
        println!();
        println!(
            "  {} Package {} is intact",
            "✓".green().bold(),
            name.cyan()
        );
    } else {
        println!();
        println!(
            "  {} Package {} has issues",
            "!".yellow().bold(),
            name.cyan()
        );
        println!();
        println!(
            "  Consider reinstalling with: {}",
            format!("rookpkg install --force {}", name).bold()
        );
    }

    Ok(())
}

fn check_all_packages(db: &Database) -> Result<()> {
    println!("{}", "Checking all installed packages...".cyan());
    println!();

    let packages = db.list_packages()?;

    if packages.is_empty() {
        println!("  {}", "No packages installed.".dimmed());
        return Ok(());
    }

    let mut total_ok = 0;
    let mut total_issues = 0;

    for pkg in &packages {
        let files = db.get_files(&pkg.name)?;

        let mut pkg_ok = true;
        let mut missing = 0;
        let mut modified = 0;

        for file in &files {
            let path = Path::new(&file.path);

            if !path.exists() {
                missing += 1;
                pkg_ok = false;
                continue;
            }

            if path.is_dir() {
                continue;
            }

            if !file.checksum.is_empty() {
                if let Ok(actual) = compute_sha256(path) {
                    if actual != file.checksum {
                        modified += 1;
                        pkg_ok = false;
                    }
                }
            }
        }

        let status = if pkg_ok {
            total_ok += 1;
            "✓".green()
        } else {
            total_issues += 1;
            "!".yellow()
        };

        let issues = if missing > 0 || modified > 0 {
            format!(
                " ({} missing, {} modified)",
                missing, modified
            )
            .dimmed()
            .to_string()
        } else {
            String::new()
        };

        println!(
            "  {} {}-{}{}",
            status,
            pkg.name.bold(),
            pkg.full_version().dimmed(),
            issues
        );
    }

    println!();
    println!("{}", "Summary:".bold());
    println!(
        "  {} {} package(s) checked",
        "→".cyan(),
        packages.len()
    );
    println!("  {} {} OK", "✓".green(), total_ok);

    if total_issues > 0 {
        println!("  {} {} with issues", "!".yellow(), total_issues);
    }

    if total_issues == 0 {
        println!();
        println!("{}", "All packages are intact.".green().bold());
    }

    Ok(())
}
