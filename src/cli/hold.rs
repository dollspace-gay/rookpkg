//! Hold/unhold command implementation
//!
//! Hold packages to prevent automatic upgrades.

use anyhow::Result;
use chrono::{TimeZone, Utc};
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;

/// Hold a package (prevent automatic upgrades)
pub fn hold(packages: &[String], reason: Option<&str>, config: &Config) -> Result<()> {
    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    let reason_text = reason.unwrap_or("");

    println!("{}", "Holding packages...".cyan());
    println!();

    let mut held_count = 0;
    let mut not_installed = Vec::new();
    let mut already_held = Vec::new();

    for name in packages {
        // Check if package is installed
        let pkg = db.get_package(name)?;
        if pkg.is_none() {
            not_installed.push(name.clone());
            continue;
        }
        let pkg = pkg.unwrap();

        // Check if already held
        if db.is_package_held(name)? {
            already_held.push(name.clone());
            continue;
        }

        // Hold at current version
        db.hold_package(name, Some(&pkg.version), reason_text)?;
        held_count += 1;

        println!(
            "  {} {} held at version {}",
            "✓".green(),
            name.bold(),
            pkg.version.cyan()
        );

        if !reason_text.is_empty() {
            println!("    Reason: {}", reason_text.dimmed());
        }
    }

    println!();

    if !not_installed.is_empty() {
        println!("{}", "Not installed (cannot hold):".yellow());
        for name in &not_installed {
            println!("  {} {}", "!".yellow(), name);
        }
        println!();
    }

    if !already_held.is_empty() {
        println!("{}", "Already held:".yellow());
        for name in &already_held {
            println!("  {} {}", "!".yellow(), name);
        }
        println!();
    }

    if held_count > 0 {
        println!(
            "{} {} package(s) held",
            "✓".green().bold(),
            held_count
        );
    } else if not_installed.is_empty() && already_held.is_empty() {
        println!("{}", "No packages to hold.".yellow());
    }

    Ok(())
}

/// Unhold a package (allow automatic upgrades again)
pub fn unhold(packages: &[String], config: &Config) -> Result<()> {
    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    println!("{}", "Unholding packages...".cyan());
    println!();

    let mut unheld_count = 0;
    let mut not_held = Vec::new();

    for name in packages {
        if !db.is_package_held(name)? {
            not_held.push(name.clone());
            continue;
        }

        db.unhold_package(name)?;
        unheld_count += 1;

        println!(
            "  {} {} released from hold",
            "✓".green(),
            name.bold()
        );
    }

    println!();

    if !not_held.is_empty() {
        println!("{}", "Not held (nothing to unhold):".yellow());
        for name in &not_held {
            println!("  {} {}", "!".yellow(), name);
        }
        println!();
    }

    if unheld_count > 0 {
        println!(
            "{} {} package(s) released from hold",
            "✓".green().bold(),
            unheld_count
        );
    } else if not_held.is_empty() {
        println!("{}", "No packages to unhold.".yellow());
    }

    Ok(())
}

/// Show detailed info about a specific held package
pub fn show_hold(name: &str, config: &Config) -> Result<()> {
    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    match db.get_hold_info(name)? {
        Some(hold) => {
            let version_str = hold.version.as_deref().unwrap_or("(any version)");
            let date = Utc.timestamp_opt(hold.held_date, 0)
                .single()
                .map(|d| d.format("%Y-%m-%d %H:%M:%S").to_string())
                .unwrap_or_else(|| "unknown".to_string());

            println!("{} {}", "Package:".bold(), hold.name.cyan());
            println!("{} {}", "Held at:".bold(), version_str);
            println!("{} {}", "Since:".bold(), date);
            if !hold.reason.is_empty() {
                println!("{} {}", "Reason:".bold(), hold.reason);
            }
        }
        None => {
            println!("Package '{}' is not held.", name);
        }
    }

    Ok(())
}

/// List all held packages
pub fn list_holds(config: &Config) -> Result<()> {
    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    let holds = db.list_held_packages()?;

    if holds.is_empty() {
        println!("{}", "No packages are held.".dimmed());
        println!();
        println!("To hold a package:");
        println!("  {} <package>", "rookpkg hold".bold());
        return Ok(());
    }

    println!("{}", "Held packages:".bold());
    println!();

    for hold in &holds {
        let version_str = hold.version.as_deref().unwrap_or("(any version)");
        let date = Utc.timestamp_opt(hold.held_date, 0)
            .single()
            .map(|d| d.format("%Y-%m-%d %H:%M").to_string())
            .unwrap_or_else(|| "unknown".to_string());

        println!(
            "  {} {} at {}",
            "→".cyan(),
            hold.name.bold(),
            version_str.cyan()
        );
        println!("    Held since: {}", date.dimmed());
        if !hold.reason.is_empty() {
            println!("    Reason: {}", hold.reason);
        }
    }

    println!();
    println!(
        "{} {} package(s) held",
        "→".cyan(),
        holds.len()
    );

    Ok(())
}
