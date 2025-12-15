//! Binary package archive format (.rookpkg)
//!
//! Creates and reads .rookpkg archives containing:
//! - .PKGINFO: Package metadata in TOML format
//! - .FILES: List of installed files with checksums
//! - .INSTALL: Installation scripts
//! - .SIGNATURE: Ed25519 signature (required)
//! - data.tar.zst: Compressed file contents

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Read};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
// sha2 imported but compute_sha256 is used from download module
use tar::{Archive, Builder};

use crate::download::compute_sha256;
use crate::spec::PackageSpec;

/// Package archive file extension
pub const PKG_EXTENSION: &str = ".rookpkg";

/// Package info metadata (stored as .PKGINFO)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageInfo {
    /// Package name
    pub name: String,

    /// Version string
    pub version: String,

    /// Release number
    pub release: u32,

    /// Short description
    pub summary: String,

    /// Full description
    pub description: String,

    /// License
    pub license: String,

    /// Upstream URL
    pub url: String,

    /// Maintainer
    pub maintainer: String,

    /// Build timestamp (Unix epoch)
    pub build_time: i64,

    /// Size of installed files in bytes
    pub installed_size: u64,

    /// Runtime dependencies: name -> version constraint
    pub depends: HashMap<String, String>,

    /// Build dependencies (for reference)
    pub build_depends: HashMap<String, String>,

    /// Optional dependencies
    pub optional_depends: HashMap<String, Vec<String>>,

    /// Package architecture
    pub arch: String,
}

impl PackageInfo {
    /// Create PackageInfo from a spec
    pub fn from_spec(spec: &PackageSpec) -> Self {
        Self {
            name: spec.package.name.clone(),
            version: spec.package.version.clone(),
            release: spec.package.release,
            summary: spec.package.summary.clone(),
            description: spec.package.description.clone(),
            license: spec.package.license.clone(),
            url: spec.package.url.clone(),
            maintainer: spec.package.maintainer.clone(),
            build_time: chrono::Utc::now().timestamp(),
            installed_size: 0, // Will be calculated during packaging
            depends: spec.depends.clone(),
            build_depends: spec.build_depends.clone(),
            optional_depends: spec.optional_depends.clone(),
            arch: std::env::consts::ARCH.to_string(),
        }
    }

    /// Get the full package filename
    pub fn filename(&self) -> String {
        format!(
            "{}-{}-{}.{}{}",
            self.name, self.version, self.release, self.arch, PKG_EXTENSION
        )
    }
}

/// File entry in the package
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntry {
    /// File path (absolute, starting with /)
    pub path: String,

    /// File size in bytes
    pub size: u64,

    /// SHA256 checksum
    pub sha256: String,

    /// File mode (permissions)
    pub mode: u32,

    /// Is this a config file?
    pub is_config: bool,

    /// File type
    pub file_type: FileType,
}

/// Type of file entry
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileType {
    Regular,
    Directory,
    Symlink,
    Hardlink,
}

/// Installation scripts
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct InstallScripts {
    /// Run before installation (create users, stop services, etc.)
    pub pre_install: String,

    /// Run after installation (configure, start services, etc.)
    pub post_install: String,

    /// Run before removal (stop services, backup data)
    pub pre_remove: String,

    /// Run after removal (cleanup users, etc.)
    pub post_remove: String,

    /// Run before upgrade
    pub pre_upgrade: String,

    /// Run after upgrade
    pub post_upgrade: String,
}

impl InstallScripts {
    /// Create from a PackageSpec
    pub fn from_spec(spec: &PackageSpec) -> Self {
        Self {
            pre_install: spec.scripts.pre_install.clone(),
            post_install: spec.scripts.post_install.clone(),
            pre_remove: spec.scripts.pre_remove.clone(),
            post_remove: spec.scripts.post_remove.clone(),
            pre_upgrade: spec.scripts.pre_upgrade.clone(),
            post_upgrade: spec.scripts.post_upgrade.clone(),
        }
    }

    /// Check if any scripts are defined
    pub fn has_scripts(&self) -> bool {
        !self.pre_install.is_empty()
            || !self.post_install.is_empty()
            || !self.pre_remove.is_empty()
            || !self.post_remove.is_empty()
            || !self.pre_upgrade.is_empty()
            || !self.post_upgrade.is_empty()
    }
}

/// Wrapper struct for serializing file list to TOML
#[derive(Debug, Clone, Serialize, Deserialize)]
struct FileList {
    files: Vec<FileEntry>,
}

/// Package archive builder
pub struct PackageArchiveBuilder {
    info: PackageInfo,
    files: Vec<FileEntry>,
    scripts: InstallScripts,
    source_dir: PathBuf,
}

impl PackageArchiveBuilder {
    /// Create a new archive builder
    pub fn new(spec: &PackageSpec, source_dir: &Path) -> Self {
        Self {
            info: PackageInfo::from_spec(spec),
            files: Vec::new(),
            scripts: InstallScripts::from_spec(spec),
            source_dir: source_dir.to_path_buf(),
        }
    }

