//! Repository management for rookpkg
//!
//! Handles remote package repositories, metadata synchronization, and mirror support.
//!
//! ## Repository Structure
//!
//! A repository is a directory (local or remote) containing:
//! - `repo.toml` - Repository metadata (name, description, signing key)
//! - `packages.json` - Package index (all available packages)
//! - `packages.json.sig` - Signature of the package index
//! - `packages/` - Directory containing .rookpkg files
//!
//! ## Repository Format
//!
//! repo.toml:
//! ```toml
//! [repository]
//! name = "rookery-core"
//! description = "Core packages for Rookery OS"
//! version = 1
//!
//! [signing]
//! fingerprint = "HYBRID:SHA256:..."
//! public_key = "path/to/key.pub or inline base64"
//!
//! [[mirrors]]
//! url = "https://packages.rookery.org/core"
//! priority = 1
//! ```

use std::fs::{self, File};
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::config::{Config, DownloadConfig};
use crate::delta::RepoDeltaIndex;
use crate::signing::{self, HybridSignature, LoadedPublicKey};

/// Repository metadata from repo.toml
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoMetadata {
    /// Repository information
    pub repository: RepositoryInfo,
    /// Signing configuration
    pub signing: RepoSigningInfo,
    /// Mirror list
    #[serde(default)]
    pub mirrors: Vec<Mirror>,
}

/// Basic repository information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepositoryInfo {
    /// Repository name (e.g., "rookery-core")
    pub name: String,
    /// Human-readable description
    pub description: String,
    /// Repository format version
    #[serde(default = "default_version")]
    pub version: u32,
    /// Last update timestamp
    #[serde(default)]
    pub updated: Option<DateTime<Utc>>,
}

fn default_version() -> u32 {
    1
}

/// Repository signing configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoSigningInfo {
    /// Fingerprint of the signing key
    pub fingerprint: String,
    /// Public key (path or inline base64)
    #[serde(default)]
    pub public_key: Option<String>,
}

/// A repository mirror
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Mirror {
    /// Mirror URL
    pub url: String,
    /// Priority (lower = higher priority)
    #[serde(default = "default_priority")]
    pub priority: u32,
    /// Geographic region (optional, for geo-selection)
    #[serde(default)]
    pub region: Option<String>,
    /// Is this mirror currently enabled?
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_priority() -> u32 {
    100
}

fn default_true() -> bool {
    true
}

/// A package group (meta-package) definition
///
/// Groups allow installing multiple related packages with a single command.
/// For example: `rookpkg install @base-devel` installs all development tools.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageGroup {
    /// Group name (e.g., "base-devel")
    pub name: String,
    /// Human-readable description
    pub description: String,
    /// List of packages in this group
    pub packages: Vec<String>,
    /// Optional packages (suggested but not required)
    #[serde(default)]
    pub optional: Vec<String>,
    /// Whether this is a required base system group
    #[serde(default)]
    pub essential: bool,
}

impl PackageGroup {
    /// Create a new package group
    pub fn new(name: &str, description: &str) -> Self {
        Self {
            name: name.to_string(),
            description: description.to_string(),
            packages: Vec::new(),
            optional: Vec::new(),
            essential: false,
        }
    }

    /// Add a required package to the group
    pub fn add_package(&mut self, name: &str) -> &mut Self {
        self.packages.push(name.to_string());
        self
    }

    /// Add an optional package to the group
    pub fn add_optional(&mut self, name: &str) -> &mut Self {
        self.optional.push(name.to_string());
        self
    }

    /// Get all packages (required + optional if include_optional is true)
    pub fn all_packages(&self, include_optional: bool) -> Vec<&str> {
        let mut pkgs: Vec<&str> = self.packages.iter().map(|s| s.as_str()).collect();
        if include_optional {
            pkgs.extend(self.optional.iter().map(|s| s.as_str()));
        }
        pkgs
    }
}

/// Package entry in the repository index
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageEntry {
    /// Package name
    pub name: String,
    /// Package version
    pub version: String,
    /// Release number
    #[serde(default = "default_release")]
    pub release: u32,
    /// Package description
    pub description: String,
    /// Package architecture (e.g., "x86_64", "noarch")
    #[serde(default = "default_arch")]
    pub arch: String,
    /// Size of the package file in bytes
    pub size: u64,
    /// SHA256 checksum of the package file
    pub sha256: String,
    /// Relative path to the package file
    pub filename: String,
    /// Runtime dependencies
    #[serde(default)]
    pub depends: Vec<String>,
    /// Build dependencies (for source packages)
    #[serde(default)]
    pub build_depends: Vec<String>,
    /// Packages this provides (virtual packages)
    #[serde(default)]
    pub provides: Vec<String>,
    /// Packages this conflicts with
    #[serde(default)]
    pub conflicts: Vec<String>,
    /// Packages this replaces
    #[serde(default)]
    pub replaces: Vec<String>,
    /// Package license
    #[serde(default)]
    pub license: Option<String>,
    /// Package homepage
    #[serde(default)]
    pub homepage: Option<String>,
    /// Package maintainer
    #[serde(default)]
    pub maintainer: Option<String>,
    /// Build date
    #[serde(default)]
    pub build_date: Option<DateTime<Utc>>,
}

fn default_release() -> u32 {
    1
}

fn default_arch() -> String {
    "x86_64".to_string()
}

/// Package index (packages.json)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageIndex {
    /// Index format version
    pub version: u32,
    /// When the index was generated
    pub generated: DateTime<Utc>,
    /// Repository name
    pub repository: String,
    /// Package count
    pub count: usize,
    /// All packages in the repository
    pub packages: Vec<PackageEntry>,
    /// Package groups defined in this repository
    #[serde(default)]
    pub groups: Vec<PackageGroup>,
    /// Delta package index (for incremental updates)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delta_index: Option<RepoDeltaIndex>,
}

impl PackageIndex {
    /// Create a new empty package index
    pub fn new(repository: &str) -> Self {
        Self {
            version: 1,
            generated: Utc::now(),
            repository: repository.to_string(),
            count: 0,
            packages: Vec::new(),
            groups: Vec::new(),
            delta_index: None,
        }
    }

    /// Add a package to the index
    pub fn add_package(&mut self, entry: PackageEntry) {
        self.packages.push(entry);
        self.count = self.packages.len();
        self.generated = Utc::now();
    }

    /// Add a package group to the index
    pub fn add_group(&mut self, group: PackageGroup) {
        self.groups.push(group);
        self.generated = Utc::now();
    }

    /// Find a package by name
    pub fn find_package(&self, name: &str) -> Option<&PackageEntry> {
        self.packages.iter().find(|p| p.name == name)
    }

    /// Find a package group by name
    pub fn find_group(&self, name: &str) -> Option<&PackageGroup> {
        self.groups.iter().find(|g| g.name == name)
    }

    /// Find all versions of a package
    pub fn find_all_versions(&self, name: &str) -> Vec<&PackageEntry> {
        self.packages.iter().filter(|p| p.name == name).collect()
    }

    /// Search packages by name or description
    pub fn search(&self, query: &str) -> Vec<&PackageEntry> {
        let query_lower = query.to_lowercase();
        self.packages
            .iter()
            .filter(|p| {
                p.name.to_lowercase().contains(&query_lower)
                    || p.description.to_lowercase().contains(&query_lower)
            })
            .collect()
    }

