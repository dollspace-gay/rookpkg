//! Patch fetching and spec rewriting
//!
//! Fetches security patches from upstream sources and updates
//! .rook spec files with new patches and version bumps.

use super::database::{CveRecord, ReferenceType};
use super::matcher::VulnerablePackage;
use anyhow::{Context, Result};
use reqwest::blocking::Client;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Represents a downloadable patch
#[derive(Debug, Clone)]
pub struct PatchInfo {
    /// CVE this patch addresses
    pub cve_id: String,
    /// URL to download the patch
    pub url: String,
    /// Local filename for the patch
    pub filename: String,
    /// SHA256 checksum (computed after download)
    pub sha256: Option<String>,
    /// Description
    pub description: String,
}

/// Fetches patches from various sources
pub struct PatchFetcher {
    client: Client,
    /// Known patch sources by package
    patch_sources: HashMap<String, Vec<PatchSource>>,
}

#[derive(Debug, Clone)]
struct PatchSource {
    /// URL pattern with {version} and {cve} placeholders
    url_pattern: String,
    /// Source name (for logging)
    name: String,
}

impl PatchFetcher {
    /// Create a new patch fetcher
    pub fn new() -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(60))
            .user_agent("rookpkg/0.1.0 (Rookery OS Package Manager)")
            .build()
            .context("Failed to create HTTP client")?;

        let mut patch_sources = HashMap::new();

        // Common patch sources for popular packages
        patch_sources.insert(
            "openssl".to_string(),
            vec![PatchSource {
                url_pattern: "https://github.com/openssl/openssl/commit/{commit}.patch".to_string(),
                name: "OpenSSL GitHub".to_string(),
            }],
        );

        patch_sources.insert(
            "linux".to_string(),
            vec![PatchSource {
                url_pattern: "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/patch/?id={commit}".to_string(),
                name: "Linux Kernel Git".to_string(),
            }],
        );

        patch_sources.insert(
            "curl".to_string(),
            vec![PatchSource {
                url_pattern: "https://github.com/curl/curl/commit/{commit}.patch".to_string(),
                name: "curl GitHub".to_string(),
            }],
        );

        Ok(Self {
            client,
            patch_sources,
        })
    }

    /// Find patches for a vulnerable package
    pub fn find_patches(&self, vuln: &VulnerablePackage) -> Vec<PatchInfo> {
        let mut patches = Vec::new();

        for cve in &vuln.cves {
            // Look for patch references in the CVE data
            for reference in &cve.references {
                if matches!(reference.ref_type, ReferenceType::Patch) {
                    if let Some(patch) = self.patch_from_url(&reference.url, &cve.id) {
                        patches.push(patch);
                    }
                }
            }

            // Try to find patches from known sources
            if let Some(sources) = self.patch_sources.get(&vuln.name) {
                for source in sources {
                    if let Some(patch) = self.try_source(source, cve) {
                        patches.push(patch);
                    }
                }
            }
        }

        // Deduplicate by URL
        let mut seen = std::collections::HashSet::new();
        patches.retain(|p| seen.insert(p.url.clone()));

        patches
    }

    /// Create PatchInfo from a URL
    fn patch_from_url(&self, url: &str, cve_id: &str) -> Option<PatchInfo> {
        // Check if URL looks like a patch
        let is_patch = url.ends_with(".patch")
            || url.ends_with(".diff")
            || url.contains("/commit/")
            || url.contains("/patch/");

        if !is_patch {
            return None;
        }

        // Generate filename from URL
        let filename = url
            .split('/')
            .next_back()
            .unwrap_or("patch")
            .replace(['?', '&', '='], "_");

        let filename = if filename.ends_with(".patch") || filename.ends_with(".diff") {
            filename
        } else {
            format!("{}-{}.patch", cve_id, filename)
        };

        Some(PatchInfo {
            cve_id: cve_id.to_string(),
            url: url.to_string(),
            filename,
            sha256: None,
            description: format!("Security fix for {}", cve_id),
        })
    }

    /// Try to find a patch from a known source by extracting commit hash from CVE references
    fn try_source(&self, source: &PatchSource, cve: &CveRecord) -> Option<PatchInfo> {
        // Look for commit hashes in CVE references
        for reference in &cve.references {
            // Check if reference URL contains a commit hash
            if let Some(commit) = Self::extract_commit_hash(&reference.url) {
                // Build patch URL from template
                let patch_url = source.url_pattern.replace("{commit}", &commit);

                tracing::debug!(
                    "Found commit {} for {} from {}, trying {}",
                    commit, cve.id, source.name, patch_url
                );

                // Try to verify the URL exists with a HEAD request
                match self.client.head(&patch_url).send() {
                    Ok(resp) if resp.status().is_success() => {
                        return Some(PatchInfo {
                            cve_id: cve.id.clone(),
                            url: patch_url,
                            filename: format!("{}-{}.patch", cve.id, commit),
                            sha256: None,
                            description: format!("Security fix for {} from {}", cve.id, source.name),
                        });
                    }
                    _ => continue,
                }
            }
        }
        None
    }

    /// Extract a git commit hash from a URL
    fn extract_commit_hash(url: &str) -> Option<String> {
        // Match patterns like:
        // - https://github.com/foo/bar/commit/abc123def...
        // - https://gitlab.com/foo/bar/-/commit/abc123def...
        // - https://git.kernel.org/.../commit/?id=abc123def...

        // GitHub/GitLab style: /commit/HASH
        if let Some(idx) = url.find("/commit/") {
            let after = &url[idx + 8..];
            let hash: String = after.chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            if hash.len() >= 7 {
                return Some(hash);
            }
        }

        // Kernel.org style: ?id=HASH
        if let Some(idx) = url.find("?id=") {
            let after = &url[idx + 4..];
            let hash: String = after.chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            if hash.len() >= 7 {
                return Some(hash);
            }
        }

        None
    }

    /// Download a patch and compute its checksum
    pub fn download_patch(&self, patch: &mut PatchInfo, dest_dir: &Path) -> Result<PathBuf> {
        let dest_path = dest_dir.join(&patch.filename);

        tracing::info!("Downloading patch: {}", patch.url);

        let response = self
            .client
            .get(&patch.url)
            .send()
            .context("Failed to download patch")?;

        if !response.status().is_success() {
            anyhow::bail!("Patch download failed: {}", response.status());
        }

        let content = response.bytes()?;

        // Compute SHA256
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(&content);
        let hash = hasher.finalize();
        patch.sha256 = Some(hex::encode(hash));

        // Write to file
        fs::write(&dest_path, &content)?;

        Ok(dest_path)
    }

    /// Download all patches for a vulnerable package
    pub fn download_all_patches(
        &self,
        vuln: &VulnerablePackage,
        dest_dir: &Path,
    ) -> Result<Vec<PatchInfo>> {
        fs::create_dir_all(dest_dir)?;

        let mut patches = self.find_patches(vuln);
        let mut downloaded = Vec::new();

        for patch in &mut patches {
            match self.download_patch(patch, dest_dir) {
                Ok(_) => downloaded.push(patch.clone()),
                Err(e) => tracing::warn!("Failed to download {}: {}", patch.url, e),
            }
        }

        Ok(downloaded)
    }
}

