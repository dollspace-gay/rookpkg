//! CVE vulnerability audit command
//!
//! Scans installed packages against CVE databases (NVD, OSV)
//! and reports vulnerabilities with severity and fix information.

use anyhow::{Context, Result};
use colored::Colorize;

use crate::config::Config;
use crate::cve::{CveAuditor, ReferenceType, Severity, SpecUpdater, VulnerablePackage};
use crate::database::Database;

/// Run the audit command
pub fn run(
    fix: bool,
    json_output: bool,
    package: Option<&str>,
    cve_lookup: Option<&str>,
    clear_cache: bool,
    config: &Config,
) -> Result<()> {
    // Create auditor
    let mut auditor = CveAuditor::new(config)
        .context("Failed to initialize CVE auditor")?;

    // Clear cache if requested
    if clear_cache {
        println!("{} Clearing CVE database cache...", "🗑".cyan());
        auditor.clear_cache()?;
        println!("{} Cache cleared.\n", "✓".green());
    }

    // If looking up a specific CVE, just show that and return
    if let Some(cve_id) = cve_lookup {
        return lookup_cve(&auditor, cve_id, json_output);
    }

    // Open the database
    let db = Database::open(&config.database.path)
        .context("Failed to open package database")?;

    // Get installed packages
    let installed = if let Some(name) = package {
        // Audit specific package
        match db.get_package(name)? {
            Some(pkg) => vec![(pkg.name, pkg.version)],
            None => {
                println!("{} Package '{}' is not installed", "✗".red(), name);
                return Ok(());
            }
        }
    } else {
        // Audit all installed packages
        let pkgs = db.list_packages()?;
        pkgs.into_iter()
            .map(|p| (p.name, p.version))
            .collect()
    };

    if installed.is_empty() {
        println!("No packages installed.");
        return Ok(());
    }

    println!(
        "{} Auditing {} installed package(s) for vulnerabilities...\n",
        "🔍".cyan(),
        installed.len()
    );

    let result = auditor.audit(&installed)
        .context("Failed to complete vulnerability audit")?;

    // Output results
    if json_output {
        print_json_result(&result.vulnerable)?;
    } else {
        print_text_result(&result.vulnerable, &result.secure, &result.unknown);
    }

    // Summary
    println!();
    if result.has_vulnerabilities() {
        let severity_summary = format!(
            "{} critical, {} high, {} medium, {} low",
            result.critical_count,
            result.high_count,
            result.medium_count,
            result.low_count
        );

        if result.has_severe_vulnerabilities() {
            println!(
                "{} Found {} vulnerabilities in {} packages ({})",
                "⚠️".yellow().bold(),
                result.total_cves,
                result.vulnerable.len(),
                severity_summary
            );
        } else {
            println!(
                "{} Found {} vulnerabilities in {} packages ({})",
                "ℹ️".blue(),
                result.total_cves,
                result.vulnerable.len(),
                severity_summary
            );
        }

        if fix {
            println!();
            run_auto_fix(&result.vulnerable, &auditor, config)?;
        } else if result.has_severe_vulnerabilities() {
            println!();
            println!(
                "Run {} to attempt automatic patching.",
                "rookpkg audit --fix".green()
            );
        }
    } else {
        println!(
            "{} No known vulnerabilities found in {} packages",
            "✓".green().bold(),
            result.secure.len()
        );
    }

    if !result.unknown.is_empty() {
        println!();
        println!(
            "{} {} packages could not be checked (not in CVE databases)",
            "?".yellow(),
            result.unknown.len()
        );
    }

    Ok(())
}

/// Look up a specific CVE by ID
fn lookup_cve(auditor: &CveAuditor, cve_id: &str, json_output: bool) -> Result<()> {
    println!("{} Looking up {}...\n", "🔍".cyan(), cve_id.cyan());

    match auditor.get_cve(cve_id)? {
        Some(cve) => {
            if json_output {
                println!("{}", serde_json::to_string_pretty(&cve)?);
            } else {
                // Print detailed CVE info
                let severity_badge = match cve.severity {
                    Severity::Critical => "CRITICAL".on_red().white().bold(),
                    Severity::High => "HIGH".on_bright_red().white(),
                    Severity::Medium => "MEDIUM".on_yellow().black(),
                    Severity::Low => "LOW".on_blue().white(),
                    Severity::Unknown => "UNKNOWN".on_white().black(),
                };

                println!("{} {}", cve.id.cyan().bold(), severity_badge);

                if let Some(score) = cve.cvss_score {
                    println!("  CVSS Score: {:.1}", score);
                }

                println!();
                println!("{}", "Summary:".bold());
                println!("  {}", cve.summary);

                if !cve.description.is_empty() && cve.description != cve.summary {
                    println!();
                    println!("{}", "Description:".bold());
                    // Word wrap the description
                    for line in textwrap(&cve.description, 70) {
                        println!("  {}", line);
                    }
                }

                if let Some(ref fixed) = cve.fixed_version {
                    println!();
                    println!("{} {}", "Fixed in:".bold(), fixed.green());
                }

                if let Some(published) = cve.published {
                    println!();
                    println!("{} {}", "Published:".bold(), published.format("%Y-%m-%d"));
                }

                if !cve.references.is_empty() {
                    println!();
                    println!("{}", "References:".bold());
                    for reference in &cve.references {
                        let ref_type = match reference.ref_type {
                            ReferenceType::Patch => "[PATCH]".green(),
                            ReferenceType::Advisory => "[ADVISORY]".yellow(),
                            ReferenceType::Vendor => "[VENDOR]".blue(),
                            ReferenceType::Article => "[ARTICLE]".dimmed(),
                            ReferenceType::Other => "[OTHER]".dimmed(),
                        };
                        println!("  {} {}", ref_type, reference.url.dimmed());
                    }
                }

                println!();
                println!("{} {}", "Source:".bold(), cve.source);
            }
        }
        None => {
            println!("{} CVE {} not found in databases", "✗".red(), cve_id);
        }
    }

    Ok(())
}