    /// Search groups by name or description
    pub fn search_groups(&self, query: &str) -> Vec<&PackageGroup> {
        let query_lower = query.to_lowercase();
        self.groups
            .iter()
            .filter(|g| {
                g.name.to_lowercase().contains(&query_lower)
                    || g.description.to_lowercase().contains(&query_lower)
            })
            .collect()
    }

    /// Set the delta index for this repository
    pub fn set_delta_index(&mut self, delta_index: RepoDeltaIndex) {
        self.delta_index = Some(delta_index);
        self.generated = Utc::now();
    }

    /// Find a delta for upgrading a package from one version to another
    pub fn find_delta(
        &self,
        package_name: &str,
        from_version: &str,
        from_release: u32,
        to_version: &str,
        to_release: u32,
    ) -> Option<&crate::delta::DeltaEntry> {
        self.delta_index.as_ref().and_then(|idx| {
            idx.find_delta(package_name, from_version, from_release, to_version, to_release)
        })
    }

    /// Check if a delta is available for a package upgrade
    pub fn has_delta_for_upgrade(
        &self,
        package_name: &str,
        from_version: &str,
        from_release: u32,
        to_version: &str,
        to_release: u32,
    ) -> bool {
        self.find_delta(package_name, from_version, from_release, to_version, to_release).is_some()
    }
}

/// A configured repository
pub struct Repository {
    /// Repository name
    pub name: String,
    /// Repository URL (base URL)
    pub url: String,
    /// Whether this repository is enabled
    pub enabled: bool,
    /// Repository priority (lower = higher priority)
    pub priority: u32,
    /// Local cache directory
    pub cache_dir: PathBuf,
    /// Cached repository metadata
    pub metadata: Option<RepoMetadata>,
    /// Cached package index
    pub index: Option<PackageIndex>,
    /// Repository public key
    pub public_key: Option<LoadedPublicKey>,
}

impl Repository {
    /// Create a new repository from config
    pub fn from_config(
        name: &str,
        url: &str,
        priority: u32,
        enabled: bool,
        cache_base: &Path,
    ) -> Self {
        let cache_dir = cache_base.join("repos").join(name);
        Self {
            name: name.to_string(),
            url: url.to_string(),
            enabled,
            priority,
            cache_dir,
            metadata: None,
            index: None,
            public_key: None,
        }
    }

    /// Check if the repository has cached metadata
    pub fn has_cache(&self) -> bool {
        self.cache_dir.join("repo.toml").exists()
            && self.cache_dir.join("packages.json").exists()
    }

    /// Load cached metadata
    pub fn load_cache(&mut self) -> Result<()> {
        let repo_path = self.cache_dir.join("repo.toml");
        let index_path = self.cache_dir.join("packages.json");

        if repo_path.exists() {
            let content = fs::read_to_string(&repo_path)?;
            self.metadata = Some(toml::from_str(&content)?);
        }

        if index_path.exists() {
            let content = fs::read_to_string(&index_path)?;
            self.index = Some(serde_json::from_str(&content)?);
        }

        Ok(())
    }

    /// Save metadata to cache
    pub fn save_cache(&self) -> Result<()> {
        fs::create_dir_all(&self.cache_dir)?;

        if let Some(ref metadata) = self.metadata {
            let content = toml::to_string_pretty(metadata)?;
            fs::write(self.cache_dir.join("repo.toml"), content)?;
        }

        if let Some(ref index) = self.index {
            let content = serde_json::to_string_pretty(index)?;
            fs::write(self.cache_dir.join("packages.json"), content)?;
        }

        Ok(())
    }

    /// Get the URL for a specific file in the repository
    pub fn file_url(&self, path: &str) -> String {
        format!("{}/{}", self.url.trim_end_matches('/'), path)
    }

    /// Get the URL for the repository metadata
    pub fn metadata_url(&self) -> String {
        self.file_url("repo.toml")
    }

    /// Get the URL for the package index
    pub fn index_url(&self) -> String {
        self.file_url("packages.json")
    }

    /// Get the URL for the package index signature
    pub fn index_sig_url(&self) -> String {
        self.file_url("packages.json.sig")
    }

    /// Get the URL for a package file
    pub fn package_url(&self, entry: &PackageEntry) -> String {
        self.file_url(&entry.filename)
    }
}

// NOTE: Download configuration (retries, timeouts) is now configured via Config.download
// See config.rs DownloadConfig struct for the configurable settings.

/// Repository manager handles all configured repositories
pub struct RepoManager {
    /// Configured repositories
    repos: Vec<Repository>,
    /// HTTP client for fetching
    client: reqwest::blocking::Client,
    /// Cache base directory
    cache_dir: PathBuf,
    /// Package cache directory
    pkg_cache_dir: PathBuf,
    /// Download configuration
    download_config: DownloadConfig,
}

impl RepoManager {
    /// Create a new repository manager from config
    pub fn new(config: &Config) -> Result<Self> {
        // Use config values for timeouts
        let connect_timeout = Duration::from_secs(config.download.connect_timeout_secs);
        let download_timeout = if config.download.download_timeout_secs == 0 {
            None
        } else {
            Some(Duration::from_secs(config.download.download_timeout_secs))
        };

        let mut client_builder = reqwest::blocking::Client::builder()
            .connect_timeout(connect_timeout)
            .user_agent(format!("rookpkg/{}", env!("CARGO_PKG_VERSION")));

        if let Some(timeout) = download_timeout {
            client_builder = client_builder.timeout(timeout);
        }

        let client = client_builder.build()?;

        let cache_dir = config.paths.cache_dir.clone();
        let pkg_cache_dir = cache_dir.join("packages");
        fs::create_dir_all(&pkg_cache_dir).ok();

        let mut repos = Vec::new();
        for repo_config in &config.repositories {
            let repo = Repository::from_config(
                &repo_config.name,
                &repo_config.url,
                repo_config.priority,
                repo_config.enabled,
                &cache_dir,
            );
            repos.push(repo);
        }

        // Sort by priority
        repos.sort_by_key(|r| r.priority);

        Ok(Self {
            repos,
            client,
            cache_dir,
            pkg_cache_dir,
            download_config: config.download.clone(),
        })
    }

    /// Get all enabled repositories
    pub fn enabled_repos(&self) -> impl Iterator<Item = &Repository> {
        self.repos.iter().filter(|r| r.enabled)
    }

    /// Get a repository by name
    pub fn get_repo(&self, name: &str) -> Option<&Repository> {
        self.repos.iter().find(|r| r.name == name)
    }

    /// Get a mutable repository by name
    pub fn get_repo_mut(&mut self, name: &str) -> Option<&mut Repository> {
        self.repos.iter_mut().find(|r| r.name == name)
    }

    /// Update all enabled repositories
    pub fn update_all(&mut self, config: &Config) -> Result<UpdateResult> {
        let mut result = UpdateResult::default();

        // Collect indices of enabled repos to avoid borrow issues
        let enabled_indices: Vec<usize> = self
            .repos
            .iter()
            .enumerate()
            .filter(|(_, r)| r.enabled)
            .map(|(i, _)| i)
            .collect();

        for idx in enabled_indices {
            let repo_name = self.repos[idx].name.clone();
            match self.update_repo_by_index(idx, config) {
                Ok(updated) => {
                    if updated {
                        result.updated.push(repo_name);
                    } else {
                        result.unchanged.push(repo_name);
                    }
                }
                Err(e) => {
                    result.failed.push((repo_name, e.to_string()));
                }
            }
        }

        Ok(result)
    }

