//! Delta package CLI commands
//!
//! This module implements the CLI interface for delta package operations:
//! - Building delta packages between two package versions
//! - Applying delta packages to upgrade packages
//! - Inspecting delta package contents
//! - Managing repository delta indexes

use std::path::Path;

use anyhow::{bail, Context, Result};
use colored::Colorize;

use crate::config::Config;
use crate::delta::{DeltaApplier, DeltaBuilder, DeltaInfo, RepoDeltaIndex};
use crate::signing::{self, HybridSignature, LoadedPublicKey};

/// Build a delta package between two versions of a package
pub fn build(old_package: &Path, new_package: &Path, output_dir: &Path, _config: &Config) -> Result<()> {
    // Validate input files exist
    if !old_package.exists() {
        bail!("Old package not found: {}", old_package.display());
    }
    if !new_package.exists() {
        bail!("New package not found: {}", new_package.display());
    }

    println!(
        "{} {} -> {}",
        "Building delta:".cyan().bold(),
        old_package.file_name().unwrap_or_default().to_string_lossy(),
        new_package.file_name().unwrap_or_default().to_string_lossy()
    );

    // Create output directory if needed
    if !output_dir.exists() {
        std::fs::create_dir_all(output_dir)
            .with_context(|| format!("Failed to create output directory: {}", output_dir.display()))?;
    }

    // Build the delta
    let builder = DeltaBuilder::new(old_package, new_package)?;
    let delta_path = builder.build(output_dir)?;

    // Read delta info for statistics
    let delta_size = std::fs::metadata(&delta_path)
        .map(|m| m.len())
        .unwrap_or(0);
    let old_size = std::fs::metadata(old_package)
        .map(|m| m.len())
        .unwrap_or(0);
    let new_size = std::fs::metadata(new_package)
        .map(|m| m.len())
        .unwrap_or(0);

    let savings = if new_size > 0 {
        100.0 - (delta_size as f64 / new_size as f64 * 100.0)
    } else {
        0.0
    };

    println!();
    println!("{}", "Delta package created successfully!".green().bold());
    println!();
    println!("  {}: {}", "Output".cyan(), delta_path.display());
    println!("  {}: {}", "Old package size".cyan(), format_size(old_size));
    println!("  {}: {}", "New package size".cyan(), format_size(new_size));
    println!("  {}: {}", "Delta size".cyan(), format_size(delta_size));
    println!(
        "  {}: {:.1}%",
        "Size savings".cyan(),
        savings
    );

    if savings < 10.0 {
        println!();
        println!(
            "{} Delta provides minimal savings ({:.1}%). Consider distributing the full package instead.",
            "Note:".yellow().bold(),
            savings
        );
    }

    Ok(())
}

/// Apply a delta package to upgrade from old to new version
pub fn apply(
    old_package: &Path,
    delta_file: &Path,
    output_dir: &Path,
    config: &Config,
) -> Result<()> {
    // Validate input files exist
    if !old_package.exists() {
        bail!("Old package not found: {}", old_package.display());
    }
    if !delta_file.exists() {
        bail!("Delta file not found: {}", delta_file.display());
    }

    println!(
        "{} {} + {}",
        "Applying delta:".cyan().bold(),
        old_package.file_name().unwrap_or_default().to_string_lossy(),
        delta_file.file_name().unwrap_or_default().to_string_lossy()
    );

    // CRITICAL: Verify delta signature before applying
    println!("{}", "Verifying delta signature...".cyan());
    let sig_path = delta_file.with_extension("rookdelta.sig");

    if !sig_path.exists() {
        bail!(
            "Delta signature file not found: {}\n\
            All delta packages MUST be signed with a trusted key.\n\
            Contact the package maintainer to sign this delta.",
            sig_path.display()
        );
    }

    // Read and parse signature
    let sig_content = std::fs::read_to_string(&sig_path)
        .with_context(|| format!("Failed to read signature file: {}", sig_path.display()))?;
    let signature: HybridSignature = serde_json::from_str(&sig_content)
        .with_context(|| "Failed to parse delta signature file")?;

    // Find the signing key
    let public_key = find_signing_key(&signature.fingerprint, config)?;

    // Read delta content for verification
    let delta_content = std::fs::read(delta_file)
        .with_context(|| "Failed to read delta file for verification")?;

    // Verify the signature
    signing::verify_signature(&public_key, &delta_content, &signature)
        .with_context(|| "Delta signature verification failed - file may be tampered!")?;

    println!(
        "  {} Signature verified: {} <{}>",
        "✓".green(),
        public_key.name.cyan(),
        public_key.email.dimmed()
    );
    println!(
        "    Trust level: {:?}",
        public_key.trust_level
    );

    // Create output directory if needed
    if !output_dir.exists() {
        std::fs::create_dir_all(output_dir)
            .with_context(|| format!("Failed to create output directory: {}", output_dir.display()))?;
    }

    // Apply the delta
    let applier = DeltaApplier::new(old_package, delta_file)?;

    // Show delta info before applying
    let delta_info = applier.info();
    println!(
        "  {} Upgrading {} from {}-{} to {}-{}",
        "→".cyan(),
        delta_info.name.bold(),
        delta_info.old_version,
        delta_info.old_release,
        delta_info.new_version,
        delta_info.new_release
    );

    let new_package = applier.apply(output_dir)?;

    let new_size = std::fs::metadata(&new_package)
        .map(|m| m.len())
        .unwrap_or(0);

    println!();
    println!("{}", "Delta applied successfully!".green().bold());
    println!();
    println!("  {}: {}", "Output".cyan(), new_package.display());
    println!("  {}: {}", "Package size".cyan(), format_size(new_size));

    Ok(())
}

