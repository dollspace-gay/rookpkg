//! Package specification file (.rook) parser
//!
//! Parses TOML spec files that define packages.

use std::collections::HashMap;
use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// A complete package specification
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageSpec {
    /// Package metadata
    pub package: PackageMetadata,

    /// Source archives and patches
    #[serde(default)]
    pub sources: HashMap<String, Source>,

    /// Patches to apply
    #[serde(default)]
    pub patches: HashMap<String, Patch>,

    /// Build-time dependencies
    #[serde(default, rename = "build-depends")]
    pub build_depends: HashMap<String, String>,

    /// Runtime dependencies
    #[serde(default)]
    pub depends: HashMap<String, String>,

    /// Optional dependencies
    #[serde(default, rename = "optional-depends")]
    pub optional_depends: HashMap<String, Vec<String>>,

    /// Environment variables for build
    #[serde(default)]
    pub environment: HashMap<String, String>,

    /// Build instructions
    #[serde(default)]
    pub build: BuildInstructions,

    /// Files to include in the package
    #[serde(default)]
    pub files: FileSpec,

    /// Configuration files
    #[serde(default, rename = "config-files")]
    pub config_files: ConfigFiles,

    /// Installation scripts
    #[serde(default)]
    pub scripts: Scripts,

    /// Changelog entries
    #[serde(default)]
    pub changelog: Vec<ChangelogEntry>,

    /// Additional metadata
    #[serde(default)]
    pub metadata: Metadata,

    /// Security information
    #[serde(default)]
    pub security: Security,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageMetadata {
    /// Package name
    pub name: String,

    /// Version string
    pub version: String,

    /// Release number (increments for same version rebuilds)
    #[serde(default = "default_release")]
    pub release: u32,

    /// Short summary
    #[serde(default)]
    pub summary: String,

    /// Full description
    #[serde(default)]
    pub description: String,

    /// License identifier
    #[serde(default)]
    pub license: String,

    /// Upstream URL
    #[serde(default)]
    pub url: String,

    /// Maintainer email
    #[serde(default)]
    pub maintainer: String,

    /// Categories
    #[serde(default)]
    pub categories: Vec<String>,
}

fn default_release() -> u32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Source {
    /// Download URL
    pub url: String,

    /// SHA256 checksum
    pub sha256: String,

    /// Mirror URLs for fallback
    #[serde(default)]
    pub mirrors: Vec<String>,

    /// Override filename (derived from URL if not specified)
    #[serde(default)]
    pub filename: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Patch {
    /// Patch file path (relative to spec file)
    pub file: String,

    /// Strip level for patch -p
    #[serde(default = "default_strip")]
    pub strip: u32,
}

fn default_strip() -> u32 {
    1
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BuildInstructions {
    /// Preparation phase (unpack, patch)
    #[serde(default)]
    pub prep: String,

    /// Configure phase
    #[serde(default)]
    pub configure: String,

    /// Build phase
    #[serde(default)]
    pub build: String,

    /// Test/check phase
    #[serde(default)]
    pub check: String,

    /// Install phase
    #[serde(default)]
    pub install: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FileSpec {
    /// Patterns for files to include
    #[serde(default)]
    pub include: Vec<String>,

    /// Patterns for files to exclude
    #[serde(default)]
    pub exclude: Vec<String>,

    /// Special file configurations
    #[serde(default)]
    pub config: Vec<FileConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileConfig {
    /// File path
    pub path: String,

    /// File mode (e.g., "0755", "4755")
    #[serde(default)]
    pub mode: Option<String>,

    /// Owner
    #[serde(default)]
    pub owner: Option<String>,

    /// Group
    #[serde(default)]
    pub group: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ConfigFiles {
    /// Files to preserve during upgrades
    #[serde(default)]
    pub preserve: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Scripts {
    /// Run before installation (create users, stop services, etc.)
    #[serde(default, rename = "pre-install")]
    pub pre_install: String,

    /// Run after installation (configure, start services, etc.)
    #[serde(default, rename = "post-install")]
    pub post_install: String,

    /// Run before removal (stop services, backup data)
    #[serde(default, rename = "pre-remove")]
    pub pre_remove: String,

    /// Run after removal (cleanup users, etc.)
    #[serde(default, rename = "post-remove")]
    pub post_remove: String,

    /// Run before upgrade
    #[serde(default, rename = "pre-upgrade")]
    pub pre_upgrade: String,

    /// Run after upgrade
    #[serde(default, rename = "post-upgrade")]
    pub post_upgrade: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangelogEntry {
    /// Date of the change
    pub date: String,

    /// Version string
    pub version: String,

    /// Author email
    pub author: String,

    /// List of changes
    pub changes: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Metadata {
    /// Search keywords
    #[serde(default)]
    pub keywords: Vec<String>,

    /// Stability level
    #[serde(default = "default_stability")]
    pub stability: String,
}

fn default_stability() -> String {
    "stable".to_string()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Security {
    /// Compatible with grsecurity
    #[serde(default, rename = "grsec-compatible")]
    pub grsec_compatible: bool,

    /// Fixed CVEs
    #[serde(default, rename = "fixed-cves")]
    pub fixed_cves: Vec<String>,
}

impl PackageSpec {
    /// Parse a spec file from a path
    pub fn from_file(path: &Path) -> Result<Self> {
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("Failed to read spec file: {}", path.display()))?;

        Self::from_str(&content)
    }

    /// Parse a spec file from a string
    pub fn from_str(content: &str) -> Result<Self> {
        toml::from_str(content).context("Failed to parse spec file as TOML")
    }

    /// Get the full version string (version-release)
    pub fn full_version(&self) -> String {
        format!("{}-{}", self.package.version, self.package.release)
    }

    /// Get all sources as a vec
    pub fn sources_list(&self) -> Vec<(&str, &Source)> {
        self.sources.iter().map(|(k, v)| (k.as_str(), v)).collect()
    }

    /// Get all runtime dependencies
    pub fn runtime_deps(&self) -> impl Iterator<Item = (&str, &str)> {
        self.depends.iter().map(|(k, v)| (k.as_str(), v.as_str()))
    }

    /// Get all build dependencies
    pub fn build_deps(&self) -> impl Iterator<Item = (&str, &str)> {
        self.build_depends
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_spec() {
        let spec = r#"
[package]
name = "hello"
version = "2.12"
release = 1
summary = "GNU Hello World program"
license = "GPLv3+"

[sources]
source0 = { url = "http://example.org/hello-2.12.tar.gz", sha256 = "abc123" }

[depends]
glibc = ">= 2.39"

[build]
configure = "./configure --prefix=/usr"
build = "make"
install = "make DESTDIR=$ROOKPKG_DESTDIR install"

[files]
include = ["/usr/bin/hello", "/usr/share/man/man1/hello.1"]
"#;

        let parsed = PackageSpec::from_str(spec).unwrap();
        assert_eq!(parsed.package.name, "hello");
        assert_eq!(parsed.package.version, "2.12");
        assert_eq!(parsed.package.release, 1);
        assert_eq!(parsed.depends.get("glibc"), Some(&">= 2.39".to_string()));
    }
}
