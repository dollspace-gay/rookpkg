//! Checksum command implementation - fetch sources and compute/update checksums

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use colored::Colorize;

use crate::config::Config;
use crate::download::{compute_sha256, Downloader, SourceFile};
use crate::spec::PackageSpec;

/// Run the checksum command
pub fn run(spec_path: &Path, update: bool, config: &Config) -> Result<()> {
    // Parse spec file
    println!(
        "{} {}",
        "Parsing spec file:".cyan(),
        spec_path.display()
    );

    let spec = PackageSpec::from_file(spec_path)?;
    println!(
        "  {} {}-{}-{}",
        "✓".green(),
        spec.package.name,
        spec.package.version,
        spec.package.release
    );

    // Get all sources
    let sources = &spec.sources;
    if sources.is_empty() {
        println!("  {} No sources defined in spec file", "→".cyan());
        return Ok(());
    }

    println!();
    println!(
        "{} {} source(s)",
        "Fetching".cyan(),
        sources.len()
    );

    let downloader = Downloader::new(config)?;
    let mut updates: Vec<(String, String, String)> = Vec::new(); // (source_key, old_sha256, new_sha256)
    let mut any_fixme = false;

    for (key, source) in sources.iter() {
        let url = &source.url;
        let expected_sha256 = &source.sha256;

        println!();
        println!("  {} {}", "Source:".cyan().bold(), key);
        println!("    URL: {}", url);
        println!("    Expected: {}", expected_sha256);

        // Check if this is a placeholder
        let is_fixme = expected_sha256.eq_ignore_ascii_case("fixme")
            || expected_sha256.eq_ignore_ascii_case("todo")
            || expected_sha256.is_empty();

        if is_fixme {
            any_fixme = true;
        }

        // Create a source file for download (skip checksum verification for FIXME)
        let source_file = if is_fixme {
            // Download without verification
            SourceFile::new(url, "skip")
        } else {
            SourceFile::new(url, expected_sha256)
        };

        // Download the file (or use cached)
        let filename = source_file.get_filename();
        let cache_path = downloader.cache_dir().join(&filename);

        // For FIXME sources, download without verification
        let downloaded_path = if is_fixme {
            download_without_verify(&downloader, url, &cache_path)?
        } else {
            // Try to download with verification
            match downloader.download(&source_file) {
                Ok(path) => path,
                Err(e) => {
                    println!("    {} Download/verify failed: {}", "✗".red(), e);
                    continue;
                }
            }
        };

        // Compute actual checksum
        let actual_sha256 = compute_sha256(&downloaded_path)?;
        println!("    Computed: {}", actual_sha256.green());

        if is_fixme {
            println!("    {} Needs update (was FIXME)", "!".yellow());
            updates.push((key.clone(), expected_sha256.clone(), actual_sha256));
        } else if actual_sha256.eq_ignore_ascii_case(expected_sha256) {
            println!("    {} Checksum matches", "✓".green());
        } else {
            println!("    {} Checksum mismatch!", "✗".red());
            updates.push((key.clone(), expected_sha256.clone(), actual_sha256));
        }
    }

    // Summary
    println!();
    println!("{}", "═".repeat(60));

    if updates.is_empty() {
        println!(
            "{} All checksums are correct!",
            "✓".green().bold()
        );
        return Ok(());
    }

    println!(
        "{} {} checksum(s) need updating:",
        "!".yellow().bold(),
        updates.len()
    );

    for (key, old, new) in &updates {
        println!("  {} {}: {} → {}", "→".cyan(), key, old.dimmed(), new.green());
    }

    // Update the spec file if requested
    if update {
        println!();
        println!("{}", "Updating spec file...".cyan());

        update_spec_checksums(spec_path, &updates)?;

        println!(
            "  {} Updated {} checksum(s) in {}",
            "✓".green(),
            updates.len(),
            spec_path.display()
        );
    } else if any_fixme {
        println!();
        println!(
            "{} Run with {} to update the spec file",
            "Tip:".yellow().bold(),
            "--update".cyan()
        );
    }

    Ok(())
}

/// Run checksum on all spec files in a directory
pub fn run_all(
    spec_dir: &Path,
    update: bool,
    continue_on_error: bool,
    config: &Config,
) -> Result<()> {
    // Find all .rook files
    if !spec_dir.exists() {
        bail!("Spec directory not found: {}", spec_dir.display());
    }
    if !spec_dir.is_dir() {
        bail!("Path is not a directory: {}", spec_dir.display());
    }

    let mut spec_files: Vec<_> = fs::read_dir(spec_dir)?
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            entry.path().extension().map_or(false, |ext| ext == "rook")
        })
        .map(|entry| entry.path())
        .collect();

    if spec_files.is_empty() {
        bail!("No .rook spec files found in {}", spec_dir.display());
    }

    spec_files.sort();

    println!(
        "{} {} spec files in {}",
        "Found".cyan(),
        spec_files.len(),
        spec_dir.display()
    );
    println!();

    let mut success_count = 0;
    let mut fail_count = 0;
    let mut updated_count = 0;

    for (index, spec_path) in spec_files.iter().enumerate() {
        let spec_name = spec_path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "unknown".to_string());

        println!(
            "[{}/{}] {} {}",
            index + 1,
            spec_files.len(),
            "Processing".cyan(),
            spec_name.bold()
        );

        match run(spec_path, update, config) {
            Ok(()) => {
                success_count += 1;
                if update {
                    updated_count += 1;
                }
            }
            Err(e) => {
                fail_count += 1;
                println!("  {} {}: {}", "✗".red(), spec_name, e);

                if !continue_on_error {
                    bail!("Checksum failed for {}", spec_name);
                }
            }
        }

        println!();
    }

    // Summary
    println!("{}", "═".repeat(60));
    println!(
        "Total: {} succeeded, {} failed",
        success_count.to_string().green(),
        if fail_count > 0 {
            fail_count.to_string().red().to_string()
        } else {
            fail_count.to_string()
        }
    );

    if updated_count > 0 {
        println!(
            "  {} Updated checksums in {} spec file(s)",
            "✓".green(),
            updated_count
        );
    }

    Ok(())
}