/// Show information about a delta package
pub fn info(delta_file: &Path, _config: &Config) -> Result<()> {
    if !delta_file.exists() {
        bail!("Delta file not found: {}", delta_file.display());
    }

    // Read delta info
    let info = read_delta_info(delta_file)?;

    let delta_size = std::fs::metadata(delta_file)
        .map(|m| m.len())
        .unwrap_or(0);

    println!("{}", "Delta Package Information".cyan().bold());
    println!();
    println!("  {}: {}", "Package".white().bold(), info.name);
    println!(
        "  {}: {}-{} -> {}-{}",
        "Version".cyan(),
        info.old_version,
        info.old_release,
        info.new_version,
        info.new_release
    );
    println!("  {}: {}", "Architecture".cyan(), info.arch);
    println!();
    println!("{}", "Checksums".cyan().bold());
    println!("  {}: {}", "Old SHA256".cyan(), &info.old_sha256[..16]);
    println!("  {}: {}", "New SHA256".cyan(), &info.new_sha256[..16]);
    println!();
    println!("{}", "Sizes".cyan().bold());
    println!("  {}: {}", "Old package".cyan(), format_size(info.old_size));
    println!("  {}: {}", "New package".cyan(), format_size(info.new_size));
    println!("  {}: {}", "Delta file".cyan(), format_size(delta_size));
    println!(
        "  {}: {:.1}%",
        "Savings".cyan(),
        info.savings_percent()
    );

    // Show if delta is worthwhile
    if info.is_worthwhile() {
        println!(
            "  {}: {}",
            "Recommendation".cyan(),
            "Use delta (significant savings)".green()
        );
    } else {
        println!(
            "  {}: {}",
            "Recommendation".cyan(),
            "Use full package (minimal savings)".yellow()
        );
    }

    println!();
    println!("{}", "Metadata".cyan().bold());
    println!("  {}: {:?}", "Algorithm".cyan(), info.algorithm);
    println!(
        "  {}: {}",
        "Created".cyan(),
        chrono::DateTime::from_timestamp(info.created, 0)
            .map(|dt| dt.format("%Y-%m-%d %H:%M:%S UTC").to_string())
            .unwrap_or_else(|| "Unknown".to_string())
    );

    Ok(())
}