    /// Update a repository by index
    fn update_repo_by_index(&mut self, idx: usize, config: &Config) -> Result<bool> {
        let repo = &self.repos[idx];
        let name = repo.name.clone();
        let metadata_url = repo.metadata_url();
        let index_url = repo.index_url();
        let sig_url = repo.index_sig_url();

        tracing::info!("Updating repository: {}", name);

        // Fetch repository metadata
        let metadata_response = self.client.get(&metadata_url).send()?;

        if !metadata_response.status().is_success() {
            bail!(
                "Failed to fetch repository metadata: HTTP {}",
                metadata_response.status()
            );
        }

        let metadata_content = metadata_response.text()?;
        let metadata: RepoMetadata = toml::from_str(&metadata_content)?;

        // Fetch package index
        let index_response = self.client.get(&index_url).send()?;

        if !index_response.status().is_success() {
            bail!(
                "Failed to fetch package index: HTTP {}",
                index_response.status()
            );
        }

        let index_content = index_response.text()?;

        // Fetch and verify signature
        let sig_response = self.client.get(&sig_url).send()?;

        let public_key = if sig_response.status().is_success() {
            let sig_content = sig_response.text()?;
            let signature: HybridSignature = serde_json::from_str(&sig_content)?;

            // Find the public key
            let public_key = self.find_repo_key(&metadata.signing.fingerprint, config)?;

            // Verify the signature
            signing::verify_signature(&public_key, index_content.as_bytes(), &signature)
                .context("Package index signature verification failed")?;

            tracing::info!("Package index signature verified");
            Some(public_key)
        } else if !config.signing.allow_untrusted {
            bail!("Package index signature not found and untrusted repositories are not allowed");
        } else {
            tracing::warn!("Package index signature not found, proceeding without verification");
            None
        };

        // Parse the index
        let index: PackageIndex = serde_json::from_str(&index_content)?;

        // Check if anything changed
        let repo = &self.repos[idx];
        let changed = repo
            .index
            .as_ref()
            .map(|i| i.generated != index.generated)
            .unwrap_or(true);

        // Update repo state
        let repo = &mut self.repos[idx];
        repo.metadata = Some(metadata);
        repo.index = Some(index);
        repo.public_key = public_key;

        // Save to cache
        repo.save_cache()?;

        Ok(changed)
    }

    /// Find a repository signing key
    fn find_repo_key(&self, fingerprint: &str, config: &Config) -> Result<LoadedPublicKey> {
        // Search in master keys
        let master_dir = &config.signing.master_keys_dir;
        if let Some(key) = self.search_key_in_dir(master_dir, fingerprint)? {
            return Ok(key);
        }

        // Search in packager keys
        let packager_dir = &config.signing.packager_keys_dir;
        if let Some(key) = self.search_key_in_dir(packager_dir, fingerprint)? {
            return Ok(key);
        }

        bail!(
            "Repository signing key not found: {}\n\
            Add the repository's public key with: rookpkg keytrust <key.pub>",
            fingerprint
        );
    }

