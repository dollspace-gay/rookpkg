//! Source download and verification
//!
//! Downloads source archives with SHA256 verification, retry logic, and mirror support.

use std::fs::{self, File};
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use reqwest::blocking::Client;
use sha2::{Digest, Sha256};

use crate::config::Config;

/// Maximum number of download retries
const MAX_RETRIES: u32 = 3;

/// Timeout for connecting to a server
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

/// Timeout for the entire download operation (10 minutes for large files)
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(600);

/// A source file to download
#[derive(Debug, Clone)]
pub struct SourceFile {
    /// Primary download URL
    pub url: String,
    /// Expected SHA256 checksum (hex-encoded)
    pub sha256: String,
    /// Optional mirror URLs
    pub mirrors: Vec<String>,
    /// Local filename (derived from URL if not specified)
    pub filename: Option<String>,
}

impl SourceFile {
    /// Create a new source file specification
    pub fn new(url: &str, sha256: &str) -> Self {
        Self {
            url: url.to_string(),
            sha256: sha256.to_lowercase(),
            mirrors: Vec::new(),
            filename: None,
        }
    }

    /// Add a mirror URL
    pub fn with_mirror(mut self, mirror: &str) -> Self {
        self.mirrors.push(mirror.to_string());
        self
    }

    /// Set the local filename
    pub fn with_filename(mut self, filename: &str) -> Self {
        self.filename = Some(filename.to_string());
        self
    }

    /// Get the filename (from explicit setting or URL)
    pub fn get_filename(&self) -> String {
        if let Some(ref name) = self.filename {
            return name.clone();
        }
        // Extract filename from URL
        self.url
            .rsplit('/')
            .next()
            .unwrap_or("download")
            .split('?')
            .next()
            .unwrap_or("download")
            .to_string()
    }

    /// Get all URLs to try (primary + mirrors)
    pub fn all_urls(&self) -> Vec<&str> {
        let mut urls = vec![self.url.as_str()];
        for mirror in &self.mirrors {
            urls.push(mirror.as_str());
        }
        urls
    }
}

/// Download manager for source files
pub struct Downloader {
    client: Client,
    cache_dir: PathBuf,
}

impl Downloader {
    /// Create a new downloader
    pub fn new(config: &Config) -> Result<Self> {
        let client = Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(DOWNLOAD_TIMEOUT)
            .user_agent(format!("rookpkg/{}", env!("CARGO_PKG_VERSION")))
            .build()
            .context("Failed to create HTTP client")?;

        let cache_dir = config.paths.cache_dir.join("sources");
        fs::create_dir_all(&cache_dir)
            .with_context(|| format!("Failed to create cache directory: {}", cache_dir.display()))?;

        Ok(Self { client, cache_dir })
    }