/// Simple text wrapping helper
fn textwrap(s: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut current_line = String::new();

    for word in s.split_whitespace() {
        if current_line.is_empty() {
            current_line = word.to_string();
        } else if current_line.len() + 1 + word.len() <= width {
            current_line.push(' ');
            current_line.push_str(word);
        } else {
            lines.push(current_line);
            current_line = word.to_string();
        }
    }

    if !current_line.is_empty() {
        lines.push(current_line);
    }

    lines
}

/// Print results as JSON
fn print_json_result(vulnerable: &[VulnerablePackage]) -> Result<()> {
    #[derive(serde::Serialize)]
    struct JsonOutput {
        vulnerable_count: usize,
        packages: Vec<JsonVulnPackage>,
    }

    #[derive(serde::Serialize)]
    struct JsonVulnPackage {
        name: String,
        version: String,
        cve_count: usize,
        max_severity: String,
        recommended_version: Option<String>,
        cves: Vec<JsonCve>,
    }

    #[derive(serde::Serialize)]
    struct JsonCve {
        id: String,
        severity: String,
        cvss_score: Option<f64>,
        summary: String,
        fixed_version: Option<String>,
    }

    let packages: Vec<JsonVulnPackage> = vulnerable
        .iter()
        .map(|v| JsonVulnPackage {
            name: v.name.clone(),
            version: v.version.clone(),
            cve_count: v.cves.len(),
            max_severity: v.max_severity().to_string(),
            recommended_version: v.recommended_version.clone(),
            cves: v
                .cves
                .iter()
                .map(|c| JsonCve {
                    id: c.id.clone(),
                    severity: c.severity.to_string(),
                    cvss_score: c.cvss_score,
                    summary: c.summary.clone(),
                    fixed_version: c.fixed_version.clone(),
                })
                .collect(),
        })
        .collect();

    let output = JsonOutput {
        vulnerable_count: vulnerable.len(),
        packages,
    };

    println!("{}", serde_json::to_string_pretty(&output)?);
    Ok(())
}