    /// Search for a key in a directory
    fn search_key_in_dir(
        &self,
        dir: &Path,
        fingerprint: &str,
    ) -> Result<Option<LoadedPublicKey>> {
        if !dir.exists() {
            return Ok(None);
        }

        for entry in fs::read_dir(dir)? {
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

    /// Search for packages across all enabled repositories
    pub fn search(&self, query: &str) -> Vec<SearchResult> {
        let mut results = Vec::new();

        for repo in self.enabled_repos() {
            if let Some(ref index) = repo.index {
                for entry in index.search(query) {
                    results.push(SearchResult {
                        repository: repo.name.clone(),
                        package: entry.clone(),
                    });
                }
            }
        }

        // Sort by name, then by repository priority
        results.sort_by(|a, b| {
            a.package
                .name
                .cmp(&b.package.name)
                .then_with(|| a.repository.cmp(&b.repository))
        });

        results
    }

    /// Find a package by name across all enabled repositories
    pub fn find_package(&self, name: &str) -> Option<SearchResult> {
        for repo in self.enabled_repos() {
            if let Some(ref index) = repo.index {
                if let Some(entry) = index.find_package(name) {
                    return Some(SearchResult {
                        repository: repo.name.clone(),
                        package: entry.clone(),
                    });
                }
            }
        }
        None
    }

    /// Find a package group by name across all enabled repositories
    pub fn find_group(&self, name: &str) -> Option<GroupSearchResult> {
        for repo in self.enabled_repos() {
            if let Some(ref index) = repo.index {
                if let Some(group) = index.find_group(name) {
                    return Some(GroupSearchResult {
                        repository: repo.name.clone(),
                        group: group.clone(),
                    });
                }
            }
        }
        None
    }

    /// List all package groups across all enabled repositories
    pub fn list_groups(&self) -> Vec<GroupSearchResult> {
        let mut results = Vec::new();

        for repo in self.enabled_repos() {
            if let Some(ref index) = repo.index {
                for group in &index.groups {
                    results.push(GroupSearchResult {
                        repository: repo.name.clone(),
                        group: group.clone(),
                    });
                }
            }
        }

        // Sort by group name
        results.sort_by(|a, b| a.group.name.cmp(&b.group.name));
        results
    }

    /// Expand a group name to its list of package names
    ///
    /// If `include_optional` is true, optional packages are included.
    /// Returns None if the group is not found.
    pub fn expand_group(&self, name: &str, include_optional: bool) -> Option<Vec<String>> {
        self.find_group(name).map(|result| {
            result.group.all_packages(include_optional)
                .into_iter()
                .map(|s| s.to_string())
                .collect()
        })
    }

    /// Load cached data for all repositories
    pub fn load_caches(&mut self) -> Result<()> {
        for repo in &mut self.repos {
            if repo.has_cache() {
                let _ = repo.load_cache(); // Ignore errors, just use what we can
            }
        }
        Ok(())
    }

    /// Download a package and verify its hybrid signature
    ///
    /// Returns the path to the downloaded package file and signature verification result.
    /// This is the recommended method for installing packages as it ensures authenticity.
    pub fn download_and_verify_package(
        &self,
        package: &PackageEntry,
        repo_name: &str,
        config: &Config,
    ) -> Result<VerifiedPackage> {
        let repo = self
            .repos
            .iter()
            .find(|r| r.name == repo_name)
            .ok_or_else(|| anyhow::anyhow!("Repository not found: {}", repo_name))?;

        // Download the package file
        let pkg_path = self.download_package(package, repo_name)?;

        // Determine signature file path
        let pkg_filename = Path::new(&package.filename)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| format!("{}-{}-{}.rookpkg", package.name, package.version, package.release));
        let sig_filename = format!("{}.sig", pkg_filename);
        let sig_cache_path = self.pkg_cache_dir.join(&sig_filename);

        // Try to download the signature file
        let sig_url = format!("{}.sig", repo.package_url(package));

        let signature_result = match self.download_with_retries(&sig_url, &sig_cache_path) {
            Ok(()) => {
                // Parse the signature
                let sig_content = fs::read_to_string(&sig_cache_path)
                    .context("Failed to read signature file")?;
                let signature: HybridSignature = serde_json::from_str(&sig_content)
                    .context("Failed to parse signature file")?;

                // Find the signing key
                match self.find_signing_key(&signature.fingerprint, config) {
                    Ok(public_key) => {
                        // Read package content for verification
                        let pkg_content = fs::read(&pkg_path)
                            .context("Failed to read package for verification")?;

                        // Verify the signature
                        match signing::verify_signature(&public_key, &pkg_content, &signature) {
                            Ok(()) => {
                                tracing::info!("Package signature verified: {}", pkg_filename);
                                SignatureStatus::Verified {
                                    fingerprint: signature.fingerprint.clone(),
                                    signer: format!("{} <{}>", public_key.name, public_key.email),
                                    trust_level: public_key.trust_level,
                                }
                            }
                            Err(e) => {
                                tracing::error!("Signature verification failed: {}", e);
                                SignatureStatus::Invalid(e.to_string())
                            }
                        }
                    }
                    Err(e) => {
                        tracing::warn!("Signing key not found: {}", e);
                        SignatureStatus::UnknownKey(signature.fingerprint.clone())
                    }
                }
            }
            Err(e) => {
                tracing::warn!("No signature file found for {}: {}", pkg_filename, e);
                SignatureStatus::Unsigned
            }
        };

        // Reject unsigned, unknown key, or invalid packages - signing is MANDATORY
        match &signature_result {
            SignatureStatus::Invalid(reason) => {
                bail!(
                    "Package signature is INVALID: {}\n\
                    DO NOT INSTALL - package may be tampered!",
                    reason
                );
            }
            SignatureStatus::Unsigned => {
                bail!(
                    "Package {} is unsigned.\n\
                    All packages MUST be signed with a trusted key.\n\
                    Contact the package maintainer to sign this package.",
                    package.name
                );
            }
            SignatureStatus::UnknownKey(fingerprint) => {
                bail!(
                    "Package {} is signed with unknown key: {}\n\
                    Trust the key with: rookpkg keytrust <key.pub>",
                    package.name,
                    fingerprint
                );
            }
            SignatureStatus::Verified { .. } => {
                // Valid signature - proceed
            }
        }

        Ok(VerifiedPackage {
            path: pkg_path,
            package: package.clone(),
            signature_status: signature_result,
        })
    }

    /// Find a signing key by fingerprint
    fn find_signing_key(&self, fingerprint: &str, config: &Config) -> Result<signing::LoadedPublicKey> {
        // Search in master keys (full trust - these are the root of trust)
        if let Some(mut key) = self.search_key_in_dir(&config.signing.master_keys_dir, fingerprint)? {
            key.trust_level = signing::TrustLevel::Full;
            return Ok(key);
        }

        // Search in packager keys
        if let Some(mut key) = self.search_key_in_dir(&config.signing.packager_keys_dir, fingerprint)? {
            // Check if this packager key has a valid certification from a master key
            let cert_dir = config.signing.packager_keys_dir.join("certs");
            if let Ok(Some(cert)) = signing::find_certification_for_key(&key.fingerprint, &cert_dir) {
                // Try to find the certifying master key
                if let Some(master_key) = self.search_key_in_dir(&config.signing.master_keys_dir, &cert.certifier_key)? {
                    // Verify the certification
                    if signing::verify_certification(&cert, &key, &master_key).is_ok() {
                        tracing::debug!(
                            "Key {} certified by master key {} for purpose '{}'",
                            key.fingerprint,
                            cert.certifier_key,
                            cert.purpose
                        );
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

        bail!("Signing key not found: {}", fingerprint)
    }

    /// Download a package from a repository with mirror fallback
    ///
    /// Returns the path to the downloaded package file.
    /// If the package is already cached with correct checksum, returns the cached path.
    /// NOTE: This does NOT verify the signature. Use download_and_verify_package for secure installs.
    pub fn download_package(&self, package: &PackageEntry, repo_name: &str) -> Result<PathBuf> {
        let repo = self
            .repos
            .iter()
            .find(|r| r.name == repo_name)
            .ok_or_else(|| anyhow::anyhow!("Repository not found: {}", repo_name))?;

        // Determine the local cache path for this package
        let pkg_filename = Path::new(&package.filename)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| format!("{}-{}-{}.rookpkg", package.name, package.version, package.release));

        let cache_path = self.pkg_cache_dir.join(&pkg_filename);

        // Check if package is already cached with correct checksum
        if cache_path.exists() {
            match verify_sha256(&cache_path, &package.sha256) {
                Ok(true) => {
                    tracing::info!("Using cached package: {}", pkg_filename);
                    return Ok(cache_path);
                }
                Ok(false) => {
                    tracing::warn!("Cached package has wrong checksum, re-downloading: {}", pkg_filename);
                    fs::remove_file(&cache_path).ok();
                }
                Err(e) => {
                    tracing::warn!("Error checking cached package: {}, re-downloading", e);
                    fs::remove_file(&cache_path).ok();
                }
            }
        }

        // Build list of URLs to try (primary + mirrors)
        let mut urls = vec![repo.package_url(package)];

        // Add mirror URLs if available
        if let Some(ref metadata) = repo.metadata {
            for mirror in &metadata.mirrors {
                if mirror.enabled {
                    let mirror_url = format!(
                        "{}/{}",
                        mirror.url.trim_end_matches('/'),
                        package.filename
                    );
                    urls.push(mirror_url);
                }
            }
        }

        // Sort mirrors by priority (lower = higher priority)
        // Primary URL stays first, mirrors sorted after
        if urls.len() > 1 {
            let primary = urls.remove(0);
            if let Some(ref metadata) = repo.metadata {
                urls.sort_by(|a, b| {
                    let a_priority = metadata
                        .mirrors
                        .iter()
                        .find(|m| a.starts_with(&m.url))
                        .map(|m| m.priority)
                        .unwrap_or(u32::MAX);
                    let b_priority = metadata
                        .mirrors
                        .iter()
                        .find(|m| b.starts_with(&m.url))
                        .map(|m| m.priority)
                        .unwrap_or(u32::MAX);
                    a_priority.cmp(&b_priority)
                });
            }
            urls.insert(0, primary);
        }

        // Try each URL until one succeeds
        let mut last_error: Option<anyhow::Error> = None;

        for url in &urls {
            tracing::info!("Downloading package from: {}", url);

            match self.download_with_retries(url, &cache_path) {
                Ok(()) => {
                    // Verify checksum
                    match verify_sha256(&cache_path, &package.sha256) {
                        Ok(true) => {
                            tracing::info!("Package download verified: {}", pkg_filename);
                            return Ok(cache_path);
                        }
                        Ok(false) => {
                            let err = anyhow::anyhow!(
                                "Checksum mismatch for {} (expected: {}, got different hash)",
                                pkg_filename,
                                package.sha256
                            );
                            tracing::error!("{}", err);
                            fs::remove_file(&cache_path).ok();
                            last_error = Some(err);
                        }
                        Err(e) => {
                            tracing::error!("Failed to verify checksum: {}", e);
                            fs::remove_file(&cache_path).ok();
                            last_error = Some(e);
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!("Download failed from {}: {}", url, e);
                    last_error = Some(e);
                }
            }
        }

        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("No URLs available for package download")))
    }

    /// Download with retry logic
    fn download_with_retries(&self, url: &str, dest: &Path) -> Result<()> {
        self.download_with_retries_progress(url, dest, None)
    }

    /// Download with retry logic and optional progress bar
    fn download_with_retries_progress(
        &self,
        url: &str,
        dest: &Path,
        progress: Option<&ProgressBar>,
    ) -> Result<()> {
        let max_retries = self.download_config.retries;
        let mut last_error: Option<anyhow::Error> = None;

        for attempt in 1..=max_retries {
            if attempt > 1 {
                tracing::info!("Retry attempt {} of {}", attempt, max_retries);
                if let Some(pb) = progress {
                    pb.set_message(format!("Retry {}/{}", attempt, max_retries));
                }
                thread::sleep(Duration::from_secs(2_u64.pow(attempt - 1)));
            }

            match self.download_single_progress(url, dest, progress) {
                Ok(()) => return Ok(()),
                Err(e) => {
                    tracing::warn!("Attempt {} failed: {}", attempt, e);
                    last_error = Some(e);
                }
            }
        }

        Err(last_error.unwrap_or_else(|| {
            anyhow::anyhow!("Download failed after {} retries", max_retries)
        }))
    }

    /// Perform a single download attempt with optional progress bar
    fn download_single_progress(
        &self,
        url: &str,
        dest: &Path,
        progress: Option<&ProgressBar>,
    ) -> Result<()> {
        let response = self
            .client
            .get(url)
            .send()
            .with_context(|| format!("Failed to connect to: {}", url))?;

        if !response.status().is_success() {
            bail!("HTTP error {}: {}", response.status(), url);
        }

        let total_size = response.content_length();

        // Set up progress bar if provided
        if let (Some(pb), Some(total)) = (progress, total_size) {
            pb.set_length(total);
            pb.set_position(0);
        }

        // Create temporary file for download
        let temp_path = dest.with_extension("part");
        let mut file = File::create(&temp_path)
            .with_context(|| format!("Failed to create temp file: {}", temp_path.display()))?;

        // Download with progress
        let mut downloaded: u64 = 0;
        let mut buffer = [0u8; 8192];
        let mut reader = BufReader::new(response);

        loop {
            let bytes_read = reader
                .read(&mut buffer)
                .context("Failed to read from network")?;

            if bytes_read == 0 {
                break;
            }

            file.write_all(&buffer[..bytes_read])
                .context("Failed to write to file")?;

            downloaded += bytes_read as u64;

            // Update progress bar
            if let Some(pb) = progress {
                pb.set_position(downloaded);
            }

            // Log progress for large files (every 10MB) when no progress bar
            if progress.is_none() {
                if let Some(total) = total_size {
                    if total > 10_000_000 && downloaded % 10_000_000 < 8192 {
                        let percent = (downloaded as f64 / total as f64 * 100.0) as u32;
                        tracing::debug!("Progress: {}% ({}/{})", percent, downloaded, total);
                    }
                }
            }
        }

        file.flush().context("Failed to flush file")?;
        drop(file);

        // Move temp file to final destination
        fs::rename(&temp_path, dest).with_context(|| {
            format!(
                "Failed to rename {} to {}",
                temp_path.display(),
                dest.display()
            )
        })?;

        // Mark progress bar as finished
        if let Some(pb) = progress {
            pb.finish_with_message("Done");
        }

        Ok(())
    }

    /// Download multiple packages (sequential fallback)
    ///
    /// For parallel downloads with progress, use `download_packages_parallel`.
    pub fn download_packages(&self, packages: &[(PackageEntry, String)]) -> Result<Vec<PathBuf>> {
        // If only one package or parallel disabled, download sequentially
        if packages.len() <= 1 || self.download_config.max_concurrent_downloads <= 1 {
            let mut paths = Vec::with_capacity(packages.len());
            for (package, repo_name) in packages {
                let path = self.download_package(package, repo_name)?;
                paths.push(path);
            }
            return Ok(paths);
        }

        // Use parallel downloads
        self.download_packages_parallel(packages)
    }

    /// Download multiple packages in parallel with progress bars
    ///
    /// Downloads up to `max_concurrent_downloads` packages simultaneously.
    /// Shows a multi-progress bar UI if `show_progress` is enabled in config.
    pub fn download_packages_parallel(
        &self,
        packages: &[(PackageEntry, String)],
    ) -> Result<Vec<PathBuf>> {
        if packages.is_empty() {
            return Ok(Vec::new());
        }

        let max_concurrent = self.download_config.max_concurrent_downloads.min(16) as usize;
        let show_progress = self.download_config.show_progress;

        // Build list of download tasks with their URLs and cache paths
        let tasks: Vec<_> = packages
            .iter()
            .filter_map(|(package, repo_name)| {
                let repo = self.repos.iter().find(|r| &r.name == repo_name)?;
                let pkg_filename = Path::new(&package.filename)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| {
                        format!(
                            "{}-{}-{}.rookpkg",
                            package.name, package.version, package.release
                        )
                    });
                let cache_path = self.pkg_cache_dir.join(&pkg_filename);

                // Check if already cached with correct checksum
                if cache_path.exists() {
                    if verify_sha256(&cache_path, &package.sha256).unwrap_or(false) {
                        tracing::info!("Using cached package: {}", pkg_filename);
                        return Some((cache_path, package.clone(), repo_name.clone(), None));
                    }
                    // Wrong checksum, will re-download
                    fs::remove_file(&cache_path).ok();
                }

                let url = repo.package_url(package);
                Some((cache_path, package.clone(), repo_name.clone(), Some(url)))
            })
            .collect();

        // Separate cached from needing download
        let mut results: Vec<(usize, PathBuf)> = Vec::with_capacity(tasks.len());
        let to_download: Vec<_> = tasks
            .into_iter()
            .enumerate()
            .filter_map(|(idx, (path, pkg, repo_name, url))| {
                if url.is_none() {
                    // Already cached
                    results.push((idx, path));
                    None
                } else {
                    Some((idx, path, pkg, repo_name, url.unwrap()))
                }
            })
            .collect();

        if to_download.is_empty() {
            // All packages were cached
            results.sort_by_key(|(idx, _)| *idx);
            return Ok(results.into_iter().map(|(_, path)| path).collect());
        }

        // Set up multi-progress bar
        let multi_progress = if show_progress {
            Some(MultiProgress::new())
        } else {
            None
        };

        // Create progress style
        let progress_style = ProgressStyle::with_template(
            "{spinner:.green} [{bar:30.cyan/blue}] {bytes}/{total_bytes} {wide_msg}",
        )
        .unwrap_or_else(|_| ProgressStyle::default_bar())
        .progress_chars("#>-");

        // Shared state for collecting results
        let results_mutex = Arc::new(Mutex::new(results));
        let errors_mutex: Arc<Mutex<Vec<(usize, String)>>> = Arc::new(Mutex::new(Vec::new()));

        // Download in batches of max_concurrent
        for batch in to_download.chunks(max_concurrent) {
            let mut handles = Vec::with_capacity(batch.len());

            for (idx, cache_path, package, _repo_name, url) in batch.iter().cloned() {
                let client = self.client.clone();
                let retries = self.download_config.retries;
                let results = Arc::clone(&results_mutex);
                let errors = Arc::clone(&errors_mutex);
                let package_name = package.name.clone();
                let expected_sha256 = package.sha256.clone();

                // Create progress bar for this download
                let progress_bar = multi_progress.as_ref().map(|mp| {
                    let pb = mp.add(ProgressBar::new(package.size));
                    pb.set_style(progress_style.clone());
                    pb.set_message(format!("{}-{}", package.name, package.version));
                    pb
                });

                let handle = thread::spawn(move || {
                    let result = download_file_with_retries(
                        &client,
                        &url,
                        &cache_path,
                        retries,
                        progress_bar.as_ref(),
                    );

                    match result {
                        Ok(()) => {
                            // Verify checksum
                            match verify_sha256(&cache_path, &expected_sha256) {
                                Ok(true) => {
                                    if let Some(pb) = progress_bar {
                                        pb.finish_with_message(format!("{} OK", package_name));
                                    }
                                    results.lock().unwrap().push((idx, cache_path));
                                }
                                Ok(false) => {
                                    if let Some(pb) = progress_bar {
                                        pb.finish_with_message(format!("{} CHECKSUM FAIL", package_name));
                                    }
                                    fs::remove_file(&cache_path).ok();
                                    errors.lock().unwrap().push((
                                        idx,
                                        format!("Checksum mismatch for {}", package_name),
                                    ));
                                }
                                Err(e) => {
                                    if let Some(pb) = progress_bar {
                                        pb.finish_with_message(format!("{} ERROR", package_name));
                                    }
                                    fs::remove_file(&cache_path).ok();
                                    errors.lock().unwrap().push((
                                        idx,
                                        format!("Checksum verify error for {}: {}", package_name, e),
                                    ));
                                }
                            }
                        }
                        Err(e) => {
                            if let Some(pb) = progress_bar {
                                pb.finish_with_message(format!("{} FAILED", package_name));
                            }
                            errors.lock().unwrap().push((
                                idx,
                                format!("Download failed for {}: {}", package_name, e),
                            ));
                        }
                    }
                });

                handles.push(handle);
            }

            // Wait for this batch to complete
            for handle in handles {
                handle.join().ok();
            }
        }

        // Check for errors
        let errors = errors_mutex.lock().unwrap();
        if !errors.is_empty() {
            let error_msgs: Vec<_> = errors.iter().map(|(_, msg)| msg.as_str()).collect();
            bail!("Download errors:\n  {}", error_msgs.join("\n  "));
        }
        drop(errors);

        // Sort results by original index to maintain order
        let mut final_results = results_mutex.lock().unwrap().clone();
        final_results.sort_by_key(|(idx, _)| *idx);

        if final_results.len() != packages.len() {
            bail!(
                "Download incomplete: expected {} packages, got {}",
                packages.len(),
                final_results.len()
            );
        }

        Ok(final_results.into_iter().map(|(_, path)| path).collect())
    }

    /// Get the base cache directory
    pub fn cache_dir(&self) -> &Path {
        &self.cache_dir
    }

    /// Get the package cache directory
    pub fn package_cache_dir(&self) -> &Path {
        &self.pkg_cache_dir
    }

    /// Clean old packages from the cache
    ///
    /// Removes packages older than `max_age_days` days.
    /// Returns the number of files removed.
    pub fn clean_package_cache(&self, max_age_days: u64) -> Result<CleanResult> {
        let mut result = CleanResult::default();
        let max_age = Duration::from_secs(max_age_days * 24 * 60 * 60);

        if !self.pkg_cache_dir.exists() {
            return Ok(result);
        }

        for entry in fs::read_dir(&self.pkg_cache_dir)? {
            let entry = entry?;
            let metadata = entry.metadata()?;

            if metadata.is_file() {
                result.total_files += 1;
                result.total_bytes += metadata.len();

                if let Ok(modified) = metadata.modified() {
                    if let Ok(age) = modified.elapsed() {
                        if age > max_age {
                            let size = metadata.len();
                            if fs::remove_file(entry.path()).is_ok() {
                                tracing::info!("Removed old cached package: {:?}", entry.file_name());
                                result.removed_files += 1;
                                result.removed_bytes += size;
                            }
                        }
                    }
                }
            }
        }

        Ok(result)
    }

    /// Clean all packages from the cache
    pub fn clean_all_packages(&self) -> Result<CleanResult> {
        let mut result = CleanResult::default();

        if !self.pkg_cache_dir.exists() {
            return Ok(result);
        }

        for entry in fs::read_dir(&self.pkg_cache_dir)? {
            let entry = entry?;
            let metadata = entry.metadata()?;

            if metadata.is_file() {
                result.total_files += 1;
                result.total_bytes += metadata.len();

                let size = metadata.len();
                if fs::remove_file(entry.path()).is_ok() {
                    result.removed_files += 1;
                    result.removed_bytes += size;
                }
            }
        }

        Ok(result)
    }

    /// Check if a package is cached
    pub fn is_package_cached(&self, package: &PackageEntry) -> bool {
        let pkg_filename = Path::new(&package.filename)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| format!("{}-{}-{}.rookpkg", package.name, package.version, package.release));

        let cache_path = self.pkg_cache_dir.join(&pkg_filename);

        if cache_path.exists() {
            verify_sha256(&cache_path, &package.sha256).unwrap_or(false)
        } else {
            false
        }
    }

    /// Get the cached path for a package (if it exists and is valid)
    pub fn get_cached_package(&self, package: &PackageEntry) -> Option<PathBuf> {
        let pkg_filename = Path::new(&package.filename)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| format!("{}-{}-{}.rookpkg", package.name, package.version, package.release));

        let cache_path = self.pkg_cache_dir.join(&pkg_filename);

        if cache_path.exists() && verify_sha256(&cache_path, &package.sha256).unwrap_or(false) {
            Some(cache_path)
        } else {
            None
        }
    }
}

/// Result of a repository update operation
#[derive(Debug, Default)]
pub struct UpdateResult {
    /// Repositories that were updated
    pub updated: Vec<String>,
    /// Repositories that were unchanged
    pub unchanged: Vec<String>,
    /// Repositories that failed to update
    pub failed: Vec<(String, String)>,
}

/// Result of a cache clean operation
#[derive(Debug, Default)]
pub struct CleanResult {
    /// Total files in cache before cleaning
    pub total_files: usize,
    /// Total bytes in cache before cleaning
    pub total_bytes: u64,
    /// Files removed
    pub removed_files: usize,
    /// Bytes freed
    pub removed_bytes: u64,
}

impl CleanResult {
    /// Check if any files were removed
    pub fn any_removed(&self) -> bool {
        self.removed_files > 0
    }

