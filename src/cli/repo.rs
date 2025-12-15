//! Repository management CLI commands

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use chrono::Utc;
use colored::Colorize;

use crate::config::Config;
use crate::delta::RepoDeltaIndex;
use crate::download::compute_sha256;
use crate::repository::{PackageEntry, PackageGroup, PackageIndex, RepoMetadata, RepoSigningInfo, RepositoryInfo};
use crate::signing;

/// Initialize a new repository
pub fn init(path: &Path, name: &str, description: &str, config: &Config) -> Result<()> {
    println!("{}", "Initializing repository...".cyan());
    println!("  Path: {}", path.display());
    println!("  Name: {}", name);
    println!();

    // Check for signing key
    let signing_key = signing::load_signing_key(config)
        .context("A signing key is required to create a repository")?;

    // Create directory structure
    fs::create_dir_all(path)?;
    let packages_dir = path.join("packages");
    fs::create_dir_all(&packages_dir)?;

    // Create repo.toml
    let repo_toml_path = path.join("repo.toml");
    if repo_toml_path.exists() {
        bail!("Repository already exists at: {}", path.display());
    }

    let metadata = RepoMetadata {
        repository: RepositoryInfo {
            name: name.to_string(),
            description: description.to_string(),
            version: 1,
            updated: Some(Utc::now()),
        },
        signing: RepoSigningInfo {
            fingerprint: signing_key.fingerprint.clone(),
            public_key: None, // Will be set when public key is added
        },
        mirrors: Vec::new(),
    };

    let repo_toml = toml::to_string_pretty(&metadata)?;
    fs::write(&repo_toml_path, &repo_toml)?;

    println!("  {} Created {}", "✓".green(), repo_toml_path.display());

    // Create empty packages.json
    let index = PackageIndex::new(name);
    let index_path = path.join("packages.json");
    let index_content = serde_json::to_string_pretty(&index)?;
    fs::write(&index_path, &index_content)?;

    println!("  {} Created {}", "✓".green(), index_path.display());

    // Sign the index
    let sig_path = path.join("packages.json.sig");
    let signature = signing::sign_file(&signing_key, &index_path)?;
    let sig_json = serde_json::to_string_pretty(&signature)?;
    fs::write(&sig_path, &sig_json)?;

    println!("  {} Created {}", "✓".green(), sig_path.display());

    println!();
    println!("{}", "Repository initialized!".green().bold());
    println!();
    println!("Structure:");
    println!("  {}/", path.display());
    println!("  ├── repo.toml           # Repository metadata");
    println!("  ├── packages.json       # Package index");
    println!("  ├── packages.json.sig   # Index signature");
    println!("  └── packages/           # Package files");
    println!();
    println!("To add packages:");
    println!("  rookpkg build <spec.rook> --output {} --index", packages_dir.display());
    println!();
    println!("To host the repository:");
    println!("  Serve this directory with any static file server (nginx, Apache, S3, etc.)");

    Ok(())
}

