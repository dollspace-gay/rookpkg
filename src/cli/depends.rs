//! Depends command implementation - show dependency tree

use anyhow::Result;
use colored::Colorize;

use std::collections::HashMap;

use crate::config::Config;
use crate::database::Database;
use crate::repository::RepoManager;
use crate::resolver::RookeryDependencyProvider;

pub fn run(package: &str, reverse: bool, config: &Config) -> Result<()> {
    if reverse {
        show_reverse_dependencies(package, config)
    } else {
        show_dependencies(package, config)
    }
}

fn show_dependencies(package: &str, config: &Config) -> Result<()> {
    println!("{} {}", "Dependencies of".bold(), package.cyan());
    println!();

    // First check installed packages
    let db_path = &config.database.path;
    if db_path.exists() {
        let db = Database::open(db_path)?;
        if let Some(_pkg) = db.get_package(package)? {
            let deps = db.get_dependencies(package)?;

            if deps.is_empty() {
                println!("  {} has no dependencies", package.cyan());
            } else {
                println!("  {}", "[installed]".green());
                for dep in &deps {
                    let installed = db.get_package(&dep.depends_on)?.is_some();
                    let status = if installed {
                        "✓".green()
                    } else {
                        "✗".red()
                    };

                    let constraint = if dep.constraint.is_empty() {
                        String::new()
                    } else {
                        format!(" ({})", dep.constraint)
                    };

                    println!(
                        "  {} {} {}{}",
                        status,
                        dep.depends_on.bold(),
                        format!("[{}]", dep.dep_type).dimmed(),
                        constraint.dimmed()
                    );
                }
            }

            return Ok(());
        }
    }

    // Check available packages from repositories
    let mut manager = RepoManager::new(config)?;
    manager.load_caches()?;

    // Build a dependency provider to check available versions
    let mut provider = RookeryDependencyProvider::new();
    for repo in manager.enabled_repos() {
        if let Some(ref index) = repo.index {
            for pkg in &index.packages {
                // Parse version for semver
                let parts: Vec<u32> = pkg.version.split('.').filter_map(|s| s.parse().ok()).collect();
                let version = pubgrub::version::SemanticVersion::new(
                    parts.first().copied().unwrap_or(0),
                    parts.get(1).copied().unwrap_or(0),
                    parts.get(2).copied().unwrap_or(0),
                );
                provider.add_package(&pkg.name, version, HashMap::new());
            }
        }
    }

    if let Some(result) = manager.find_package(package) {
        let pkg = &result.package;

        if pkg.depends.is_empty() {
            println!("  {} has no dependencies", package.cyan());
        } else {
            println!("  {} [{}]", "[available]".yellow(), result.repository.cyan());
            for dep in &pkg.depends {
                // Parse dependency string like "name" or "name >= 1.0"
                let (dep_name, constraint_str) = if let Some(pos) = dep.find(|c: char| c == '>' || c == '<' || c == '=') {
                    (&dep[..pos].trim(), dep[pos..].trim().to_string())
                } else {
                    (&dep.trim(), String::new())
                };

                // Check available versions using get_versions
                let version_info = if let Some(versions) = provider.get_versions(dep_name) {
                    let count = versions.len();
                    format!("{} version(s) available", count)
                } else {
                    "not available".to_string()
                };

                if constraint_str.is_empty() {
                    println!(
                        "  {} {} ({})",
                        "→".cyan(),
                        dep.bold(),
                        version_info.dimmed()
                    );
                } else {
                    println!(
                        "  {} {} {} ({})",
                        "→".cyan(),
                        dep_name.bold(),
                        constraint_str.dimmed(),
                        version_info.dimmed()
                    );
                }
            }
        }

        return Ok(());
    }

    println!("  {}", "Package not found.".red());
    println!();
    println!("  Try {} to refresh package lists.", "rookpkg update".bold());

    Ok(())
}

fn show_reverse_dependencies(package: &str, config: &Config) -> Result<()> {
    println!("{} {}", "Packages that depend on".bold(), package.cyan());
    println!();

    let db_path = &config.database.path;
    if !db_path.exists() {
        println!("  {}", "No packages installed.".dimmed());
        return Ok(());
    }

    let db = Database::open(db_path)?;

    // Check if package exists
    if db.get_package(package)?.is_none() {
        println!("  {} is not installed", package.cyan());
        println!();
        println!(
            "  Reverse dependencies can only be shown for installed packages."
        );
        return Ok(());
    }

    let rdeps = db.get_reverse_dependencies(package)?;

    if rdeps.is_empty() {
        println!(
            "  {} No installed packages depend on {}",
            "✓".green(),
            package.cyan()
        );
        println!();
        println!("  This package can be safely removed.");
    } else {
        println!(
            "  {} {} package(s) depend on {}:",
            "!".yellow(),
            rdeps.len(),
            package.cyan()
        );
        println!();

        for rdep in &rdeps {
            if let Some(pkg) = db.get_package(rdep)? {
                println!(
                    "  {} {}-{}",
                    "←".cyan(),
                    pkg.name.bold(),
                    pkg.full_version().dimmed()
                );
            } else {
                println!("  {} {}", "←".cyan(), rdep.bold());
            }
        }

        println!();
        println!(
            "  Use {} to also remove dependent packages.",
            "rookpkg remove --cascade".bold()
        );
    }

    Ok(())
}
