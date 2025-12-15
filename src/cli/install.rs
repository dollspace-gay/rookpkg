//! Install command implementation

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{bail, Result};
use colored::Colorize;
use pubgrub::range::Range;
use pubgrub::solver::resolve;
use pubgrub::version::SemanticVersion;

use crate::archive::PackageArchiveReader;
use crate::config::Config;
use crate::database::Database;
use crate::hooks::HookResult;
use crate::repository::{PackageEntry, RepoManager, SignatureStatus, VerifiedPackage};
use crate::resolver::{parse_constraint, Package, RookeryDependencyProvider};
use crate::signing::TrustLevel;
use crate::transaction::{ConflictType, Transaction};

pub fn run(packages: &[String], local: bool, dry_run: bool, download_only: bool, config: &Config) -> Result<()> {
    if dry_run {
        println!("{}", "Dry run mode - no changes will be made".yellow());
        println!();
    }

    if download_only {
        println!("{}", "Download-only mode - packages will be cached but not installed".yellow());
        println!();
    }

    // Handle local package installation
    if local {
        if download_only {
            println!("{}", "Note: --download-only has no effect with --local (files are already local)".yellow());
        }
        return run_local(packages, dry_run, config);
    }

    println!("{}", "Loading repository data...".cyan());

    // Initialize repository manager and load cached metadata
    let mut manager = RepoManager::new(config)?;

    // Check if we have any repos
    if config.repositories.is_empty() {
        println!();
        println!("{}", "No repositories configured.".yellow());
        println!("Run {} to add repositories.", "rookpkg update".bold());
        return Ok(());
    }

    // Load caches and show repo status
    manager.load_caches()?;

    // Show repo status using get_repo
    for repo_config in &config.repositories {
        if let Some(repo) = manager.get_repo(&repo_config.name) {
            let pkg_count = repo.index.as_ref().map(|i| i.count).unwrap_or(0);
            tracing::debug!(
                "Repository '{}': {} packages loaded from {}",
                repo.name,
                pkg_count,
                manager.package_cache_dir().display()
            );
        }
    }

    // Expand @group references to individual packages
    let expanded_packages = expand_groups(packages, &manager)?;

    println!("{}", "Resolving dependencies...".cyan());
    println!();

    // Build dependency provider from repository data
    let mut provider = RookeryDependencyProvider::new();
    let mut package_map: HashMap<String, (PackageEntry, String)> = HashMap::new();

    // Add all available packages to the provider
    for repo in manager.enabled_repos() {
        if let Some(ref index) = repo.index {
            for pkg in &index.packages {
                // Parse version
                let version = parse_version(&pkg.version);

                // Parse dependencies
                let mut deps = HashMap::new();
                for dep_str in &pkg.depends {
                    // Format: "name" or "name >= 1.0"
                    let (dep_name, constraint) = parse_dep_string(dep_str);
                    if let Ok(range) = parse_constraint(&constraint) {
                        deps.insert(dep_name.to_string(), range);
                    }
                }

                provider.add_package(&pkg.name, version, deps);
                package_map.insert(pkg.name.clone(), (pkg.clone(), repo.name.clone()));
            }
        }
    }

    // Find each requested package first
    let mut not_found = Vec::new();
    let mut root_packages = Vec::new();

    for package_name in &expanded_packages {
        if package_map.contains_key(package_name) {
            root_packages.push(package_name.clone());
        } else {
            println!("  {} {} {}", "✗".red(), package_name.bold(), "(not found)".red());
            not_found.push(package_name.clone());
        }
    }

    if !not_found.is_empty() {
        println!();
        println!(
            "{} {} package(s) not found:",
            "Error:".red().bold(),
            not_found.len()
        );
        for name in &not_found {
            println!("  - {}", name);
        }
        println!();
        println!("Try {} to refresh package lists.", "rookpkg update".bold());
        bail!("Some packages not found");
    }

    if root_packages.is_empty() {
        println!("{}", "Nothing to install.".yellow());
        return Ok(());
    }

    // Resolve dependencies using PubGrub
    println!("  Resolving dependency tree...");

    // Create a virtual root package that depends on all requested packages
    let mut root_deps: HashMap<String, Range<SemanticVersion>> = HashMap::new();
    for pkg_name in &root_packages {
        root_deps.insert(pkg_name.clone(), Range::any());
    }
    provider.add_package("__root__", SemanticVersion::new(1, 0, 0), root_deps);

    let solution = match resolve(&provider, Package("__root__".to_string()), SemanticVersion::new(1, 0, 0)) {
        Ok(sol) => sol,
        Err(e) => {
            println!();
            println!("{}", "Dependency resolution failed:".red().bold());
            println!("  {}", e);
            bail!("Could not resolve dependencies");
        }
    };

    // Build install list from solution (excluding virtual root)
    let mut to_install: Vec<(PackageEntry, String)> = Vec::new();
    for (pkg, _version) in &solution {
        if pkg.0 != "__root__" {
            if let Some((entry, repo)) = package_map.get(&pkg.0) {
                to_install.push((entry.clone(), repo.clone()));
            }
        }
    }

    // Show resolved packages
    let requested_set: std::collections::HashSet<_> = root_packages.iter().collect();
    for (pkg, repo) in &to_install {
        let is_dep = !requested_set.contains(&pkg.name);
        if is_dep {
            println!(
                "  {} {}-{} {} {} {}",
                "✓".green(),
                pkg.name.bold(),
                pkg.version,
                "from".dimmed(),
                repo.cyan(),
                "(dependency)".dimmed()
            );
        } else {
            println!(
                "  {} {}-{} {} {}",
                "✓".green(),
                pkg.name.bold(),
                pkg.version,
                "from".dimmed(),
                repo.cyan()
            );
        }
    }

    println!();

    if to_install.is_empty() {
        println!("{}", "Nothing to install.".yellow());
        return Ok(());
    }

    // Calculate total download size
    let total_size: u64 = to_install.iter().map(|(p, _)| p.size).sum();
    println!(
        "Total download size: {}",
        format_size(total_size).cyan()
    );
    println!();

    if dry_run {
        println!("{}", "Dry run complete - no packages downloaded.".yellow());
        return Ok(());
    }

    // Pre-download all packages to cache (batch download)
    // This uses download_packages for efficient parallel fetching
    tracing::debug!("Pre-downloading {} packages to cache", to_install.len());
    let download_list: Vec<(PackageEntry, String)> = to_install.clone();
    let _downloaded_paths = manager.download_packages(&download_list)?;

    // Download and verify packages
    println!("{}", "Downloading and verifying packages...".cyan());
    println!();

    let mut verified_packages: Vec<VerifiedPackage> = Vec::new();

    for (package, repo_name) in &to_install {
        // Check if package is already cached
        let cached_status = if manager.is_package_cached(package) {
            if let Some(cached_path) = manager.get_cached_package(package) {
                tracing::debug!("Package {} found in cache: {}", package.name, cached_path.display());
                "(cached)"
            } else {
                ""
            }
        } else {
            ""
        };

        print!(
            "  {} {}-{} {}... ",
            "↓".cyan(),
            package.name,
            package.version,
            cached_status.dimmed()
        );

        match manager.download_and_verify_package(package, repo_name, config) {
            Ok(verified) => {
                // Show download and verification result
                // Only Verified status can reach here - unsigned/unknown/invalid all bail
                if let SignatureStatus::Verified { signer, trust_level, .. } = &verified.signature_status {
                    let trust_color = match trust_level {
                        TrustLevel::Ultimate => "ultimate".green(),
                        TrustLevel::Full => "full".green(),
                        TrustLevel::Marginal => "marginal".yellow(),
                        TrustLevel::Unknown => "unknown".red(),
                    };
                    println!("{} [signed by {} ({})]", "✓".green(), signer.cyan(), trust_color);
                }

                verified_packages.push(verified);
            }
            Err(e) => {
                println!("{}", "✗".red());
                bail!("Failed to download/verify {}: {}", package.name, e);
            }
        }
    }

    println!();

    // Summary
    let verified_count = verified_packages.iter().filter(|p| p.is_verified()).count();
    let trusted_count = verified_packages.iter().filter(|p| p.is_trusted()).count();

    if verified_count == verified_packages.len() {
        println!(
            "{} All {} package(s) have valid signatures",
            "✓".green().bold(),
            verified_count
        );
        if trusted_count == verified_packages.len() {
            println!("  All signatures from trusted keys");
        }
    } else {
        let unsigned_count = verified_packages.len() - verified_count;
        println!(
            "{} {} of {} package(s) verified, {} unsigned/unknown",
            "!".yellow().bold(),
            verified_count,
            verified_packages.len(),
            unsigned_count
        );
    }

    println!();

    // Download-only mode: exit after downloading and verifying
    if download_only {
        println!(
            "{} {} package(s) downloaded to cache",
            "✓".green().bold(),
            verified_packages.len()
        );
        println!();
        println!("Cached packages:");
        for verified in &verified_packages {
            println!(
                "  {} {}",
                "→".cyan(),
                verified.path.display()
            );
        }
        println!();
        println!("To install these packages later, run:");
        println!("  {} {}", "rookpkg install".bold(), packages.join(" "));
        return Ok(());
    }

    // Install packages using transaction
    println!("{}", "Installing packages...".cyan());
    println!();

    // Open or create database
    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    // Check for already installed packages
    let mut already_installed = Vec::new();
    for verified in &verified_packages {
        if let Ok(Some(existing)) = db.get_package(&verified.package.name) {
            already_installed.push((verified.package.name.clone(), existing.version.clone()));
        }
    }

    // Filter out already installed packages
    let packages_to_install: Vec<_> = verified_packages
        .into_iter()
        .filter(|v| !already_installed.iter().any(|(n, _)| n == &v.package.name))
        .collect();

    if !already_installed.is_empty() {
        println!("{}", "Some packages are already installed:".yellow());
        for (name, version) in &already_installed {
            println!("  {} {} ({})", "!".yellow(), name.bold(), version);
        }
        println!();
        println!("Use {} to update existing packages.", "rookpkg upgrade".bold());
        println!();
    }

    if packages_to_install.is_empty() {
        println!("{}", "Nothing new to install.".yellow());
        return Ok(());
    }

    // Build transaction
    let root = Path::new("/");

    // Re-open database for transaction
    let db = Database::open(db_path)?;
    let mut tx = Transaction::new(root, db)?;

    for verified in &packages_to_install {
        let version = format!("{}-{}", verified.package.version, verified.package.release);
        tx.install(&verified.package.name, &version, &verified.path);
    }

    // Check for file conflicts before executing
    println!("{}", "Checking for file conflicts...".cyan());
    let conflicts = tx.check_conflicts(false)?;  // Don't check unowned files by default

    if !conflicts.is_empty() {
        println!();
        println!("{}", "File conflicts detected:".red().bold());
        println!();

        for conflict in &conflicts {
            let conflict_desc = match &conflict.conflict_with {
                ConflictType::InstalledPackage(pkg) => {
                    format!("owned by '{}'", pkg.cyan())
                }
                ConflictType::TransactionPackage(pkg) => {
                    format!("also installed by '{}'", pkg.cyan())
                }
                ConflictType::UnownedFile => {
                    "unowned file on filesystem".to_string()
                }
            };
            println!(
                "  {} {} ({})",
                "✗".red(),
                conflict.path.bold(),
                conflict_desc
            );
        }

        println!();
        bail!(
            "Cannot install: {} file conflict(s) detected. \
            Remove conflicting package(s) first.",
            conflicts.len()
        );
    }

    println!("  {} No conflicts found", "✓".green());
    println!();

    // Execute transaction with hooks
    match tx.execute_with_hooks(&config.hooks) {
        Ok((pre_results, post_results)) => {
            // Show hook execution summary
            print_hook_results("pre-transaction", &pre_results);

            println!(
                "{} {} package(s) installed successfully",
                "✓".green().bold(),
                packages_to_install.len()
            );

            print_hook_results("post-transaction", &post_results);
        }
        Err(e) => {
            println!(
                "{} Installation failed: {}",
                "✗".red().bold(),
                e
            );
            bail!("Installation transaction failed: {}", e);
        }
    }

    println!();
    println!("{}", "Installation complete!".green());

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

/// Parse a version string to SemanticVersion
fn parse_version(s: &str) -> SemanticVersion {
    let parts: Vec<&str> = s.split('.').collect();

    let major: u32 = parts
        .first()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    let minor: u32 = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);

    let patch: u32 = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);

    SemanticVersion::new(major, minor, patch)
}