/// Download a file without checksum verification
fn download_without_verify(
    _downloader: &Downloader,
    url: &str,
    dest_path: &Path,
) -> Result<std::path::PathBuf> {
    use reqwest::blocking::Client;
    use std::fs::File;
    use std::io::{BufReader, Read, Write};
    use std::time::Duration;

    // Check if already cached
    if dest_path.exists() {
        println!("    {} Using cached file", "→".cyan());
        return Ok(dest_path.to_path_buf());
    }

    println!("    {} Downloading...", "→".cyan());

    let client = Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .timeout(Duration::from_secs(600))
        .user_agent(format!("rookpkg/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .context("Failed to create HTTP client")?;

    let response = client
        .get(url)
        .send()
        .with_context(|| format!("Failed to connect to: {}", url))?;

    if !response.status().is_success() {
        bail!("HTTP error {}: {}", response.status(), url);
    }

    // Create parent directory if needed
    if let Some(parent) = dest_path.parent() {
        fs::create_dir_all(parent)?;
    }

    // Download to temp file
    let temp_path = dest_path.with_extension("part");
    let mut file = File::create(&temp_path)
        .with_context(|| format!("Failed to create temp file: {}", temp_path.display()))?;

    let mut buffer = [0u8; 8192];
    let mut reader = BufReader::new(response);

    loop {
        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        file.write_all(&buffer[..bytes_read])?;
    }

    file.flush()?;
    drop(file);

    // Move to final location
    fs::rename(&temp_path, dest_path)?;

    println!("    {} Downloaded", "✓".green());
    Ok(dest_path.to_path_buf())
}

/// Update checksums in a spec file
fn update_spec_checksums(
    spec_path: &Path,
    updates: &[(String, String, String)],
) -> Result<()> {
    let content = fs::read_to_string(spec_path)
        .with_context(|| format!("Failed to read spec file: {}", spec_path.display()))?;

    let mut new_content = content.clone();

    for (key, _old_sha256, new_sha256) in updates {
        // Find the line containing this source key and update its sha256
        // Pattern: key = { url = "...", sha256 = "FIXME" }
        // We need to find the line starting with this key and replace the sha256 on that line

        // Use regex to find and replace the sha256 for this specific source key
        let pattern = format!(
            r#"({}\s*=\s*\{{\s*url\s*=\s*"[^"]*"\s*,\s*sha256\s*=\s*")([^"]*)("\s*\}})"#,
            regex::escape(key)
        );

        if let Ok(re) = regex::Regex::new(&pattern) {
            new_content = re.replace(&new_content, |caps: &regex::Captures| {
                format!("{}{}{}", &caps[1], new_sha256, &caps[3])
            }).to_string();
        } else {
            // Fallback: try line-by-line approach
            let lines: Vec<&str> = new_content.lines().collect();
            let mut result_lines = Vec::new();

            for line in lines {
                if line.trim_start().starts_with(key) && line.contains("sha256") {
                    // This line contains the source key, replace sha256 value
                    let updated = replace_sha256_in_line(line, new_sha256);
                    result_lines.push(updated);
                } else {
                    result_lines.push(line.to_string());
                }
            }
            new_content = result_lines.join("\n");
            // Preserve trailing newline if original had one
            if content.ends_with('\n') {
                new_content.push('\n');
            }
        }
    }

    fs::write(spec_path, &new_content)
        .with_context(|| format!("Failed to write spec file: {}", spec_path.display()))?;

    Ok(())
}

/// Replace sha256 value in a source line
fn replace_sha256_in_line(line: &str, new_sha256: &str) -> String {
    // Find sha256 = "..." and replace the value
    if let Some(start) = line.find("sha256") {
        if let Some(quote_start) = line[start..].find('"') {
            let abs_quote_start = start + quote_start + 1;
            if let Some(quote_end) = line[abs_quote_start..].find('"') {
                let abs_quote_end = abs_quote_start + quote_end;
                return format!(
                    "{}{}{}",
                    &line[..abs_quote_start],
                    new_sha256,
                    &line[abs_quote_end..]
                );
            }
        }
    }
    line.to_string()
}
