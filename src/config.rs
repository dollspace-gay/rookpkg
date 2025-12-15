//! Configuration management for rookpkg

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Main configuration structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Database configuration
    #[serde(default)]
    pub database: DatabaseConfig,

    /// Signing configuration
    #[serde(default)]
    pub signing: SigningConfig,

    /// Repository configuration
    #[serde(default)]
    pub repositories: Vec<RepositoryConfig>,

    /// Build configuration
    #[serde(default)]
    pub build: BuildConfig,

    /// Path configuration
    #[serde(default)]
    pub paths: PathsConfig,

    /// Hooks configuration
    #[serde(default)]
    pub hooks: HooksConfig,

    /// Download configuration
    #[serde(default)]
    pub download: DownloadConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseConfig {
    /// Path to the SQLite database
    pub path: PathBuf,
}

impl Default for DatabaseConfig {
    fn default() -> Self {
        Self {
            path: PathBuf::from("/var/lib/rookpkg/db.sqlite"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SigningConfig {
    /// Require signatures on all packages (cannot be disabled)
    #[serde(default = "default_true")]
    pub require_signatures: bool,

    /// Allow packages signed by untrusted keys
    #[serde(default)]
    pub allow_untrusted: bool,

    /// Directory for master signing keys
    pub master_keys_dir: PathBuf,

    /// Directory for packager signing keys
    pub packager_keys_dir: PathBuf,

    /// Path to user's signing key
    pub user_signing_key: PathBuf,

    /// Allowed signature algorithms
    #[serde(default = "default_algorithms")]
    pub allowed_algorithms: Vec<String>,
}

fn default_true() -> bool {
    true
}

fn default_algorithms() -> Vec<String> {
    vec![
        "hybrid-ed25519-ml-dsa-65".to_string(),
        "ed25519".to_string(),
    ]
}

impl Default for SigningConfig {
    fn default() -> Self {
        let config_dir = directories::ProjectDirs::from("org", "rookery", "rookpkg")
            .map(|d| d.config_dir().to_path_buf())
            .unwrap_or_else(|| PathBuf::from("~/.config/rookpkg"));

        Self {
            require_signatures: true,
            allow_untrusted: false,
            master_keys_dir: PathBuf::from("/etc/rookpkg/keys/master"),
            packager_keys_dir: PathBuf::from("/etc/rookpkg/keys/packagers"),
            user_signing_key: config_dir.join("signing-key.secret"),
            allowed_algorithms: default_algorithms(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepositoryConfig {
    /// Repository name
    pub name: String,

    /// Repository URL
    pub url: String,

    /// Whether this repository is enabled
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Priority (lower = higher priority)
    #[serde(default = "default_priority")]
    pub priority: u32,
}

fn default_priority() -> u32 {
    100
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuildConfig {
    /// Build directory
    pub build_dir: PathBuf,

    /// Cache directory for downloaded sources
    pub cache_dir: PathBuf,

    /// Number of parallel jobs for make
    #[serde(default = "default_jobs")]
    pub jobs: u32,
}

fn default_jobs() -> u32 {
    num_cpus()
}

fn num_cpus() -> u32 {
    std::thread::available_parallelism()
        .map(|p| p.get() as u32)
        .unwrap_or(4)
}

impl Default for BuildConfig {
    fn default() -> Self {
        Self {
            build_dir: PathBuf::from("/var/lib/rookpkg/build"),
            cache_dir: PathBuf::from("/var/lib/rookpkg/cache"),
            jobs: default_jobs(),
        }
    }
}

/// Path configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PathsConfig {
    /// Root directory for rookpkg data
    pub root_dir: PathBuf,

    /// Cache directory for downloads
    pub cache_dir: PathBuf,

    /// Build directory for package building
    pub build_dir: PathBuf,

    /// Directory for installed package data
    pub pkg_dir: PathBuf,

    /// Directory for spec files
    pub specs_dir: PathBuf,
}

impl Default for PathsConfig {
    fn default() -> Self {
        Self {
            root_dir: PathBuf::from("/var/lib/rookpkg"),
            cache_dir: PathBuf::from("/var/cache/rookpkg"),
            build_dir: PathBuf::from("/var/lib/rookpkg/build"),
            pkg_dir: PathBuf::from("/var/lib/rookpkg/packages"),
            specs_dir: PathBuf::from("/var/lib/rookpkg/specs"),
        }
    }
}

/// Hooks configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HooksConfig {
    /// Directory for system-wide hooks
    pub hooks_dir: PathBuf,

    /// Whether hooks are enabled
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Fail transaction if a pre-transaction hook fails
    #[serde(default = "default_true")]
    pub fail_on_pre_hook_error: bool,

    /// Fail transaction if a post-transaction hook fails (after transaction completes)
    #[serde(default)]
    pub fail_on_post_hook_error: bool,

    /// Timeout for hook execution in seconds (0 = no timeout)
    #[serde(default = "default_hook_timeout")]
    pub timeout_seconds: u64,
}

fn default_hook_timeout() -> u64 {
    300 // 5 minutes
}

impl Default for HooksConfig {
    fn default() -> Self {
        Self {
            hooks_dir: PathBuf::from("/etc/rookpkg/hooks.d"),
            enabled: true,
            fail_on_pre_hook_error: true,
            fail_on_post_hook_error: false,
            timeout_seconds: default_hook_timeout(),
        }
    }
}

/// Download configuration for parallel package downloads
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadConfig {
    /// Maximum number of concurrent downloads (1-16)
    #[serde(default = "default_concurrent_downloads")]
    pub max_concurrent_downloads: u8,

    /// Connection timeout in seconds
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_secs: u64,

    /// Download timeout in seconds (0 = no timeout)
    #[serde(default = "default_download_timeout")]
    pub download_timeout_secs: u64,

    /// Number of retries for failed downloads
    #[serde(default = "default_retries")]
    pub retries: u32,

    /// Whether to show download progress
    #[serde(default = "default_true")]
    pub show_progress: bool,
}

fn default_concurrent_downloads() -> u8 {
    4
}

fn default_connect_timeout() -> u64 {
    30
}

fn default_download_timeout() -> u64 {
    600 // 10 minutes
}

fn default_retries() -> u32 {
    3
}

impl Default for DownloadConfig {
    fn default() -> Self {
        Self {
            max_concurrent_downloads: default_concurrent_downloads(),
            connect_timeout_secs: default_connect_timeout(),
            download_timeout_secs: default_download_timeout(),
            retries: default_retries(),
            show_progress: true,
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            database: DatabaseConfig::default(),
            signing: SigningConfig::default(),
            repositories: vec![],
            build: BuildConfig::default(),
            paths: PathsConfig::default(),
            hooks: HooksConfig::default(),
            download: DownloadConfig::default(),
        }
    }
}

impl Config {
    /// Load configuration from file, or use defaults
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let config_path = path
            .map(PathBuf::from)
            .or_else(|| {
                // Try system config
                let system_config = PathBuf::from("/etc/rookpkg/rookpkg.conf");
                if system_config.exists() {
                    return Some(system_config);
                }

                // Try user config
                directories::ProjectDirs::from("org", "rookery", "rookpkg")
                    .map(|d| d.config_dir().join("rookpkg.conf"))
                    .filter(|p| p.exists())
            });

        match config_path {
            Some(path) => {
                let content = std::fs::read_to_string(&path)
                    .with_context(|| format!("Failed to read config: {}", path.display()))?;
                toml::from_str(&content)
                    .with_context(|| format!("Failed to parse config: {}", path.display()))
            }
            None => Ok(Config::default()),
        }
    }

    /// Get the directory for signing keys
    pub fn signing_key_dir(&self) -> &Path {
        self.signing
            .user_signing_key
            .parent()
            .unwrap_or(Path::new("."))
    }
}