/// Parse a dependency string like "name" or "name >= 1.0"
fn parse_dep_string(dep: &str) -> (&str, String) {
    // Try to find an operator
    for op in &[">=", "<=", "==", "!=", ">", "<", "="] {
        if let Some(pos) = dep.find(op) {
            let name = dep[..pos].trim();
            let constraint = dep[pos..].trim();
            return (name, constraint.to_string());
        }
    }
    // No operator found - name only, any version
    (dep.trim(), "*".to_string())
}

/// Expand @group references to individual packages
///
/// Package names starting with '@' are treated as group references.
/// For example: "@base-devel" expands to all packages in the "base-devel" group.
fn expand_groups(packages: &[String], manager: &RepoManager) -> Result<Vec<String>> {
    let mut expanded = Vec::new();
    let mut groups_found = Vec::new();

    for pkg in packages {
        if let Some(group_name) = pkg.strip_prefix('@') {
            // This is a group reference
            match manager.expand_group(group_name, false) {
                Some(group_packages) => {
                    groups_found.push((group_name.to_string(), group_packages.len()));
                    for gp in group_packages {
                        if !expanded.contains(&gp) {
                            expanded.push(gp);
                        }
                    }
                }
                None => {
                    bail!(
                        "Package group '{}' not found.\n\
                        Run {} to list available groups.",
                        group_name.cyan(),
                        "rookpkg groups".bold()
                    );
                }
            }
        } else {
            // Regular package name
            if !expanded.contains(pkg) {
                expanded.push(pkg.clone());
            }
        }
    }

    // Print group expansion summary
    if !groups_found.is_empty() {
        println!("{}", "Expanding package groups...".cyan());
        println!();
        for (name, count) in &groups_found {
            println!(
                "  {} @{} → {} package(s)",
                "→".cyan(),
                name.bold(),
                count
            );
        }
        println!();
    }

    Ok(expanded)
}

