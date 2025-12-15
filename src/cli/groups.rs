//! Groups command implementation
//!
//! List available package groups from repositories.

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::repository::RepoManager;

/// Run the groups command
///
/// If `group_name` is provided, show details about that group.
/// Otherwise, list all available groups.
pub fn run(group_name: Option<&str>, config: &Config) -> Result<()> {
    // Initialize repository manager and load cached metadata
    let mut manager = RepoManager::new(config)?;

    // Check if we have any repos
    if config.repositories.is_empty() {
        println!("{}", "No repositories configured.".yellow());
        println!("Run {} to add repositories.", "rookpkg update".bold());
        return Ok(());
    }

    // Load caches
    manager.load_caches()?;

    if let Some(name) = group_name {
        // Show details for a specific group
        show_group(&manager, name)
    } else {
        // List all groups
        list_groups(&manager)
    }
}

/// List all available package groups
fn list_groups(manager: &RepoManager) -> Result<()> {
    let groups = manager.list_groups();

    if groups.is_empty() {
        println!("{}", "No package groups available.".yellow());
        println!();
        println!("Package groups are defined in repository metadata.");
        println!("Run {} to refresh repository data.", "rookpkg update".bold());
        return Ok(());
    }

    println!("{}", "Available package groups:".bold());
    println!();

    for result in &groups {
        let group = &result.group;
        let pkg_count = group.packages.len();
        let opt_count = group.optional.len();

        print!(
            "  {} @{}",
            "→".cyan(),
            group.name.bold()
        );

        if group.essential {
            print!(" {}", "(essential)".yellow());
        }

        println!();
        println!("    {}", group.description.dimmed());

        if opt_count > 0 {
            println!(
                "    {} packages: {} required, {} optional",
                pkg_count + opt_count,
                pkg_count,
                opt_count
            );
        } else {
            println!("    {} packages", pkg_count);
        }

        println!("    Repository: {}", result.repository.cyan());
        println!();
    }

    println!(
        "{} {} group(s) available",
        "→".cyan(),
        groups.len()
    );
    println!();
    println!("To install a group:");
    println!("  {} {}", "rookpkg install".bold(), "@group-name".cyan());
    println!();
    println!("To see packages in a group:");
    println!("  {} {}", "rookpkg groups".bold(), "group-name".cyan());

    Ok(())
}

/// Show details for a specific group
fn show_group(manager: &RepoManager, name: &str) -> Result<()> {
    match manager.find_group(name) {
        Some(result) => {
            let group = &result.group;

            println!("{} @{}", "Group:".bold(), group.name.cyan().bold());
            println!("{} {}", "Description:".bold(), group.description);
            println!("{} {}", "Repository:".bold(), result.repository);

            if group.essential {
                println!("{} {}", "Type:".bold(), "Essential (required for base system)".yellow());
            }

            println!();

            // Required packages
            if !group.packages.is_empty() {
                println!("{}", "Required packages:".bold());
                for pkg in &group.packages {
                    // Try to get package info
                    if let Some(pkg_info) = manager.find_package(pkg) {
                        println!(
                            "  {} {} - {}",
                            "•".green(),
                            pkg.bold(),
                            pkg_info.package.description.dimmed()
                        );
                    } else {
                        println!(
                            "  {} {} {}",
                            "•".yellow(),
                            pkg.bold(),
                            "(not in repository)".dimmed()
                        );
                    }
                }
                println!();
            }

            // Optional packages
            if !group.optional.is_empty() {
                println!("{}", "Optional packages:".bold());
                for pkg in &group.optional {
                    if let Some(pkg_info) = manager.find_package(pkg) {
                        println!(
                            "  {} {} - {}",
                            "○".dimmed(),
                            pkg,
                            pkg_info.package.description.dimmed()
                        );
                    } else {
                        println!(
                            "  {} {} {}",
                            "○".yellow(),
                            pkg,
                            "(not in repository)".dimmed()
                        );
                    }
                }
                println!();
            }

            // Summary
            let total = group.packages.len() + group.optional.len();
            println!(
                "{} {} package(s) in group ({} required, {} optional)",
                "→".cyan(),
                total,
                group.packages.len(),
                group.optional.len()
            );
            println!();
            println!("To install this group:");
            println!("  {} @{}", "rookpkg install".bold(), group.name);

            Ok(())
        }
        None => {
            bail!(
                "Package group '{}' not found.\n\n\
                Run {} to list available groups.",
                name.cyan(),
                "rookpkg groups".bold()
            );
        }
    }
}