/// Updates .rook spec files with security patches
pub struct SpecUpdater;

impl SpecUpdater {
    /// Update a spec file with new patches and bump the release
    pub fn update_spec(
        spec_path: &Path,
        patches: &[PatchInfo],
        bump_release: bool,
    ) -> Result<String> {
        let content = fs::read_to_string(spec_path)
            .context("Failed to read spec file")?;

        let mut spec: toml::Value = content.parse()
            .context("Failed to parse spec file")?;

        // Bump release number if requested
        if bump_release {
            if let Some(package) = spec.get_mut("package") {
                if let Some(release) = package.get_mut("release") {
                    if let Some(r) = release.as_integer() {
                        *release = toml::Value::Integer(r + 1);
                    }
                }
            }
        }

        // Add patches to the [patches] section
        let patches_table = spec
            .get_mut("patches")
            .and_then(|p| p.as_table_mut());

        if let Some(patches_table) = patches_table {
            for (i, patch) in patches.iter().enumerate() {
                let key = format!("patch{}", patches_table.len() + i);
                let mut patch_entry = toml::map::Map::new();
                patch_entry.insert(
                    "url".to_string(),
                    toml::Value::String(patch.url.clone()),
                );
                if let Some(ref sha256) = patch.sha256 {
                    patch_entry.insert(
                        "sha256".to_string(),
                        toml::Value::String(sha256.clone()),
                    );
                }
                patch_entry.insert(
                    "description".to_string(),
                    toml::Value::String(patch.description.clone()),
                );
                patches_table.insert(key, toml::Value::Table(patch_entry));
            }
        }

        // Add changelog entry
        Self::add_changelog_entry(&mut spec, patches)?;

        // Convert back to TOML string
        let updated = toml::to_string_pretty(&spec)
            .context("Failed to serialize spec")?;

        Ok(updated)
    }

    /// Add a changelog entry for the security update
    fn add_changelog_entry(spec: &mut toml::Value, patches: &[PatchInfo]) -> Result<()> {
        // Get version first before borrowing changelog mutably
        let version = spec
            .get("package")
            .and_then(|p| p.get("version"))
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();

        let changelog = spec
            .get_mut("changelog")
            .and_then(|c| c.as_array_mut());

        if let Some(changelog) = changelog {
            let mut entry = toml::map::Map::new();

            entry.insert("version".to_string(), toml::Value::String(version));
            entry.insert(
                "date".to_string(),
                toml::Value::String(chrono::Utc::now().format("%Y-%m-%d").to_string()),
            );
            entry.insert(
                "author".to_string(),
                toml::Value::String("rookpkg CVE auto-patcher".to_string()),
            );

            // Build changes array
            let mut changes = vec![toml::Value::String("Security update".to_string())];
            for patch in patches {
                changes.push(toml::Value::String(format!("Fix {}", patch.cve_id)));
            }
            entry.insert("changes".to_string(), toml::Value::Array(changes));

            // Insert at beginning
            changelog.insert(0, toml::Value::Table(entry));
        }

        Ok(())
    }