/// Install local .rookpkg files
fn run_local(packages: &[String], dry_run: bool, config: &Config) -> Result<()> {
    println!("{}", "Installing local package(s)...".cyan());
    println!();

    // Verify all files exist and are valid packages
    let mut to_install: Vec<(PathBuf, crate::archive::PackageInfo)> = Vec::new();

    for pkg_path in packages {
        let path = PathBuf::from(pkg_path);
        if !path.exists() {
            bail!("Package file not found: {}", pkg_path);
        }

        // Open and read package info
        let reader = PackageArchiveReader::open(&path)?;
        let info = reader.read_info()?;

        println!(
            "  {} {}-{}-{} ({})",
            "→".cyan(),
            info.name.bold(),
            info.version,
            info.release,
            format_size(std::fs::metadata(&path)?.len())
        );

        to_install.push((path, info));
    }

    println!();

    if to_install.is_empty() {
        println!("{}", "Nothing to install.".yellow());
        return Ok(());
    }

    if dry_run {
        println!("{}", "Dry run complete - no packages installed.".yellow());
        return Ok(());
    }

    // Open database
    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    // Check for already installed packages
    let mut already_installed = Vec::new();
    for (_, info) in &to_install {
        if let Ok(Some(existing)) = db.get_package(&info.name) {
            already_installed.push((info.name.clone(), existing.version.clone()));
        }
    }

    // Filter out already installed packages
    let packages_to_install: Vec<_> = to_install
        .into_iter()
        .filter(|(_, info)| !already_installed.iter().any(|(n, _)| n == &info.name))
        .collect();

    if !already_installed.is_empty() {
        println!("{}", "Some packages are already installed:".yellow());
        for (name, version) in &already_installed {
            println!("  {} {} ({})", "!".yellow(), name.bold(), version);
        }
        println!();
        println!("Use {} to update existing packages.", "rookpkg upgrade".bold());
        println!();
    }

    if packages_to_install.is_empty() {
        println!("{}", "Nothing new to install.".yellow());
        return Ok(());
    }

    // Install using transaction
    println!("{}", "Installing packages...".cyan());
    println!();

    let root = Path::new("/");

    // Re-open database for transaction
    let db = Database::open(db_path)?;
    let mut tx = Transaction::new(root, db)?;

    for (path, info) in &packages_to_install {
        let version = format!("{}-{}", info.version, info.release);
        tx.install(&info.name, &version, path);
    }

    // Check for file conflicts before executing
    println!("{}", "Checking for file conflicts...".cyan());
    let conflicts = tx.check_conflicts(false)?;

    if !conflicts.is_empty() {
        println!();
        println!("{}", "File conflicts detected:".red().bold());
        println!();

        for conflict in &conflicts {
            let conflict_desc = match &conflict.conflict_with {
                ConflictType::InstalledPackage(pkg) => {
                    format!("owned by '{}'", pkg.cyan())
                }
                ConflictType::TransactionPackage(pkg) => {
                    format!("also installed by '{}'", pkg.cyan())
                }
                ConflictType::UnownedFile => {
                    "unowned file on filesystem".to_string()
                }
            };
            println!(
                "  {} {} ({})",
                "✗".red(),
                conflict.path.bold(),
                conflict_desc
            );
        }

        println!();
        bail!(
            "Cannot install: {} file conflict(s) detected. \
            Remove conflicting package(s) first.",
            conflicts.len()
        );
    }

    println!("  {} No conflicts found", "✓".green());
    println!();

    // Execute transaction with hooks
    match tx.execute_with_hooks(&config.hooks) {
        Ok((pre_results, post_results)) => {
            print_hook_results("pre-transaction", &pre_results);

            println!(
                "{} {} package(s) installed successfully",
                "✓".green().bold(),
                packages_to_install.len()
            );

            print_hook_results("post-transaction", &post_results);
        }
        Err(e) => {
            println!(
                "{} Installation failed: {}",
                "✗".red().bold(),
                e
            );
            bail!("Installation transaction failed: {}", e);
        }
    }

    println!();
    println!("{}", "Installation complete!".green());

    Ok(())
}