/// Print results as formatted text
fn print_text_result(
    vulnerable: &[VulnerablePackage],
    secure: &[String],
    unknown: &[String],
) {
    // Show secure packages summary if any
    if !secure.is_empty() {
        println!(
            "{} {} package(s) have no known vulnerabilities\n",
            "✓".green(),
            secure.len()
        );
    }

    if vulnerable.is_empty() {
        return;
    }

    // Sort by max CVSS score (highest first), then by severity
    let mut sorted: Vec<_> = vulnerable.iter().collect();
    sorted.sort_by(|a, b| {
        // First compare by CVSS score (descending)
        let cvss_cmp = b.max_cvss().partial_cmp(&a.max_cvss());
        if let Some(std::cmp::Ordering::Equal) | None = cvss_cmp {
            // Fall back to severity comparison
            let sev_a = match a.max_severity() {
                Severity::Critical => 0,
                Severity::High => 1,
                Severity::Medium => 2,
                Severity::Low => 3,
                Severity::Unknown => 4,
            };
            let sev_b = match b.max_severity() {
                Severity::Critical => 0,
                Severity::High => 1,
                Severity::Medium => 2,
                Severity::Low => 3,
                Severity::Unknown => 4,
            };
            sev_a.cmp(&sev_b)
        } else {
            cvss_cmp.unwrap()
        }
    });

    for vuln in sorted {
        let severity_badge = match vuln.max_severity() {
            Severity::Critical => "CRITICAL".on_red().white().bold(),
            Severity::High => "HIGH".on_bright_red().white(),
            Severity::Medium => "MEDIUM".on_yellow().black(),
            Severity::Low => "LOW".on_blue().white(),
            Severity::Unknown => "UNKNOWN".on_white().black(),
        };

        // Show max CVSS score for the package
        let max_cvss_str = vuln
            .max_cvss()
            .map(|s| format!(" CVSS {:.1}", s))
            .unwrap_or_default();

        println!(
            "{}{} {} {} ({})",
            severity_badge,
            max_cvss_str.red().bold(),
            vuln.name.bold(),
            vuln.version.dimmed(),
            format!("{} CVE(s)", vuln.cves.len()).cyan()
        );

        for cve in &vuln.cves {
            let severity_color = match cve.severity {
                Severity::Critical => "CRIT".red().bold(),
                Severity::High => "HIGH".red(),
                Severity::Medium => "MED".yellow(),
                Severity::Low => "LOW".blue(),
                Severity::Unknown => "???".dimmed(),
            };

            let score = cve
                .cvss_score
                .map(|s| format!(" ({:.1})", s))
                .unwrap_or_default();

            println!(
                "  {} {}{}: {}",
                severity_color,
                cve.id.cyan(),
                score.dimmed(),
                truncate(&cve.summary, 60)
            );

            if let Some(ref fixed) = cve.fixed_version {
                println!("       Fixed in: {}", fixed.green());
            }

            // Show patch references
            let patches: Vec<_> = cve
                .references
                .iter()
                .filter(|r| matches!(r.ref_type, ReferenceType::Patch))
                .collect();

            if !patches.is_empty() {
                println!("       Patch: {}", patches[0].url.dimmed());
            }
        }

        if let Some(ref recommended) = vuln.recommended_version {
            println!(
                "  {} Upgrade to {}",
                "→".green(),
                recommended.green().bold()
            );
        }

        println!();
    }

    // Show unknown packages at the end
    if !unknown.is_empty() {
        println!(
            "{} {} package(s) not found in CVE databases:",
            "?".yellow(),
            unknown.len()
        );
        for pkg in unknown {
            println!("    {}", pkg.dimmed());
        }
        println!();
    }
}

/// Truncate a string to max length with ellipsis
fn truncate(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else {
        format!("{}...", &s[..max_len - 3])
    }
}

/// Attempt to automatically fix vulnerabilities by downloading patches
/// and updating .rook spec files
fn run_auto_fix(vulnerable: &[VulnerablePackage], auditor: &CveAuditor, config: &Config) -> Result<()> {
    println!("{} Attempting automatic fixes...\n", "🔧".cyan());

    let patcher = auditor.patcher();
    let patch_dir = config.paths.cache_dir.join("security-patches");
    std::fs::create_dir_all(&patch_dir)?;

    let mut patched_specs = Vec::new();
    let mut failed = Vec::new();

    for vuln in vulnerable {
        println!("{} Processing {}...", "→".cyan(), vuln.name.bold());

        // Skip if no patches available and no recommended version
        if !vuln.has_patch_available() && vuln.recommended_version.is_none() {
            println!(
                "  {} No patches or fixed versions available",
                "⚠".yellow()
            );
            failed.push((vuln.name.clone(), "No patches available".to_string()));
            continue;
        }

        // Look for spec file first
        let spec_path = config.paths.specs_dir.join(format!("{}.rook", vuln.name));
        if !spec_path.exists() {
            println!(
                "  {} Spec file not found at {}",
                "⚠".yellow(),
                spec_path.display()
            );
            failed.push((vuln.name.clone(), "Spec file not found".to_string()));
            continue;
        }

        // Create package-specific patch directory
        let pkg_patch_dir = patch_dir.join(&vuln.name);

        // Download all available patches
        let downloaded = patcher.download_all_patches(vuln, &pkg_patch_dir)?;

        if downloaded.is_empty() && vuln.recommended_version.is_none() {
            println!(
                "  {} Could not download any patches",
                "⚠".yellow()
            );
            failed.push((vuln.name.clone(), "Patch download failed".to_string()));
            continue;
        }

        if !downloaded.is_empty() {
            println!(
                "  {} Downloaded {} patch(es) to {}",
                "✓".green(),
                downloaded.len(),
                pkg_patch_dir.display()
            );

            for patch in &downloaded {
                println!(
                    "    {} {} ({})",
                    "→".cyan(),
                    patch.filename,
                    patch.cve_id.dimmed()
                );
            }

            // Backup the original spec file
            let backup_path = SpecUpdater::backup_spec(&spec_path)?;
            println!(
                "  {} Backed up spec to {}",
                "→".cyan(),
                backup_path.display().to_string().dimmed()
            );

            // Update the spec file with patches and bump release
            match SpecUpdater::update_spec(&spec_path, &downloaded, true) {
                Ok(updated_content) => {
                    SpecUpdater::write_spec(&spec_path, &updated_content)?;
                    println!(
                        "  {} Updated {} with {} patches, bumped release",
                        "✓".green(),
                        spec_path.display(),
                        downloaded.len()
                    );
                    patched_specs.push(vuln.name.clone());
                }
                Err(e) => {
                    println!(
                        "  {} Failed to update spec: {}",
                        "✗".red(),
                        e
                    );
                    failed.push((vuln.name.clone(), format!("Spec update failed: {}", e)));
                }
            }
        } else if let Some(ref new_version) = vuln.recommended_version {
            // No patches but there's a recommended version upgrade
            // Try to automatically update the version if we can construct the new URL
            println!(
                "  {} Attempting upgrade to {}...",
                "ℹ".blue(),
                new_version.green()
            );

            match try_version_upgrade(&spec_path, &vuln.version, new_version, config) {
                Ok(true) => {
                    println!(
                        "  {} Updated spec to version {}",
                        "✓".green(),
                        new_version.green().bold()
                    );
                    patched_specs.push(vuln.name.clone());
                }
                Ok(false) => {
                    println!(
                        "    {} Could not automatically determine new source URL",
                        "⚠".yellow()
                    );
                    println!(
                        "    Manual intervention needed: update source URL and checksum in spec"
                    );
                    failed.push((vuln.name.clone(), format!("Upgrade to {} required", new_version)));
                }
                Err(e) => {
                    println!(
                        "  {} Version upgrade failed: {}",
                        "✗".red(),
                        e
                    );
                    failed.push((vuln.name.clone(), format!("Version upgrade failed: {}", e)));
                }
            }
        }

        println!();
    }

    // Summary
    println!("{}", "─".repeat(60).dimmed());
    println!();

    if !patched_specs.is_empty() {
        println!(
            "{} {} package(s) patched successfully:",
            "✓".green().bold(),
            patched_specs.len()
        );
        for name in &patched_specs {
            println!("    {} {}", "→".green(), name);
        }
        println!();
        println!(
            "To rebuild patched packages, run:\n    {}",
            format!("rookpkg build {}", patched_specs.join(" ")).green()
        );
    }

    if !failed.is_empty() {
        println!();
        println!(
            "{} {} package(s) require manual intervention:",
            "⚠".yellow().bold(),
            failed.len()
        );
        for (name, reason) in &failed {
            println!("    {} {}: {}", "→".yellow(), name, reason.dimmed());
        }
    }

    Ok(())
}