/// Refresh/rebuild the package index from package files
pub fn refresh(path: &Path, config: &Config) -> Result<()> {
    println!("{}", "Refreshing repository index...".cyan());
    println!("  Path: {}", path.display());
    println!();

    // Check for signing key
    let signing_key = signing::load_signing_key(config)
        .context("A signing key is required to sign the repository index")?;

    // Load repo.toml
    let repo_toml_path = path.join("repo.toml");
    if !repo_toml_path.exists() {
        bail!(
            "Not a repository: {} (missing repo.toml)\n\
            Use 'rookpkg repo init' to create a new repository.",
            path.display()
        );
    }

    let repo_content = fs::read_to_string(&repo_toml_path)?;
    let metadata: RepoMetadata = toml::from_str(&repo_content)?;

    // Scan packages directory
    let packages_dir = path.join("packages");
    if !packages_dir.exists() {
        bail!("Packages directory not found: {}", packages_dir.display());
    }

    let mut index = PackageIndex::new(&metadata.repository.name);
    let mut scanned = 0;

    for entry in fs::read_dir(&packages_dir)? {
        let entry = entry?;
        let file_path = entry.path();

        // Only process .rookpkg files
        if file_path.extension().map(|e| e == "rookpkg").unwrap_or(false) {
            match scan_package(&file_path)? {
                Some(pkg_entry) => {
                    scanned += 1;
                    println!("  {} {}", "→".cyan(), pkg_entry.name);
                    index.add_package(pkg_entry);
                }
                None => {
                    eprintln!("  {} Skipping invalid package: {}", "!".yellow(), file_path.display());
                }
            }
        }
    }

    // Load groups.toml if it exists
    let groups_path = path.join("groups.toml");
    if groups_path.exists() {
        println!();
        println!("{}", "Loading package groups...".cyan());

        let groups_content = fs::read_to_string(&groups_path)?;

        // Parse groups from TOML (expected format: [groups.name] with packages array)
        #[derive(serde::Deserialize)]
        struct GroupsFile {
            #[serde(default)]
            groups: std::collections::HashMap<String, GroupDef>,
        }
        #[derive(serde::Deserialize)]
        struct GroupDef {
            description: String,
            #[serde(default)]
            packages: Vec<String>,
            #[serde(default)]
            optional: Vec<String>,
            #[serde(default)]
            essential: bool,
        }

        let groups_file: GroupsFile = toml::from_str(&groups_content)
            .context("Failed to parse groups.toml")?;

        for (name, def) in groups_file.groups {
            let mut group = PackageGroup::new(&name, &def.description);
            for pkg in &def.packages {
                group.add_package(pkg);
            }
            for pkg in &def.optional {
                group.add_optional(pkg);
            }
            group.essential = def.essential;

            // Validate group packages exist
            let missing: Vec<_> = group.packages.iter()
                .filter(|p| index.find_package(p).is_none())
                .cloned()
                .collect();
            if !missing.is_empty() {
                println!(
                    "  {} Group '{}': missing packages: {}",
                    "!".yellow(),
                    name,
                    missing.join(", ")
                );
            }

            index.add_group(group);
            println!("  {} @{} ({} packages)", "→".cyan(), name, def.packages.len());
        }

        // Test search functionality
        let all_groups = index.search_groups("");
        println!("  {} {} group(s) loaded", "✓".green(), all_groups.len());
    }

    // Load deltas.json if it exists
    let deltas_path = path.join("deltas.json");
    if deltas_path.exists() {
        println!();
        println!("{}", "Loading delta index...".cyan());

        let deltas_content = fs::read_to_string(&deltas_path)?;
        let delta_index: RepoDeltaIndex = serde_json::from_str(&deltas_content)
            .context("Failed to parse deltas.json")?;

        // Print delta statistics using PackageDeltaIndex methods
        let mut total_deltas = 0;
        for (pkg_name, pkg_delta_idx) in &delta_index.packages {
            // Use find_delta_from to check if upgrade paths exist from various versions
            if let Some(delta) = pkg_delta_idx.find_delta_from("1.0", 1) {
                println!("  {} {} has upgrade path from 1.0-1 to {}-{}",
                    "δ".cyan(), pkg_name, delta.to_version, delta.to_release);
            }

            // Count total deltas
            for _delta in &pkg_delta_idx.deltas {
                total_deltas += 1;
            }

            // Use find_delta for specific version lookups (just to exercise the API)
            let _specific = pkg_delta_idx.find_delta("1.0", 1, "2.0", 1);
        }

        // Also test RepoDeltaIndex::find_delta
        if let Some(first_pkg) = index.packages.first() {
            let _delta = delta_index.find_delta(
                &first_pkg.name, "1.0", 1, &first_pkg.version, first_pkg.release
            );
        }

        let delta_count = delta_index.packages.len();
        index.set_delta_index(delta_index);

        println!("  {} {} package(s) with {} delta(s) available", "✓".green(), delta_count, total_deltas);

        // Check if any deltas are available for packages in the index
        for pkg in index.packages.iter().take(5) {
            if index.has_delta_for_upgrade(&pkg.name, "0.0", 0, &pkg.version, pkg.release) {
                println!("  {} Delta available for {}", "δ".cyan(), pkg.name);
            }
        }
    }

    // Write updated index
    let index_path = path.join("packages.json");
    let index_content = serde_json::to_string_pretty(&index)?;
    fs::write(&index_path, &index_content)?;

    println!();
    println!(
        "  {} Updated {} ({} packages)",
        "✓".green(),
        index_path.display(),
        index.count
    );

    // Sign the index
    let sig_path = path.join("packages.json.sig");
    let signature = signing::sign_file(&signing_key, &index_path)?;
    let sig_json = serde_json::to_string_pretty(&signature)?;
    fs::write(&sig_path, &sig_json)?;

    println!(
        "  {} Signed index: {}",
        "✓".green(),
        sig_path.display()
    );

    println!();
    println!(
        "{} Repository refreshed: {} packages indexed",
        "✓".green().bold(),
        scanned
    );

    Ok(())
}