    /// Scan and add files from the source directory
    pub fn scan_files(&mut self) -> Result<()> {
        self.files.clear();
        let mut total_size: u64 = 0;

        fn scan_recursive(
            dir: &Path,
            base: &Path,
            files: &mut Vec<FileEntry>,
            total_size: &mut u64,
            config_patterns: &[String],
        ) -> Result<()> {
            for entry in fs::read_dir(dir)? {
                let entry = entry?;
                let path = entry.path();
                let metadata = entry.metadata()?;

                // Get path relative to base, then make it absolute for the target system
                let rel_path = path.strip_prefix(base)?;
                let install_path = PathBuf::from("/").join(rel_path);
                let path_str = install_path.to_string_lossy().to_string();

                let file_type = if metadata.is_dir() {
                    FileType::Directory
                } else if metadata.file_type().is_symlink() {
                    FileType::Symlink
                } else {
                    FileType::Regular
                };

                let is_config = config_patterns.iter().any(|p| path_str.contains(p));

                let (size, sha256) = if file_type == FileType::Regular {
                    let size = metadata.len();
                    let sha256 = compute_sha256(&path)?;
                    *total_size += size;
                    (size, sha256)
                } else {
                    (0, String::new())
                };

                #[cfg(unix)]
                let mode = std::os::unix::fs::PermissionsExt::mode(&metadata.permissions());
                #[cfg(not(unix))]
                let mode = if metadata.is_dir() { 0o755 } else { 0o644 };

                files.push(FileEntry {
                    path: path_str,
                    size,
                    sha256,
                    mode,
                    is_config,
                    file_type,
                });

                if metadata.is_dir() {
                    scan_recursive(&path, base, files, total_size, config_patterns)?;
                }
            }
            Ok(())
        }

        // Get config file patterns from spec (if we have access to it)
        // For now, use common patterns
        let config_patterns: Vec<String> = vec![
            "/etc/".to_string(),
        ];

        scan_recursive(
            &self.source_dir,
            &self.source_dir,
            &mut self.files,
            &mut total_size,
            &config_patterns,
        )?;

        self.info.installed_size = total_size;
        self.files.sort_by(|a, b| a.path.cmp(&b.path));

        tracing::info!(
            "Scanned {} files, total size: {} bytes",
            self.files.len(),
            total_size
        );

        Ok(())
    }

    /// Build the package archive
    pub fn build(&self, output_dir: &Path) -> Result<PathBuf> {
        fs::create_dir_all(output_dir)?;

        let output_path = output_dir.join(self.info.filename());
        let temp_dir = tempfile::tempdir()?;

        // Create .PKGINFO
        let pkginfo_path = temp_dir.path().join(".PKGINFO");
        let pkginfo_content = toml::to_string_pretty(&self.info)?;
        fs::write(&pkginfo_path, &pkginfo_content)?;

        // Create .FILES (wrap in FileList struct for valid TOML)
        let files_path = temp_dir.path().join(".FILES");
        let file_list = FileList { files: self.files.clone() };
        let files_content = toml::to_string_pretty(&file_list)?;
        fs::write(&files_path, &files_content)?;

        // Create .INSTALL if scripts exist
        let install_path = temp_dir.path().join(".INSTALL");
        if self.scripts.has_scripts() {
            let install_content = toml::to_string_pretty(&self.scripts)?;
            fs::write(&install_path, &install_content)?;
        }

        // Create data.tar.zst
        let data_tar_path = temp_dir.path().join("data.tar");
        self.create_data_tar(&data_tar_path)?;

        let data_zst_path = temp_dir.path().join("data.tar.zst");
        self.compress_zstd(&data_tar_path, &data_zst_path)?;

        // Create the final package archive (tar containing all the above)
        self.create_package_archive(&output_path, temp_dir.path(), &data_zst_path)?;

        tracing::info!("Created package: {}", output_path.display());
        Ok(output_path)
    }

    /// Create the data tarball from source directory
    fn create_data_tar(&self, output: &Path) -> Result<()> {
        let file = File::create(output)?;
        let mut builder = Builder::new(file);

        // Add all files from source directory
        builder.append_dir_all(".", &self.source_dir)
            .context("Failed to add files to data tar")?;

        builder.finish()?;
        Ok(())
    }

    /// Compress a file with zstd
    fn compress_zstd(&self, input: &Path, output: &Path) -> Result<()> {
        let input_file = File::open(input)?;
        let output_file = File::create(output)?;

        let mut encoder = zstd::stream::Encoder::new(output_file, 19)?;
        let mut reader = BufReader::new(input_file);

        std::io::copy(&mut reader, &mut encoder)?;
        encoder.finish()?;

        Ok(())
    }