/// Try to automatically upgrade a package to a new version
/// Returns Ok(true) if successful, Ok(false) if cannot auto-upgrade, Err on failure
fn try_version_upgrade(
    spec_path: &std::path::Path,
    old_version: &str,
    new_version: &str,
    _config: &Config,
) -> Result<bool> {
    use crate::spec::PackageSpec;

    // Read the spec to get the current source URL
    let spec = PackageSpec::from_file(spec_path)?;

    // Get the primary source URL
    let source = match spec.sources.get("source0") {
        Some(s) => s,
        None => return Ok(false), // No source0, can't auto-upgrade
    };

    // Try to construct new URL by replacing old version with new version
    let old_url = &source.url;
    let new_url = old_url.replace(old_version, new_version);

    if new_url == *old_url {
        // Version wasn't in URL, can't auto-construct
        return Ok(false);
    }

    println!(
        "    {} Trying new URL: {}",
        "→".cyan(),
        new_url.dimmed()
    );

    // Try to verify the new URL exists and download it
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    let response = client.head(&new_url).send();

    match response {
        Ok(resp) if resp.status().is_success() => {
            // URL exists, now download and compute checksum
            println!(
                "    {} URL is valid, downloading to compute checksum...",
                "✓".green()
            );

            let response = client.get(&new_url).send()?;
            if !response.status().is_success() {
                return Ok(false);
            }

            let content = response.bytes()?;

            // Compute SHA256
            use sha2::{Digest, Sha256};
            let mut hasher = Sha256::new();
            hasher.update(&content);
            let hash = hasher.finalize();
            let new_sha256 = hex::encode(hash);

            println!(
                "    {} Computed checksum: {}...",
                "✓".green(),
                &new_sha256[..16].dimmed()
            );

            // Backup the original spec file
            let backup_path = SpecUpdater::backup_spec(spec_path)?;
            println!(
                "    {} Backed up spec to {}",
                "→".cyan(),
                backup_path.display().to_string().dimmed()
            );

            // Update the spec file with new version
            let updated_content = SpecUpdater::update_version(
                spec_path,
                new_version,
                &new_url,
                &new_sha256,
            )?;

            SpecUpdater::write_spec(spec_path, &updated_content)?;

            Ok(true)
        }
        _ => {
            // URL doesn't exist or error
            Ok(false)
        }
    }
}