    /// Create a backup of the original spec file
    pub fn backup_spec(spec_path: &Path) -> Result<PathBuf> {
        let backup_path = spec_path.with_extension("rook.bak");
        fs::copy(spec_path, &backup_path)?;
        Ok(backup_path)
    }

    /// Write updated spec to file
    pub fn write_spec(spec_path: &Path, content: &str) -> Result<()> {
        fs::write(spec_path, content)?;
        Ok(())
    }

    /// Update a spec file to use a new upstream version
    pub fn update_version(
        spec_path: &Path,
        new_version: &str,
        new_source_url: &str,
        new_sha256: &str,
    ) -> Result<String> {
        let content = fs::read_to_string(spec_path)
            .context("Failed to read spec file")?;

        let mut spec: toml::Value = content.parse()
            .context("Failed to parse spec file")?;

        // Update version
        if let Some(package) = spec.get_mut("package") {
            if let Some(version) = package.get_mut("version") {
                *version = toml::Value::String(new_version.to_string());
            }
            // Reset release to 1 for new version
            if let Some(release) = package.get_mut("release") {
                *release = toml::Value::Integer(1);
            }
        }

        // Update source URL and checksum
        if let Some(sources) = spec.get_mut("sources") {
            if let Some(sources_table) = sources.as_table_mut() {
                if let Some(source0) = sources_table.get_mut("source0") {
                    if let Some(source_table) = source0.as_table_mut() {
                        source_table.insert(
                            "url".to_string(),
                            toml::Value::String(new_source_url.to_string()),
                        );
                        source_table.insert(
                            "sha256".to_string(),
                            toml::Value::String(new_sha256.to_string()),
                        );
                    }
                }
            }
        }

        // Add changelog entry
        let changelog = spec
            .get_mut("changelog")
            .and_then(|c| c.as_array_mut());

        if let Some(changelog) = changelog {
            let mut entry = toml::map::Map::new();
            entry.insert("version".to_string(), toml::Value::String(new_version.to_string()));
            entry.insert(
                "date".to_string(),
                toml::Value::String(chrono::Utc::now().format("%Y-%m-%d").to_string()),
            );
            entry.insert(
                "author".to_string(),
                toml::Value::String("rookpkg CVE auto-patcher".to_string()),
            );
            entry.insert(
                "changes".to_string(),
                toml::Value::Array(vec![
                    toml::Value::String(format!("Updated to version {}", new_version)),
                    toml::Value::String("Security update".to_string()),
                ]),
            );
            changelog.insert(0, toml::Value::Table(entry));
        }

        let updated = toml::to_string_pretty(&spec)
            .context("Failed to serialize spec")?;

        Ok(updated)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_patch_from_url() {
        let fetcher = PatchFetcher::new().unwrap();

        // GitHub commit URL
        let patch = fetcher.patch_from_url(
            "https://github.com/foo/bar/commit/abc123.patch",
            "CVE-2024-0001",
        );
        assert!(patch.is_some());
        let patch = patch.unwrap();
        assert_eq!(patch.cve_id, "CVE-2024-0001");
        assert!(patch.filename.ends_with(".patch"));

        // Non-patch URL
        let patch = fetcher.patch_from_url(
            "https://example.com/advisory.html",
            "CVE-2024-0001",
        );
        assert!(patch.is_none());
    }

    #[test]
    fn test_spec_updater_bump_release() {
        let spec_content = r#"
[package]
name = "test"
version = "1.0.0"
release = 1

[sources]
source0 = { url = "http://example.com/test.tar.gz", sha256 = "abc123" }

[patches]

[[changelog]]
version = "1.0.0"
date = "2024-01-01"
author = "test"
changes = ["Initial release"]
"#;

        // Write temp file
        let temp_dir = tempfile::tempdir().unwrap();
        let spec_path = temp_dir.path().join("test.rook");
        fs::write(&spec_path, spec_content).unwrap();

        let patches = vec![PatchInfo {
            cve_id: "CVE-2024-0001".to_string(),
            url: "http://example.com/fix.patch".to_string(),
            filename: "fix.patch".to_string(),
            sha256: Some("def456".to_string()),
            description: "Security fix".to_string(),
        }];

        let updated = SpecUpdater::update_spec(&spec_path, &patches, true).unwrap();

        // Check release was bumped
        assert!(updated.contains("release = 2"));

        // Check patch was added
        assert!(updated.contains("CVE-2024-0001"));
    }
}