/// Generate delta index for a repository
pub fn index(repo_dir: &Path, _config: &Config) -> Result<()> {
    println!(
        "{} {}",
        "Generating delta index for:".cyan().bold(),
        repo_dir.display()
    );

    let _packages_dir = repo_dir.join("packages");
    let deltas_dir = repo_dir.join("deltas");

    if !deltas_dir.exists() {
        println!("  No deltas directory found, creating empty index.");
        let index = RepoDeltaIndex::new();
        let index_path = repo_dir.join("deltas.json");
        let json = serde_json::to_string_pretty(&index)?;
        std::fs::write(&index_path, json)?;
        println!("  {} {}", "Created:".green(), index_path.display());
        return Ok(());
    }

    // Scan for delta files
    let mut index = RepoDeltaIndex::new();
    let mut count = 0;

    for entry in std::fs::read_dir(&deltas_dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.extension().and_then(|s| s.to_str()) == Some("rookdelta") {
            match read_delta_info(&path) {
                Ok(info) => {
                    let delta_entry = crate::delta::DeltaEntry {
                        from_version: info.old_version.clone(),
                        from_release: info.old_release,
                        to_version: info.new_version.clone(),
                        to_release: info.new_release,
                        filename: path
                            .file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .to_string(),
                        size: std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0),
                        sha256: crate::download::compute_sha256(&path).unwrap_or_default(),
                    };
                    index.add_delta(&info.name, delta_entry);
                    count += 1;
                    println!("  {} {}", "Added:".green(), path.file_name().unwrap_or_default().to_string_lossy());
                }
                Err(e) => {
                    println!(
                        "  {} {} - {}",
                        "Skipped:".yellow(),
                        path.file_name().unwrap_or_default().to_string_lossy(),
                        e
                    );
                }
            }
        }
    }

    // Write index
    let index_path = repo_dir.join("deltas.json");
    let json = serde_json::to_string_pretty(&index)?;
    std::fs::write(&index_path, json)?;

    println!();
    println!(
        "{} Indexed {} delta packages",
        "✓".green().bold(),
        count
    );
    println!("  {}: {}", "Index file".cyan(), index_path.display());

    Ok(())
}

/// Read delta info from a delta file
fn read_delta_info(delta_path: &Path) -> Result<DeltaInfo> {
    use std::io::Read;

    let file = std::fs::File::open(delta_path)?;
    let mut archive = tar::Archive::new(file);

    for entry in archive.entries()? {
        let mut entry = entry?;
        let path = entry.path()?.to_path_buf();

        if path.to_string_lossy() == ".DELTAINFO" {
            let mut contents = String::new();
            entry.read_to_string(&mut contents)?;
            let info: DeltaInfo = toml::from_str(&contents)?;
            return Ok(info);
        }
    }

    bail!("Delta file missing .DELTAINFO metadata")
}

/// Format file size as human-readable string
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

/// Find a signing key by fingerprint across all trusted key directories
///
/// Searches in order:
/// 1. Master keys (full trust)
/// 2. Packager keys (with certification check)
/// 3. User's own key (ultimate trust)
fn find_signing_key(fingerprint: &str, config: &Config) -> Result<LoadedPublicKey> {
    // Search in master keys (full trust - root of trust)
    if let Some(mut key) = search_key_in_dir(&config.signing.master_keys_dir, fingerprint)? {
        key.trust_level = signing::TrustLevel::Full;
        return Ok(key);
    }

    // Search in packager keys
    if let Some(mut key) = search_key_in_dir(&config.signing.packager_keys_dir, fingerprint)? {
        // Check if this packager key has a valid certification from a master key
        let cert_dir = config.signing.packager_keys_dir.join("certs");
        if let Ok(Some(cert)) = signing::find_certification_for_key(&key.fingerprint, &cert_dir) {
            // Try to find the certifying master key
            if let Some(master_key) = search_key_in_dir(&config.signing.master_keys_dir, &cert.certifier_key)? {
                // Verify the certification
                if signing::verify_certification(&cert, &key, &master_key).is_ok() {
                    key.trust_level = signing::TrustLevel::Full;
                    return Ok(key);
                }
            }
        }
        // No valid certification - marginal trust only
        key.trust_level = signing::TrustLevel::Marginal;
        return Ok(key);
    }

    // Check user's own key (ultimate trust)
    let user_pub_path = config
        .signing
        .user_signing_key
        .parent()
        .unwrap_or(Path::new("."))
        .join("signing-key.pub");

    if user_pub_path.exists() {
        if let Ok(mut key) = signing::load_public_key(&user_pub_path) {
            if key.fingerprint == fingerprint
                || key.fingerprint.ends_with(fingerprint)
                || fingerprint.ends_with(&key.fingerprint)
            {
                key.trust_level = signing::TrustLevel::Ultimate;
                return Ok(key);
            }
        }
    }

    bail!(
        "Signing key not found: {}\n\
        Trust the key with: rookpkg keytrust <key.pub>",
        fingerprint
    )
}

/// Search for a key by fingerprint in a directory
fn search_key_in_dir(dir: &Path, fingerprint: &str) -> Result<Option<LoadedPublicKey>> {
    if !dir.exists() {
        return Ok(None);
    }

    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().map(|e| e == "pub").unwrap_or(false) {
            if let Ok(key) = signing::load_public_key(&path) {
                if key.fingerprint == fingerprint
                    || key.fingerprint.ends_with(fingerprint)
                    || fingerprint.ends_with(&key.fingerprint)
                {
                    return Ok(Some(key));
                }
            }
        }
    }

    Ok(None)
}