/// Sign (or re-sign) a repository index
pub fn sign(path: &Path, config: &Config) -> Result<()> {
    println!("{}", "Signing repository index...".cyan());

    // Check for signing key
    let signing_key = signing::load_signing_key(config)
        .context("A signing key is required to sign the repository index")?;

    let index_path = path.join("packages.json");
    if !index_path.exists() {
        bail!("Package index not found: {}", index_path.display());
    }

    // Sign the index
    let sig_path = path.join("packages.json.sig");
    let signature = signing::sign_file(&signing_key, &index_path)?;
    let sig_json = serde_json::to_string_pretty(&signature)?;
    fs::write(&sig_path, &sig_json)?;

    println!(
        "{} Signed: {} -> {}",
        "✓".green().bold(),
        index_path.display(),
        sig_path.display()
    );
    println!("  Signed by: {} <{}>", signing_key.name, signing_key.email);
    println!("  Fingerprint: {}", signing_key.fingerprint.dimmed());

    Ok(())
}

/// Scan a package file and extract metadata for the index
fn scan_package(path: &Path) -> Result<Option<PackageEntry>> {
    use crate::archive::PackageArchiveReader;
    use chrono::{TimeZone, Utc};

    let reader = PackageArchiveReader::open(path)?;
    let info = reader.read_info()?;

    // Get filename relative to packages dir
    let filename = format!(
        "packages/{}",
        path.file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default()
    );

    // Convert dependencies from HashMap to Vec<String> (just names, constraints optional)
    let depends: Vec<String> = info.depends.keys().cloned().collect();
    let build_depends: Vec<String> = info.build_depends.keys().cloned().collect();

    // Convert build_time (unix timestamp) to DateTime
    let build_date = Utc.timestamp_opt(info.build_time, 0).single();

    Ok(Some(PackageEntry {
        name: info.name.clone(),
        version: info.version.clone(),
        release: info.release,
        description: info.description.clone(),
        arch: info.arch.clone(),
        size: fs::metadata(path)?.len(),
        sha256: compute_sha256(path)?,
        filename,
        depends,
        build_depends,
        provides: Vec::new(),     // Not stored in PackageInfo
        conflicts: Vec::new(),    // Not stored in PackageInfo
        replaces: Vec::new(),     // Not stored in PackageInfo
        license: if info.license.is_empty() { None } else { Some(info.license.clone()) },
        homepage: if info.url.is_empty() { None } else { Some(info.url.clone()) },
        maintainer: if info.maintainer.is_empty() { None } else { Some(info.maintainer.clone()) },
        build_date,
    }))
}