    /// Create the final package archive
    fn create_package_archive(
        &self,
        output: &Path,
        temp_dir: &Path,
        data_zst: &Path,
    ) -> Result<()> {
        let file = File::create(output)?;
        let mut builder = Builder::new(file);

        // Add metadata files first
        let pkginfo = temp_dir.join(".PKGINFO");
        builder.append_path_with_name(&pkginfo, ".PKGINFO")?;

        let files = temp_dir.join(".FILES");
        builder.append_path_with_name(&files, ".FILES")?;

        let install = temp_dir.join(".INSTALL");
        if install.exists() {
            builder.append_path_with_name(&install, ".INSTALL")?;
        }

        // Add compressed data
        builder.append_path_with_name(data_zst, "data.tar.zst")?;

        builder.finish()?;
        Ok(())
    }

    /// Get the package info
    pub fn info(&self) -> &PackageInfo {
        &self.info
    }

    /// Get the file list
    pub fn files(&self) -> &[FileEntry] {
        &self.files
    }
}

/// Package archive reader
pub struct PackageArchiveReader {
    path: PathBuf,
}

impl PackageArchiveReader {
    /// Open a package archive
    pub fn open(path: &Path) -> Result<Self> {
        if !path.exists() {
            bail!("Package file not found: {}", path.display());
        }
        Ok(Self {
            path: path.to_path_buf(),
        })
    }

    /// Read the package info
    pub fn read_info(&self) -> Result<PackageInfo> {
        let file = File::open(&self.path)?;
        let mut archive = Archive::new(file);

        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;

            if path.to_string_lossy() == ".PKGINFO" {
                let mut content = String::new();
                entry.read_to_string(&mut content)?;
                return toml::from_str(&content).context("Failed to parse .PKGINFO");
            }
        }

        bail!("Package does not contain .PKGINFO")
    }

    /// Read the file list
    pub fn read_files(&self) -> Result<Vec<FileEntry>> {
        let file = File::open(&self.path)?;
        let mut archive = Archive::new(file);

        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;

            if path.to_string_lossy() == ".FILES" {
                let mut content = String::new();
                entry.read_to_string(&mut content)?;
                let file_list: FileList = toml::from_str(&content).context("Failed to parse .FILES")?;
                return Ok(file_list.files);
            }
        }

        bail!("Package does not contain .FILES")
    }

    /// Read install scripts
    pub fn read_scripts(&self) -> Result<Option<InstallScripts>> {
        let file = File::open(&self.path)?;
        let mut archive = Archive::new(file);

        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;

            if path.to_string_lossy() == ".INSTALL" {
                let mut content = String::new();
                entry.read_to_string(&mut content)?;
                return Ok(Some(toml::from_str(&content).context("Failed to parse .INSTALL")?));
            }
        }

        Ok(None)
    }

    /// Extract the data archive to a directory
    pub fn extract_data(&self, dest: &Path) -> Result<()> {
        fs::create_dir_all(dest)?;

        let file = File::open(&self.path)?;
        let mut archive = Archive::new(file);

        // First, find and extract data.tar.zst
        let temp_dir = tempfile::tempdir()?;
        let data_zst = temp_dir.path().join("data.tar.zst");

        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;

            if path.to_string_lossy() == "data.tar.zst" {
                let mut out = File::create(&data_zst)?;
                std::io::copy(&mut entry, &mut out)?;
                break;
            }
        }

        if !data_zst.exists() {
            bail!("Package does not contain data.tar.zst");
        }

        // Decompress zstd
        let data_tar = temp_dir.path().join("data.tar");
        {
            let zst_file = File::open(&data_zst)?;
            let tar_file = File::create(&data_tar)?;
            let mut decoder = zstd::stream::Decoder::new(zst_file)?;
            let mut writer = BufWriter::new(tar_file);
            std::io::copy(&mut decoder, &mut writer)?;
        }

        // Extract tar
        let tar_file = File::open(&data_tar)?;
        let mut data_archive = Archive::new(tar_file);
        data_archive.unpack(dest)?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_package_info_filename() {
        let info = PackageInfo {
            name: "hello".to_string(),
            version: "2.12".to_string(),
            release: 1,
            summary: String::new(),
            description: String::new(),
            license: String::new(),
            url: String::new(),
            maintainer: String::new(),
            build_time: 0,
            installed_size: 0,
            depends: HashMap::new(),
            build_depends: HashMap::new(),
            optional_depends: HashMap::new(),
            arch: "x86_64".to_string(),
        };

        assert_eq!(info.filename(), "hello-2.12-1.x86_64.rookpkg");
    }

    #[test]
    fn test_install_scripts_has_scripts() {
        let empty = InstallScripts::default();
        assert!(!empty.has_scripts());

        let with_post = InstallScripts {
            post_install: "echo hello".to_string(),
            ..Default::default()
        };
        assert!(with_post.has_scripts());
    }
}
