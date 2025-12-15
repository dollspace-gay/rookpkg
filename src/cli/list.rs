//! List command implementation

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;
use crate::package::AvailablePackage;
use crate::repository::RepoManager;

pub fn run(available: bool, filter: Option<&str>, all_versions: bool, config: &Config) -> Result<()> {
    if available {
        list_available(filter, all_versions, config)
    } else {
        list_installed(filter, config)
    }
}

fn list_installed(filter: Option<&str>, config: &Config) -> Result<()> {
    println!("{}", "Installed packages:".bold());
    println!();

    let db_path = &config.database.path;
    if !db_path.exists() {
        println!("  {}", "No packages installed yet.".dimmed());
        return Ok(());
    }

    let db = Database::open(&db_path)?;
    let packages = db.list_packages()?;

    if packages.is_empty() {
        println!("  {}", "No packages installed yet.".dimmed());
        return Ok(());
    }

    // Filter packages if needed
    let filtered: Vec<_> = if let Some(pattern) = filter {
        packages
            .iter()
            .filter(|p| p.name.contains(pattern))
            .collect()
    } else {
        packages.iter().collect()
    };

    if filtered.is_empty() {
        println!("  No packages match filter: {}", filter.unwrap_or("").cyan());
        return Ok(());
    }

    // Calculate column widths
    let max_name = filtered.iter().map(|p| p.name.len()).max().unwrap_or(0);
    let max_version = filtered
        .iter()
        .map(|p| p.full_version().len())
        .max()
        .unwrap_or(0);

    for pkg in &filtered {
        println!(
            "  {:<width_name$}  {:<width_ver$}  {}",
            pkg.name.bold(),
            pkg.full_version(),
            format_size(pkg.size_bytes).dimmed(),
            width_name = max_name,
            width_ver = max_version,
        );
    }

    println!();
    println!(
        "  {} package(s) installed",
        filtered.len().to_string().green()
    );

    Ok(())
}

fn list_available(filter: Option<&str>, all_versions: bool, config: &Config) -> Result<()> {
    println!("{}", "Available packages:".bold());
    println!();

    if config.repositories.is_empty() {
        println!("  {}", "No repositories configured.".yellow());
        println!();
        println!("Run {} to add repositories.", "rookpkg update".bold());
        return Ok(());
    }

    let mut manager = RepoManager::new(config)?;
    manager.load_caches()?;

    // Collect all available packages and convert to AvailablePackage
    let mut packages: Vec<(AvailablePackage, String, String)> = Vec::new();
    for repo in manager.enabled_repos() {
        if let Some(ref index) = repo.index {
            for pkg in &index.packages {
                // Use AvailablePackage for consistency with package.rs types
                let available = AvailablePackage::from_entry(pkg, &repo.url);
                // Keep description for search/display
                packages.push((available, repo.name.clone(), pkg.description.clone()));
            }
        }
    }

    if packages.is_empty() {
        println!("  {}", "No packages available.".dimmed());
        println!();
        println!("Run {} to update repository metadata.", "rookpkg update".bold());
        return Ok(());
    }

    // Sort by name
    packages.sort_by(|a, b| a.0.name.cmp(&b.0.name));

    // Filter packages if needed
    let filtered: Vec<_> = if let Some(pattern) = filter {
        packages
            .iter()
            .filter(|(p, _, desc)| p.name.contains(pattern) || desc.contains(pattern))
            .collect()
    } else {
        packages.iter().collect()
    };

    if filtered.is_empty() {
        println!("  No packages match filter: {}", filter.unwrap_or("").cyan());
        return Ok(());
    }

    // If all_versions is requested, show all versions for each package
    if all_versions {
        // Get unique package names
        let mut unique_names: Vec<&str> = filtered.iter().map(|(p, _, _)| p.name.as_str()).collect();
        unique_names.sort();
        unique_names.dedup();

        for name in &unique_names {
            println!("  {}:", name.bold());

            // Use PackageIndex::find_all_versions to get all versions from each repo
            for repo in manager.enabled_repos() {
                if let Some(ref index) = repo.index {
                    let versions = index.find_all_versions(name);
                    for pkg in versions {
                        println!(
                            "    {} {} [{}]",
                            "-".dimmed(),
                            format!("{}-{}", pkg.version, pkg.release),
                            repo.name.cyan()
                        );
                    }
                }
            }
        }

        println!();
        println!(
            "  {} unique package(s), {} version(s) total",
            unique_names.len().to_string().green(),
            filtered.len().to_string().green()
        );
    } else {
        // Calculate column widths
        let max_name = filtered.iter().map(|(p, _, _)| p.name.len()).max().unwrap_or(0);
        let max_version = filtered
            .iter()
            .map(|(p, _, _)| p.full_version().len())
            .max()
            .unwrap_or(0);

        for (pkg, repo, desc) in &filtered {
            println!(
                "  {:<width_name$}  {:<width_ver$}  {}  {}",
                pkg.name.bold(),
                pkg.full_version(),
                format!("[{}]", repo).dimmed(),
                truncate(desc, 40).dimmed(),
                width_name = max_name,
                width_ver = max_version,
            );
        }

        println!();
        println!(
            "  {} package(s) available",
            filtered.len().to_string().green()
        );
    }

    Ok(())
}

fn truncate(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else {
        format!("{}...", &s[..max_len - 3])
    }
}

fn format_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