    /// Format the removed bytes as a human-readable string
    pub fn removed_bytes_human(&self) -> String {
        format_bytes(self.removed_bytes)
    }

    /// Format the total bytes as a human-readable string
    pub fn total_bytes_human(&self) -> String {
        format_bytes(self.total_bytes)
    }
}

/// Format bytes as a human-readable string
fn format_bytes(bytes: u64) -> String {
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

/// Verify the SHA256 checksum of a file
fn verify_sha256(path: &Path, expected: &str) -> Result<bool> {
    let actual = compute_sha256(path)?;
    Ok(actual.eq_ignore_ascii_case(expected))
}

/// Compute the SHA256 checksum of a file
fn compute_sha256(path: &Path) -> Result<String> {
    let file = File::open(path)
        .with_context(|| format!("Failed to open file for checksum: {}", path.display()))?;

    let mut reader = BufReader::with_capacity(1024 * 1024, file);
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];

    loop {
        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    let hash = hasher.finalize();
    Ok(hex::encode(hash))
}

/// Download a file with retries (standalone function for thread spawning)
///
/// This function can be called from a separate thread without borrowing self.
fn download_file_with_retries(
    client: &reqwest::blocking::Client,
    url: &str,
    dest: &Path,
    max_retries: u32,
    progress: Option<&ProgressBar>,
) -> Result<()> {
    let mut last_error: Option<anyhow::Error> = None;

    for attempt in 1..=max_retries {
        if attempt > 1 {
            tracing::info!("Retry attempt {} of {} for {}", attempt, max_retries, url);
            if let Some(pb) = progress {
                pb.set_message(format!("Retry {}/{}", attempt, max_retries));
            }
            thread::sleep(Duration::from_secs(2_u64.pow(attempt - 1)));
        }

        match download_file_single(client, url, dest, progress) {
            Ok(()) => return Ok(()),
            Err(e) => {
                tracing::warn!("Attempt {} failed: {}", attempt, e);
                last_error = Some(e);
            }
        }
    }

    Err(last_error.unwrap_or_else(|| {
        anyhow::anyhow!("Download failed after {} retries", max_retries)
    }))
}

/// Perform a single download attempt (standalone function for thread spawning)
fn download_file_single(
    client: &reqwest::blocking::Client,
    url: &str,
    dest: &Path,
    progress: Option<&ProgressBar>,
) -> Result<()> {
    let response = client
        .get(url)
        .send()
        .with_context(|| format!("Failed to connect to: {}", url))?;

    if !response.status().is_success() {
        bail!("HTTP error {}: {}", response.status(), url);
    }

    let total_size = response.content_length();

    // Set up progress bar if provided
    if let (Some(pb), Some(total)) = (progress, total_size) {
        pb.set_length(total);
        pb.set_position(0);
    }

    // Create temporary file for download
    let temp_path = dest.with_extension("part");
    let mut file = File::create(&temp_path)
        .with_context(|| format!("Failed to create temp file: {}", temp_path.display()))?;

    // Download with progress
    let mut downloaded: u64 = 0;
    let mut buffer = [0u8; 8192];
    let mut reader = BufReader::new(response);

    loop {
        let bytes_read = reader
            .read(&mut buffer)
            .context("Failed to read from network")?;

        if bytes_read == 0 {
            break;
        }

        file.write_all(&buffer[..bytes_read])
            .context("Failed to write to file")?;

        downloaded += bytes_read as u64;

        // Update progress bar
        if let Some(pb) = progress {
            pb.set_position(downloaded);
        }
    }

    file.flush().context("Failed to flush file")?;
    drop(file);

    // Move temp file to final destination
    fs::rename(&temp_path, dest).with_context(|| {
        format!(
            "Failed to rename {} to {}",
            temp_path.display(),
            dest.display()
        )
    })?;

    Ok(())
}

impl UpdateResult {
    /// Check if all updates succeeded
    pub fn all_success(&self) -> bool {
        self.failed.is_empty()
    }

    /// Get total number of repositories processed
    pub fn total(&self) -> usize {
        self.updated.len() + self.unchanged.len() + self.failed.len()
    }
}

/// A search result from repository search
#[derive(Debug, Clone)]
pub struct SearchResult {
    /// Repository the package was found in
    pub repository: String,
    /// Package entry
    pub package: PackageEntry,
}

/// A group search result from repository search
#[derive(Debug, Clone)]
pub struct GroupSearchResult {
    /// Repository the group was found in
    pub repository: String,
    /// Package group
    pub group: PackageGroup,
}

/// Status of package signature verification
#[derive(Debug, Clone)]
pub enum SignatureStatus {
    /// Signature verified successfully
    Verified {
        /// Key fingerprint
        fingerprint: String,
        /// Signer identity (name <email>)
        signer: String,
        /// Trust level of the signing key
        trust_level: signing::TrustLevel,
    },
    /// Package has no signature
    Unsigned,
    /// Signature exists but key is not in keyring
    UnknownKey(String),
    /// Signature verification failed (tampered or corrupted)
    Invalid(String),
}

impl SignatureStatus {
    /// Check if the signature is verified
    pub fn is_verified(&self) -> bool {
        matches!(self, SignatureStatus::Verified { .. })
    }

    /// Check if the signature is trusted (verified with at least marginal trust)
    pub fn is_trusted(&self) -> bool {
        match self {
            SignatureStatus::Verified { trust_level, .. } => {
                *trust_level != signing::TrustLevel::Unknown
            }
            _ => false,
        }
    }

    /// Get a human-readable description
    pub fn description(&self) -> String {
        match self {
            SignatureStatus::Verified { signer, trust_level, .. } => {
                let trust_str = match trust_level {
                    signing::TrustLevel::Ultimate => "ultimate",
                    signing::TrustLevel::Full => "full",
                    signing::TrustLevel::Marginal => "marginal",
                    signing::TrustLevel::Unknown => "unknown",
                };
                format!("Verified by {} (trust: {})", signer, trust_str)
            }
            SignatureStatus::Unsigned => "Unsigned".to_string(),
            SignatureStatus::UnknownKey(fp) => format!("Unknown key: {}", fp),
            SignatureStatus::Invalid(reason) => format!("INVALID: {}", reason),
        }
    }
}

/// A downloaded package with signature verification result
#[derive(Debug, Clone)]
pub struct VerifiedPackage {
    /// Path to the downloaded package file
    pub path: PathBuf,
    /// Package metadata
    pub package: PackageEntry,
    /// Signature verification status
    pub signature_status: SignatureStatus,
}

impl VerifiedPackage {
    /// Check if the package signature is verified
    pub fn is_verified(&self) -> bool {
        self.signature_status.is_verified()
    }

    /// Check if the package is from a trusted source
    pub fn is_trusted(&self) -> bool {
        self.signature_status.is_trusted()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_package_index_search() {
        let mut index = PackageIndex::new("test");

        index.add_package(PackageEntry {
            name: "bash".to_string(),
            version: "5.2".to_string(),
            release: 1,
            description: "The GNU Bourne Again shell".to_string(),
            arch: "x86_64".to_string(),
            size: 1234567,
            sha256: "abc123".to_string(),
            filename: "packages/bash-5.2-1.x86_64.rookpkg".to_string(),
            depends: vec!["glibc".to_string()],
            build_depends: vec![],
            provides: vec!["sh".to_string()],
            conflicts: vec![],
            replaces: vec![],
            license: Some("GPL-3.0".to_string()),
            homepage: Some("https://www.gnu.org/software/bash/".to_string()),
            maintainer: Some("Rookery Maintainers".to_string()),
            build_date: Some(Utc::now()),
        });

        index.add_package(PackageEntry {
            name: "zsh".to_string(),
            version: "5.9".to_string(),
            release: 1,
            description: "The Z shell".to_string(),
            arch: "x86_64".to_string(),
            size: 2345678,
            sha256: "def456".to_string(),
            filename: "packages/zsh-5.9-1.x86_64.rookpkg".to_string(),
            depends: vec!["glibc".to_string()],
            build_depends: vec![],
            provides: vec!["sh".to_string()],
            conflicts: vec![],
            replaces: vec![],
            license: Some("MIT".to_string()),
            homepage: Some("https://www.zsh.org/".to_string()),
            maintainer: Some("Rookery Maintainers".to_string()),
            build_date: Some(Utc::now()),
        });

        // Search by name
        let results = index.search("bash");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "bash");

        // Search by description
        let results = index.search("shell");
        assert_eq!(results.len(), 2);

        // Find specific package
        let pkg = index.find_package("zsh");
        assert!(pkg.is_some());
        assert_eq!(pkg.unwrap().version, "5.9");
    }

    #[test]
    fn test_package_index_find_all_versions() {
        let mut index = PackageIndex::new("test-repo");

        // Add multiple versions of the same package
        index.add_package(PackageEntry {
            name: "openssl".to_string(),
            version: "1.1.1w".to_string(),
            release: 1,
            description: "OpenSSL 1.1 series (legacy)".to_string(),
            arch: "x86_64".to_string(),
            size: 3000000,
            sha256: "aaa111".to_string(),
            filename: "packages/openssl-1.1.1w-1.x86_64.rookpkg".to_string(),
            depends: vec!["glibc".to_string()],
            build_depends: vec![],
            provides: vec![],
            conflicts: vec![],
            replaces: vec![],
            license: Some("Apache-2.0".to_string()),
            homepage: Some("https://openssl.org/".to_string()),
            maintainer: Some("Rookery Maintainers".to_string()),
            build_date: Some(Utc::now()),
        });

        index.add_package(PackageEntry {
            name: "openssl".to_string(),
            version: "3.0.12".to_string(),
            release: 1,
            description: "OpenSSL 3.0 series (current)".to_string(),
            arch: "x86_64".to_string(),
            size: 3500000,
            sha256: "bbb222".to_string(),
            filename: "packages/openssl-3.0.12-1.x86_64.rookpkg".to_string(),
            depends: vec!["glibc".to_string()],
            build_depends: vec![],
            provides: vec![],
            conflicts: vec![],
            replaces: vec![],
            license: Some("Apache-2.0".to_string()),
            homepage: Some("https://openssl.org/".to_string()),
            maintainer: Some("Rookery Maintainers".to_string()),
            build_date: Some(Utc::now()),
        });

        index.add_package(PackageEntry {
            name: "curl".to_string(),
            version: "8.5.0".to_string(),
            release: 1,
            description: "Command line tool for transferring data".to_string(),
            arch: "x86_64".to_string(),
            size: 800000,
            sha256: "ccc333".to_string(),
            filename: "packages/curl-8.5.0-1.x86_64.rookpkg".to_string(),
            depends: vec!["openssl".to_string()],
            build_depends: vec![],
            provides: vec![],
            conflicts: vec![],
            replaces: vec![],
            license: Some("MIT".to_string()),
            homepage: Some("https://curl.se/".to_string()),
            maintainer: Some("Rookery Maintainers".to_string()),
            build_date: Some(Utc::now()),
        });

        // find_all_versions should return both openssl versions
        let openssl_versions = index.find_all_versions("openssl");
        assert_eq!(openssl_versions.len(), 2);

        let versions: Vec<&str> = openssl_versions.iter().map(|p| p.version.as_str()).collect();
        assert!(versions.contains(&"1.1.1w"));
        assert!(versions.contains(&"3.0.12"));

        // find_all_versions with single version
        let curl_versions = index.find_all_versions("curl");
        assert_eq!(curl_versions.len(), 1);
        assert_eq!(curl_versions[0].version, "8.5.0");

        // find_all_versions with non-existent package
        let missing_versions = index.find_all_versions("nonexistent");
        assert!(missing_versions.is_empty());
    }

    #[test]
    fn test_package_groups() {
        let mut index = PackageIndex::new("test-repo");

        // Add some packages
        index.add_package(PackageEntry {
            name: "gcc".to_string(),
            version: "13.2".to_string(),
            release: 1,
            description: "GNU Compiler Collection".to_string(),
            arch: "x86_64".to_string(),
            size: 50000000,
            sha256: "gcc123".to_string(),
            filename: "packages/gcc-13.2-1.x86_64.rookpkg".to_string(),
            depends: vec!["glibc".to_string()],
            build_depends: vec![],
            provides: vec![],
            conflicts: vec![],
            replaces: vec![],
            license: Some("GPL-3.0".to_string()),
            homepage: None,
            maintainer: None,
            build_date: None,
        });

        index.add_package(PackageEntry {
            name: "make".to_string(),
            version: "4.4".to_string(),
            release: 1,
            description: "GNU make utility".to_string(),
            arch: "x86_64".to_string(),
            size: 500000,
            sha256: "make123".to_string(),
            filename: "packages/make-4.4-1.x86_64.rookpkg".to_string(),
            depends: vec!["glibc".to_string()],
            build_depends: vec![],
            provides: vec![],
            conflicts: vec![],
            replaces: vec![],
            license: Some("GPL-3.0".to_string()),
            homepage: None,
            maintainer: None,
            build_date: None,
        });

        index.add_package(PackageEntry {
            name: "autoconf".to_string(),
            version: "2.72".to_string(),
            release: 1,
            description: "GNU autoconf".to_string(),
            arch: "noarch".to_string(),
            size: 200000,
            sha256: "autoconf123".to_string(),
            filename: "packages/autoconf-2.72-1.noarch.rookpkg".to_string(),
            depends: vec!["m4".to_string()],
            build_depends: vec![],
            provides: vec![],
            conflicts: vec![],
            replaces: vec![],
            license: Some("GPL-3.0".to_string()),
            homepage: None,
            maintainer: None,
            build_date: None,
        });

        // Add a package group
        let mut devel_group = PackageGroup::new("base-devel", "Base development tools");
        devel_group.add_package("gcc");
        devel_group.add_package("make");
        devel_group.add_optional("autoconf");
        index.add_group(devel_group);

        // Test finding a group
        let group = index.find_group("base-devel");
        assert!(group.is_some());
        let group = group.unwrap();
        assert_eq!(group.name, "base-devel");
        assert_eq!(group.packages.len(), 2);
        assert_eq!(group.optional.len(), 1);

        // Test all_packages method
        let required_only = group.all_packages(false);
        assert_eq!(required_only.len(), 2);
        assert!(required_only.contains(&"gcc"));
        assert!(required_only.contains(&"make"));

        let with_optional = group.all_packages(true);
        assert_eq!(with_optional.len(), 3);
        assert!(with_optional.contains(&"autoconf"));

        // Test searching groups
        let results = index.search_groups("devel");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "base-devel");

        // Test group not found
        let missing = index.find_group("nonexistent");
        assert!(missing.is_none());
    }
}