    /// Download a source file with verification
    ///
    /// Returns the path to the downloaded file.
    /// If the file already exists in cache with correct checksum, it's returned immediately.
    pub fn download(&self, source: &SourceFile) -> Result<PathBuf> {
        let filename = source.get_filename();
        let dest_path = self.cache_dir.join(&filename);

        // Check if file already exists with correct checksum
        if dest_path.exists() {
            match verify_checksum(&dest_path, &source.sha256) {
                Ok(true) => {
                    tracing::info!("Using cached source: {}", filename);
                    return Ok(dest_path);
                }
                Ok(false) => {
                    tracing::warn!("Cached file has wrong checksum, re-downloading: {}", filename);
                    fs::remove_file(&dest_path).ok();
                }
                Err(e) => {
                    tracing::warn!("Error checking cached file: {}, re-downloading", e);
                    fs::remove_file(&dest_path).ok();
                }
            }
        }

        // Try each URL until one succeeds
        let urls = source.all_urls();
        let mut last_error: Option<anyhow::Error> = None;

        for url in &urls {
            tracing::info!("Downloading: {}", url);

            match self.download_with_retries(url, &dest_path) {
                Ok(()) => {
                    // Verify checksum
                    match verify_checksum(&dest_path, &source.sha256) {
                        Ok(true) => {
                            tracing::info!("Download verified: {}", filename);
                            return Ok(dest_path);
                        }
                        Ok(false) => {
                            let err = anyhow::anyhow!(
                                "Checksum mismatch for {} (expected: {})",
                                filename,
                                source.sha256
                            );
                            tracing::error!("{}", err);
                            fs::remove_file(&dest_path).ok();
                            last_error = Some(err);
                        }
                        Err(e) => {
                            tracing::error!("Failed to verify checksum: {}", e);
                            fs::remove_file(&dest_path).ok();
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

        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("No URLs available for download")))
    }

    /// Download with retry logic
    fn download_with_retries(&self, url: &str, dest: &Path) -> Result<()> {
        let mut last_error: Option<anyhow::Error> = None;

        for attempt in 1..=MAX_RETRIES {
            if attempt > 1 {
                tracing::info!("Retry attempt {} of {}", attempt, MAX_RETRIES);
                std::thread::sleep(Duration::from_secs(2_u64.pow(attempt - 1)));
            }

            match self.download_single(url, dest) {
                Ok(()) => return Ok(()),
                Err(e) => {
                    tracing::warn!("Attempt {} failed: {}", attempt, e);
                    last_error = Some(e);
                }
            }
        }

        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("Download failed after {} retries", MAX_RETRIES)))
    }

    /// Perform a single download attempt
    fn download_single(&self, url: &str, dest: &Path) -> Result<()> {
        let response = self
            .client
            .get(url)
            .send()
            .with_context(|| format!("Failed to connect to: {}", url))?;

        if !response.status().is_success() {
            bail!("HTTP error {}: {}", response.status(), url);
        }

        let total_size = response.content_length();

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

            // Log progress for large files
            if let Some(total) = total_size {
                if total > 10_000_000 && downloaded % 10_000_000 < 8192 {
                    let percent = (downloaded as f64 / total as f64 * 100.0) as u32;
                    tracing::debug!("Progress: {}% ({}/{})", percent, downloaded, total);
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

        Ok(())
    }

    /// Download multiple sources in sequence
    pub fn download_all(&self, sources: &[SourceFile]) -> Result<Vec<PathBuf>> {
        let mut paths = Vec::with_capacity(sources.len());

        for source in sources {
            let path = self.download(source)?;
            paths.push(path);
        }

        Ok(paths)
    }

    /// Get the cache directory path
    pub fn cache_dir(&self) -> &Path {
        &self.cache_dir
    }

    /// Clean old files from the cache
    pub fn clean_cache(&self, max_age_days: u64) -> Result<u64> {
        let mut removed = 0;
        let max_age = Duration::from_secs(max_age_days * 24 * 60 * 60);

        for entry in fs::read_dir(&self.cache_dir)? {
            let entry = entry?;
            let metadata = entry.metadata()?;

            if metadata.is_file() {
                if let Ok(modified) = metadata.modified() {
                    if let Ok(age) = modified.elapsed() {
                        if age > max_age {
                            if fs::remove_file(entry.path()).is_ok() {
                                tracing::info!("Removed old cache file: {:?}", entry.file_name());
                                removed += 1;
                            }
                        }
                    }
                }
            }
        }

        Ok(removed)
    }
}

/// Verify the SHA256 checksum of a file
pub fn verify_checksum(path: &Path, expected: &str) -> Result<bool> {
    let actual = compute_sha256(path)?;
    Ok(actual.eq_ignore_ascii_case(expected))
}

/// Compute the SHA256 checksum of a file
pub fn compute_sha256(path: &Path) -> Result<String> {
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

/// Extract a tarball to a directory
pub fn extract_tarball(archive: &Path, dest_dir: &Path) -> Result<()> {
    use std::process::Command;

    fs::create_dir_all(dest_dir)
        .with_context(|| format!("Failed to create extraction directory: {}", dest_dir.display()))?;

    let archive_str = archive
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("Invalid archive path"))?;

    // Determine decompression based on extension
    let tar_args: Vec<&str> = if archive_str.ends_with(".tar.gz") || archive_str.ends_with(".tgz") {
        vec!["-xzf", archive_str, "-C"]
    } else if archive_str.ends_with(".tar.xz") {
        vec!["-xJf", archive_str, "-C"]
    } else if archive_str.ends_with(".tar.bz2") {
        vec!["-xjf", archive_str, "-C"]
    } else if archive_str.ends_with(".tar.zst") || archive_str.ends_with(".tar.zstd") {
        vec!["--use-compress-program=zstd", "-xf", archive_str, "-C"]
    } else if archive_str.ends_with(".tar") {
        vec!["-xf", archive_str, "-C"]
    } else {
        bail!("Unsupported archive format: {}", archive_str);
    };

    let dest_str = dest_dir
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("Invalid destination path"))?;

    let mut cmd_args = tar_args;
    cmd_args.push(dest_str);

    let output = Command::new("tar")
        .args(&cmd_args)
        .output()
        .context("Failed to execute tar command")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("tar extraction failed: {}", stderr);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::tempdir;

    #[test]
    fn test_source_file_filename() {
        let source = SourceFile::new(
            "https://example.org/packages/foo-1.0.tar.gz",
            "abc123",
        );
        assert_eq!(source.get_filename(), "foo-1.0.tar.gz");

        let source_with_query = SourceFile::new(
            "https://example.org/download?file=bar-2.0.tar.xz",
            "def456",
        );
        assert_eq!(source_with_query.get_filename(), "download");

        let source_explicit = SourceFile::new("https://example.org/download", "xyz789")
            .with_filename("custom-name.tar.gz");
        assert_eq!(source_explicit.get_filename(), "custom-name.tar.gz");
    }

    #[test]
    fn test_source_file_mirrors() {
        let source = SourceFile::new("https://primary.org/file.tar.gz", "abc123")
            .with_mirror("https://mirror1.org/file.tar.gz")
            .with_mirror("https://mirror2.org/file.tar.gz");

        let urls = source.all_urls();
        assert_eq!(urls.len(), 3);
        assert_eq!(urls[0], "https://primary.org/file.tar.gz");
        assert_eq!(urls[1], "https://mirror1.org/file.tar.gz");
        assert_eq!(urls[2], "https://mirror2.org/file.tar.gz");
    }

    #[test]
    fn test_compute_sha256() {
        let dir = tempdir().unwrap();
        let file_path = dir.path().join("test.txt");

        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"hello world").unwrap();
        drop(file);

        let hash = compute_sha256(&file_path).unwrap();
        // SHA256 of "hello world"
        assert_eq!(
            hash,
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        );
    }

    #[test]
    fn test_verify_checksum() {
        let dir = tempdir().unwrap();
        let file_path = dir.path().join("test.txt");

        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"hello world").unwrap();
        drop(file);

        // Correct checksum
        assert!(verify_checksum(
            &file_path,
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        )
        .unwrap());

        // Wrong checksum
        assert!(!verify_checksum(&file_path, "wronghash").unwrap());

        // Case insensitive
        assert!(verify_checksum(
            &file_path,
            "B94D27B9934D3E08A52E52D7DA7DABFAC484EFE37A5380EE9088F7ACE2EFCDE9"
        )
        .unwrap());
    }
}
