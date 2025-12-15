//! Delta package support for incremental updates
//!
//! This module implements binary delta generation and application for package updates.
//! Instead of downloading a full package, users can download a smaller delta file
//! that contains only the differences between the old and new package versions.
//!
//! ## Delta Format (.rookdelta)
//!
//! A delta file is a tar archive containing:
//! - `.DELTAINFO` - Delta metadata (TOML format)
//! - `data.delta.zst` - Compressed binary diff of data.tar.zst
//!
//! ## Usage
//!
//! Building a delta:
//! ```ignore
//! let delta = DeltaBuilder::new(&old_pkg, &new_pkg)?;
//! let delta_path = delta.build(output_dir)?;
//! ```
//!
//! Applying a delta:
//! ```ignore
//! let applier = DeltaApplier::new(&old_pkg, &delta_file)?;
//! let new_pkg = applier.apply(output_dir)?;
//! ```

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::archive::{PackageArchiveReader, PackageInfo};
use crate::download::compute_sha256;

/// Delta file extension
pub const DELTA_EXTENSION: &str = ".rookdelta";

/// Minimum savings percentage to generate a delta (if delta is >90% of full size, skip)
const MIN_SAVINGS_PERCENT: u64 = 10;

/// Block size for delta computation (4KB)
const BLOCK_SIZE: usize = 4096;

/// Delta package metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeltaInfo {
    /// Source package name
    pub name: String,
    /// Source (old) package version
    pub old_version: String,
    /// Source release number
    pub old_release: u32,
    /// Target (new) package version
    pub new_version: String,
    /// Target release number
    pub new_release: u32,
    /// Architecture
    pub arch: String,
    /// SHA256 of the old package
    pub old_sha256: String,
    /// SHA256 of the new package
    pub new_sha256: String,
    /// Size of the old package
    pub old_size: u64,
    /// Size of the new package
    pub new_size: u64,
    /// Size of this delta file
    pub delta_size: u64,
    /// Delta generation timestamp
    pub created: i64,
    /// Algorithm used for delta generation
    pub algorithm: DeltaAlgorithm,
}

impl DeltaInfo {
    /// Get the delta filename
    pub fn filename(&self) -> String {
        format!(
            "{}-{}-{}_to_{}-{}.{}{}",
            self.name,
            self.old_version,
            self.old_release,
            self.new_version,
            self.new_release,
            self.arch,
            DELTA_EXTENSION
        )
    }

    /// Calculate the savings percentage
    pub fn savings_percent(&self) -> f64 {
        if self.new_size == 0 {
            return 0.0;
        }
        ((self.new_size - self.delta_size) as f64 / self.new_size as f64) * 100.0
    }

    /// Check if applying this delta is worthwhile
    pub fn is_worthwhile(&self) -> bool {
        self.savings_percent() >= MIN_SAVINGS_PERCENT as f64
    }
}

/// Delta algorithm type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeltaAlgorithm {
    /// Block-based binary diff (similar to bsdiff)
    Bsdiff,
    /// Simple xdelta-style diff
    Xdelta,
}

impl Default for DeltaAlgorithm {
    fn default() -> Self {
        Self::Bsdiff
    }
}

/// A delta operation in the binary diff
#[derive(Debug, Clone, Serialize, Deserialize)]
enum DeltaOp {
    /// Copy bytes from the old file at given offset and length
    Copy { offset: u64, length: u64 },
    /// Insert new bytes (stored inline)
    Insert { data: Vec<u8> },
}

/// Delta data structure (internal format)
#[derive(Debug, Clone, Serialize, Deserialize)]
struct DeltaData {
    /// Operations to transform old -> new
    ops: Vec<DeltaOp>,
    /// Expected size of the output
    output_size: u64,
    /// Checksum of the output
    output_sha256: String,
}

/// Delta builder - creates delta packages from two package versions
pub struct DeltaBuilder {
    /// Old package path
    old_path: PathBuf,
    /// New package path
    new_path: PathBuf,
    /// Old package info
    old_info: PackageInfo,
    /// New package info
    new_info: PackageInfo,
}

impl DeltaBuilder {
    /// Create a new delta builder
    pub fn new(old_package: &Path, new_package: &Path) -> Result<Self> {
        // Read package info from both packages
        let old_reader = PackageArchiveReader::open(old_package)?;
        let new_reader = PackageArchiveReader::open(new_package)?;

        let old_info = old_reader.read_info()?;
        let new_info = new_reader.read_info()?;

        // Verify packages are for the same package name
        if old_info.name != new_info.name {
            bail!(
                "Package names don't match: {} vs {}",
                old_info.name,
                new_info.name
            );
        }

        // Verify architectures match
        if old_info.arch != new_info.arch {
            bail!(
                "Package architectures don't match: {} vs {}",
                old_info.arch,
                new_info.arch
            );
        }

        Ok(Self {
            old_path: old_package.to_path_buf(),
            new_path: new_package.to_path_buf(),
            old_info,
            new_info,
        })
    }

    /// Build the delta package
    pub fn build(&self, output_dir: &Path) -> Result<PathBuf> {
        fs::create_dir_all(output_dir)?;

        let temp_dir = tempfile::tempdir()?;

        // Extract data.tar.zst from both packages
        let old_data = self.extract_data_archive(&self.old_path, temp_dir.path(), "old")?;
        let new_data = self.extract_data_archive(&self.new_path, temp_dir.path(), "new")?;

        // Compute checksums
        let old_sha256 = compute_sha256(&self.old_path)?;
        let new_sha256 = compute_sha256(&self.new_path)?;
        let old_size = fs::metadata(&self.old_path)?.len();
        let new_size = fs::metadata(&self.new_path)?.len();

        // Generate the binary diff
        let delta_data = self.generate_diff(&old_data, &new_data)?;

        // Serialize and compress the delta
        let delta_bytes = self.serialize_delta(&delta_data)?;
        let delta_zst_path = temp_dir.path().join("data.delta.zst");
        self.compress_data(&delta_bytes, &delta_zst_path)?;

        // Create delta info
        let delta_info = DeltaInfo {
            name: self.new_info.name.clone(),
            old_version: self.old_info.version.clone(),
            old_release: self.old_info.release,
            new_version: self.new_info.version.clone(),
            new_release: self.new_info.release,
            arch: self.new_info.arch.clone(),
            old_sha256,
            new_sha256,
            old_size,
            new_size,
            delta_size: 0, // Will be updated after packaging
            created: chrono::Utc::now().timestamp(),
            algorithm: DeltaAlgorithm::Bsdiff,
        };

        // Check if delta is worthwhile
        let delta_zst_size = fs::metadata(&delta_zst_path)?.len();
        let estimated_savings = if new_size > 0 {
            ((new_size - delta_zst_size) as f64 / new_size as f64) * 100.0
        } else {
            0.0
        };

        if estimated_savings < MIN_SAVINGS_PERCENT as f64 {
            tracing::warn!(
                "Delta provides only {:.1}% savings (minimum: {}%), skipping",
                estimated_savings,
                MIN_SAVINGS_PERCENT
            );
            bail!(
                "Delta not worthwhile: only {:.1}% savings",
                estimated_savings
            );
        }

        // Write delta info
        let info_path = temp_dir.path().join(".DELTAINFO");
        let info_content = toml::to_string_pretty(&delta_info)?;
        fs::write(&info_path, &info_content)?;

        // Create the delta package
        let output_path = output_dir.join(delta_info.filename());
        self.create_delta_archive(&output_path, temp_dir.path(), &delta_zst_path)?;

        // Update delta size in info (for logging)
        let final_size = fs::metadata(&output_path)?.len();
        tracing::info!(
            "Created delta: {} ({} bytes, {:.1}% of full package)",
            output_path.display(),
            final_size,
            (final_size as f64 / new_size as f64) * 100.0
        );

        Ok(output_path)
    }

    /// Extract data.tar.zst from a package
    fn extract_data_archive(&self, package: &Path, temp_dir: &Path, prefix: &str) -> Result<PathBuf> {
        let file = File::open(package)?;
        let mut archive = tar::Archive::new(file);

        let data_zst = temp_dir.join(format!("{}_data.tar.zst", prefix));

        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;

            if path.to_string_lossy() == "data.tar.zst" {
                let mut out = File::create(&data_zst)?;
                std::io::copy(&mut entry, &mut out)?;
                return Ok(data_zst);
            }
        }

        bail!("Package does not contain data.tar.zst")
    }

    /// Generate binary diff between old and new data
    fn generate_diff(&self, old_data: &Path, new_data: &Path) -> Result<DeltaData> {
        let old_bytes = fs::read(old_data)?;
        let new_bytes = fs::read(new_data)?;

        // Compute output checksum
        let mut hasher = Sha256::new();
        hasher.update(&new_bytes);
        let output_sha256 = hex::encode(hasher.finalize());

        // Use block-based diffing algorithm
        let ops = self.compute_block_diff(&old_bytes, &new_bytes)?;

        Ok(DeltaData {
            ops,
            output_size: new_bytes.len() as u64,
            output_sha256,
        })
    }

    /// Compute block-based diff (simplified bsdiff-style algorithm)
    fn compute_block_diff(&self, old: &[u8], new: &[u8]) -> Result<Vec<DeltaOp>> {
        let mut ops = Vec::new();
        let mut new_pos = 0;

        // Build a hash table of old file blocks for quick lookup
        let mut block_index: HashMap<u64, Vec<usize>> = HashMap::new();
        for (i, chunk) in old.chunks(BLOCK_SIZE).enumerate() {
            let hash = self.hash_block(chunk);
            block_index.entry(hash).or_default().push(i * BLOCK_SIZE);
        }

        // Scan through new file looking for matching blocks
        let mut pending_insert: Vec<u8> = Vec::new();

        while new_pos < new.len() {
            let remaining = new.len() - new_pos;
            let block_len = remaining.min(BLOCK_SIZE);
            let new_block = &new[new_pos..new_pos + block_len];
            let block_hash = self.hash_block(new_block);

            // Try to find a matching block in old file
            let mut found_match = false;
            if let Some(positions) = block_index.get(&block_hash) {
                for &old_pos in positions {
                    // Verify the match (hash collision check)
                    let old_end = (old_pos + block_len).min(old.len());
                    if old_end - old_pos == block_len && &old[old_pos..old_end] == new_block {
                        // Found a match! First, flush any pending inserts
                        if !pending_insert.is_empty() {
                            ops.push(DeltaOp::Insert {
                                data: std::mem::take(&mut pending_insert),
                            });
                        }

                        // Try to extend the match forward
                        let mut match_len = block_len;
                        while new_pos + match_len < new.len()
                            && old_pos + match_len < old.len()
                            && new[new_pos + match_len] == old[old_pos + match_len]
                        {
                            match_len += 1;
                        }

                        ops.push(DeltaOp::Copy {
                            offset: old_pos as u64,
                            length: match_len as u64,
                        });

                        new_pos += match_len;
                        found_match = true;
                        break;
                    }
                }
            }

            if !found_match {
                // No match found, add to pending inserts
                pending_insert.push(new[new_pos]);
                new_pos += 1;
            }
        }

        // Flush any remaining pending inserts
        if !pending_insert.is_empty() {
            ops.push(DeltaOp::Insert { data: pending_insert });
        }

        // Merge adjacent copy operations
        ops = self.merge_ops(ops);

        Ok(ops)
    }

    /// Simple hash function for blocks
    fn hash_block(&self, data: &[u8]) -> u64 {
        // FNV-1a hash
        let mut hash: u64 = 0xcbf29ce484222325;
        for &byte in data {
            hash ^= byte as u64;
            hash = hash.wrapping_mul(0x100000001b3);
        }
        hash
    }

    /// Merge adjacent operations where possible
    fn merge_ops(&self, ops: Vec<DeltaOp>) -> Vec<DeltaOp> {
        let mut merged = Vec::new();

        for op in ops {
            match (&mut merged.last_mut(), &op) {
                // Merge adjacent inserts
                (Some(DeltaOp::Insert { data: existing }), DeltaOp::Insert { data: new }) => {
                    existing.extend(new);
                }
                // Merge adjacent copies if they're contiguous
                (
                    Some(DeltaOp::Copy {
                        offset: existing_off,
                        length: existing_len,
                    }),
                    DeltaOp::Copy { offset, length },
                ) if *existing_off + *existing_len == *offset => {
                    *existing_len += length;
                }
                _ => {
                    merged.push(op);
                }
            }
        }

        merged
    }

    /// Serialize delta data to bytes
    fn serialize_delta(&self, delta: &DeltaData) -> Result<Vec<u8>> {
        // Use bincode for compact binary serialization
        let mut output = Vec::new();

        // Write header
        output.extend_from_slice(b"ROOKDELTA\x01"); // Magic + version

        // Write output info
        output.extend_from_slice(&delta.output_size.to_le_bytes());
        let sha_bytes = hex::decode(&delta.output_sha256)?;
        output.extend_from_slice(&sha_bytes);

        // Write number of operations
        output.extend_from_slice(&(delta.ops.len() as u32).to_le_bytes());

        // Write each operation
        for op in &delta.ops {
            match op {
                DeltaOp::Copy { offset, length } => {
                    output.push(0x01); // Copy marker
                    output.extend_from_slice(&offset.to_le_bytes());
                    output.extend_from_slice(&length.to_le_bytes());
                }
                DeltaOp::Insert { data } => {
                    output.push(0x02); // Insert marker
                    output.extend_from_slice(&(data.len() as u64).to_le_bytes());
                    output.extend_from_slice(data);
                }
            }
        }

        Ok(output)
    }

    /// Compress data with zstd
    fn compress_data(&self, data: &[u8], output: &Path) -> Result<()> {
        let file = File::create(output)?;
        let mut encoder = zstd::stream::Encoder::new(file, 19)?;
        encoder.write_all(data)?;
        encoder.finish()?;
        Ok(())
    }

    /// Create the final delta archive
    fn create_delta_archive(
        &self,
        output: &Path,
        temp_dir: &Path,
        delta_zst: &Path,
    ) -> Result<()> {
        let file = File::create(output)?;
        let mut builder = tar::Builder::new(file);

        // Add delta info
        let info_path = temp_dir.join(".DELTAINFO");
        builder.append_path_with_name(&info_path, ".DELTAINFO")?;

        // Add compressed delta
        builder.append_path_with_name(delta_zst, "data.delta.zst")?;

        builder.finish()?;
        Ok(())
    }
}

/// Delta applier - applies a delta to an old package to produce a new package
pub struct DeltaApplier {
    /// Old package path
    old_path: PathBuf,
    /// Delta file path
    delta_path: PathBuf,
    /// Delta info
    delta_info: DeltaInfo,
}

impl DeltaApplier {
    /// Create a new delta applier
    pub fn new(old_package: &Path, delta_file: &Path) -> Result<Self> {
        // Read delta info
        let delta_info = Self::read_delta_info(delta_file)?;

        // Verify old package matches
        let old_sha256 = compute_sha256(old_package)?;
        if old_sha256 != delta_info.old_sha256 {
            bail!(
                "Old package checksum mismatch: expected {}, got {}",
                delta_info.old_sha256,
                old_sha256
            );
        }

        Ok(Self {
            old_path: old_package.to_path_buf(),
            delta_path: delta_file.to_path_buf(),
            delta_info,
        })
    }

    /// Read delta info from a delta file
    fn read_delta_info(delta_path: &Path) -> Result<DeltaInfo> {
        let file = File::open(delta_path)?;
        let mut archive = tar::Archive::new(file);

        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;

            if path.to_string_lossy() == ".DELTAINFO" {
                let mut content = String::new();
                entry.read_to_string(&mut content)?;
                return toml::from_str(&content).context("Failed to parse .DELTAINFO");
            }
        }

        bail!("Delta file does not contain .DELTAINFO")
    }

    /// Apply the delta to produce the new package
    pub fn apply(&self, output_dir: &Path) -> Result<PathBuf> {
        fs::create_dir_all(output_dir)?;

        let temp_dir = tempfile::tempdir()?;

        // Extract data.tar.zst from old package
        let old_data = self.extract_data_archive(&self.old_path, temp_dir.path())?;

        // Extract and decompress delta
        let delta_data = self.extract_and_decompress_delta(temp_dir.path())?;

        // Apply delta to produce new data
        let new_data_path = temp_dir.path().join("new_data.tar.zst");
        self.apply_delta(&old_data, &delta_data, &new_data_path)?;

        // Reconstruct the new package
        let output_path = self.reconstruct_package(&new_data_path, output_dir)?;

        // Verify the result
        let new_sha256 = compute_sha256(&output_path)?;
        if new_sha256 != self.delta_info.new_sha256 {
            fs::remove_file(&output_path).ok();
            bail!(
                "Reconstructed package checksum mismatch: expected {}, got {}",
                self.delta_info.new_sha256,
                new_sha256
            );
        }

        tracing::info!(
            "Successfully applied delta to create {}",
            output_path.display()
        );

        Ok(output_path)
    }

    /// Extract data.tar.zst from a package
    fn extract_data_archive(&self, package: &Path, temp_dir: &Path) -> Result<PathBuf> {
        let file = File::open(package)?;
        let mut archive = tar::Archive::new(file);

        let data_zst = temp_dir.join("old_data.tar.zst");

        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;

            if path.to_string_lossy() == "data.tar.zst" {
                let mut out = File::create(&data_zst)?;
                std::io::copy(&mut entry, &mut out)?;
                return Ok(data_zst);
            }
        }

        bail!("Package does not contain data.tar.zst")
    }

    /// Extract and decompress the delta data
    fn extract_and_decompress_delta(&self, temp_dir: &Path) -> Result<DeltaData> {
        let file = File::open(&self.delta_path)?;
        let mut archive = tar::Archive::new(file);

        let delta_zst = temp_dir.join("data.delta.zst");

        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;

            if path.to_string_lossy() == "data.delta.zst" {
                let mut out = File::create(&delta_zst)?;
                std::io::copy(&mut entry, &mut out)?;
                break;
            }
        }

        if !delta_zst.exists() {
            bail!("Delta file does not contain data.delta.zst");
        }

        // Decompress
        let zst_file = File::open(&delta_zst)?;
        let mut decoder = zstd::stream::Decoder::new(zst_file)?;
        let mut delta_bytes = Vec::new();
        decoder.read_to_end(&mut delta_bytes)?;

        // Parse delta data
        self.parse_delta(&delta_bytes)
    }

    /// Parse serialized delta data
    fn parse_delta(&self, data: &[u8]) -> Result<DeltaData> {
        let mut pos = 0;

        // Check magic
        if data.len() < 10 || &data[0..10] != b"ROOKDELTA\x01" {
            bail!("Invalid delta file format");
        }
        pos += 10;

        // Read output size
        if pos + 8 > data.len() {
            bail!("Delta file truncated");
        }
        let output_size = u64::from_le_bytes(data[pos..pos + 8].try_into()?);
        pos += 8;

        // Read output SHA256
        if pos + 32 > data.len() {
            bail!("Delta file truncated");
        }
        let output_sha256 = hex::encode(&data[pos..pos + 32]);
        pos += 32;

        // Read operation count
        if pos + 4 > data.len() {
            bail!("Delta file truncated");
        }
        let op_count = u32::from_le_bytes(data[pos..pos + 4].try_into()?) as usize;
        pos += 4;

        // Read operations
        let mut ops = Vec::with_capacity(op_count);
        for _ in 0..op_count {
            if pos >= data.len() {
                bail!("Delta file truncated");
            }

            match data[pos] {
                0x01 => {
                    // Copy
                    pos += 1;
                    if pos + 16 > data.len() {
                        bail!("Delta file truncated");
                    }
                    let offset = u64::from_le_bytes(data[pos..pos + 8].try_into()?);
                    pos += 8;
                    let length = u64::from_le_bytes(data[pos..pos + 8].try_into()?);
                    pos += 8;
                    ops.push(DeltaOp::Copy { offset, length });
                }
                0x02 => {
                    // Insert
                    pos += 1;
                    if pos + 8 > data.len() {
                        bail!("Delta file truncated");
                    }
                    let length = u64::from_le_bytes(data[pos..pos + 8].try_into()?) as usize;
                    pos += 8;
                    if pos + length > data.len() {
                        bail!("Delta file truncated");
                    }
                    let insert_data = data[pos..pos + length].to_vec();
                    pos += length;
                    ops.push(DeltaOp::Insert { data: insert_data });
                }
                _ => {
                    bail!("Unknown delta operation: {}", data[pos]);
                }
            }
        }

        Ok(DeltaData {
            ops,
            output_size,
            output_sha256,
        })
    }

    /// Apply delta operations to produce new data
    fn apply_delta(&self, old_data_path: &Path, delta: &DeltaData, output: &Path) -> Result<()> {
        // Read and decompress old data
        let old_zst = File::open(old_data_path)?;
        let mut decoder = zstd::stream::Decoder::new(old_zst)?;
        let mut old_bytes = Vec::new();
        decoder.read_to_end(&mut old_bytes)?;

        // Apply operations
        let mut new_bytes = Vec::with_capacity(delta.output_size as usize);

        for op in &delta.ops {
            match op {
                DeltaOp::Copy { offset, length } => {
                    let start = *offset as usize;
                    let end = start + *length as usize;
                    if end > old_bytes.len() {
                        bail!(
                            "Delta copy operation out of bounds: {}..{} (old file size: {})",
                            start,
                            end,
                            old_bytes.len()
                        );
                    }
                    new_bytes.extend_from_slice(&old_bytes[start..end]);
                }
                DeltaOp::Insert { data } => {
                    new_bytes.extend_from_slice(data);
                }
            }
        }

        // Verify output size
        if new_bytes.len() as u64 != delta.output_size {
            bail!(
                "Output size mismatch: expected {}, got {}",
                delta.output_size,
                new_bytes.len()
            );
        }

        // Verify checksum
        let mut hasher = Sha256::new();
        hasher.update(&new_bytes);
        let actual_sha256 = hex::encode(hasher.finalize());
        if actual_sha256 != delta.output_sha256 {
            bail!(
                "Output checksum mismatch: expected {}, got {}",
                delta.output_sha256,
                actual_sha256
            );
        }

        // Compress and write output
        let file = File::create(output)?;
        let mut encoder = zstd::stream::Encoder::new(file, 19)?;
        encoder.write_all(&new_bytes)?;
        encoder.finish()?;

        Ok(())
    }

    /// Reconstruct the new package from the delta result
    fn reconstruct_package(&self, new_data: &Path, output_dir: &Path) -> Result<PathBuf> {
        let temp_dir = tempfile::tempdir()?;

        // Extract metadata from old package (we'll update version info)
        let old_file = File::open(&self.old_path)?;
        let mut old_archive = tar::Archive::new(old_file);

        // Copy metadata files, updating .PKGINFO
        let pkginfo_path = temp_dir.path().join(".PKGINFO");
        let files_path = temp_dir.path().join(".FILES");
        let install_path = temp_dir.path().join(".INSTALL");

        for entry in old_archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;
            let path_str = path.to_string_lossy();

            match path_str.as_ref() {
                ".PKGINFO" => {
                    // Read and update version info
                    let mut content = String::new();
                    entry.read_to_string(&mut content)?;
                    let mut info: PackageInfo = toml::from_str(&content)?;
                    info.version = self.delta_info.new_version.clone();
                    info.release = self.delta_info.new_release;
                    info.build_time = chrono::Utc::now().timestamp();
                    let new_content = toml::to_string_pretty(&info)?;
                    fs::write(&pkginfo_path, new_content)?;
                }
                ".FILES" => {
                    let mut out = File::create(&files_path)?;
                    std::io::copy(&mut entry, &mut out)?;
                }
                ".INSTALL" => {
                    let mut out = File::create(&install_path)?;
                    std::io::copy(&mut entry, &mut out)?;
                }
                _ => {}
            }
        }

        // Create the new package
        let output_filename = format!(
            "{}-{}-{}.{}.rookpkg",
            self.delta_info.name,
            self.delta_info.new_version,
            self.delta_info.new_release,
            self.delta_info.arch
        );
        let output_path = output_dir.join(&output_filename);

        let file = File::create(&output_path)?;
        let mut builder = tar::Builder::new(file);

        // Add metadata
        if pkginfo_path.exists() {
            builder.append_path_with_name(&pkginfo_path, ".PKGINFO")?;
        }
        if files_path.exists() {
            builder.append_path_with_name(&files_path, ".FILES")?;
        }
        if install_path.exists() {
            builder.append_path_with_name(&install_path, ".INSTALL")?;
        }

        // Add new data
        builder.append_path_with_name(new_data, "data.tar.zst")?;

        builder.finish()?;

        Ok(output_path)
    }

    /// Get the delta info
    pub fn info(&self) -> &DeltaInfo {
        &self.delta_info
    }
}

/// Delta index entry in repository
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeltaEntry {
    /// Source (old) version
    pub from_version: String,
    /// Source release
    pub from_release: u32,
    /// Target (new) version
    pub to_version: String,
    /// Target release
    pub to_release: u32,
    /// Delta file path (relative to repo)
    pub filename: String,
    /// Delta file size
    pub size: u64,
    /// SHA256 of delta file
    pub sha256: String,
}

/// Delta index for a package (all available deltas)
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PackageDeltaIndex {
    /// Package name
    pub name: String,
    /// Available deltas
    pub deltas: Vec<DeltaEntry>,
}

impl PackageDeltaIndex {
    /// Create a new delta index for a package
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
            deltas: Vec::new(),
        }
    }

    /// Add a delta entry
    pub fn add_delta(&mut self, entry: DeltaEntry) {
        self.deltas.push(entry);
    }

    /// Find a delta for upgrading from a specific version
    pub fn find_delta(&self, from_version: &str, from_release: u32, to_version: &str, to_release: u32) -> Option<&DeltaEntry> {
        self.deltas.iter().find(|d| {
            d.from_version == from_version
                && d.from_release == from_release
                && d.to_version == to_version
                && d.to_release == to_release
        })
    }

    /// Find any delta that can upgrade from a specific version
    pub fn find_delta_from(&self, from_version: &str, from_release: u32) -> Option<&DeltaEntry> {
        self.deltas
            .iter()
            .find(|d| d.from_version == from_version && d.from_release == from_release)
    }
}

/// Repository-wide delta index
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RepoDeltaIndex {
    /// Index version
    pub version: u32,
    /// When the index was generated
    pub generated: chrono::DateTime<chrono::Utc>,
    /// Delta indices per package
    pub packages: HashMap<String, PackageDeltaIndex>,
}

impl RepoDeltaIndex {
    /// Create a new repository delta index
    pub fn new() -> Self {
        Self {
            version: 1,
            generated: chrono::Utc::now(),
            packages: HashMap::new(),
        }
    }

    /// Add a delta for a package
    pub fn add_delta(&mut self, package: &str, entry: DeltaEntry) {
        self.packages
            .entry(package.to_string())
            .or_insert_with(|| PackageDeltaIndex::new(package))
            .add_delta(entry);
        self.generated = chrono::Utc::now();
    }

    /// Find a delta for a package upgrade
    pub fn find_delta(
        &self,
        package: &str,
        from_version: &str,
        from_release: u32,
        to_version: &str,
        to_release: u32,
    ) -> Option<&DeltaEntry> {
        self.packages
            .get(package)
            .and_then(|idx| idx.find_delta(from_version, from_release, to_version, to_release))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_delta_info_filename() {
        let info = DeltaInfo {
            name: "hello".to_string(),
            old_version: "1.0".to_string(),
            old_release: 1,
            new_version: "1.1".to_string(),
            new_release: 1,
            arch: "x86_64".to_string(),
            old_sha256: "abc".to_string(),
            new_sha256: "def".to_string(),
            old_size: 1000,
            new_size: 1200,
            delta_size: 200,
            created: 0,
            algorithm: DeltaAlgorithm::Bsdiff,
        };

        assert_eq!(
            info.filename(),
            "hello-1.0-1_to_1.1-1.x86_64.rookdelta"
        );
    }

    #[test]
    fn test_delta_info_savings() {
        let info = DeltaInfo {
            name: "test".to_string(),
            old_version: "1.0".to_string(),
            old_release: 1,
            new_version: "1.1".to_string(),
            new_release: 1,
            arch: "x86_64".to_string(),
            old_sha256: "abc".to_string(),
            new_sha256: "def".to_string(),
            old_size: 1000,
            new_size: 1000,
            delta_size: 200,
            created: 0,
            algorithm: DeltaAlgorithm::Bsdiff,
        };

        assert!((info.savings_percent() - 80.0).abs() < 0.1);
        assert!(info.is_worthwhile());

        let bad_delta = DeltaInfo {
            delta_size: 950,
            ..info
        };
        assert!((bad_delta.savings_percent() - 5.0).abs() < 0.1);
        assert!(!bad_delta.is_worthwhile());
    }

    #[test]
    fn test_delta_algorithm_default() {
        assert_eq!(DeltaAlgorithm::default(), DeltaAlgorithm::Bsdiff);
    }

    #[test]
    fn test_package_delta_index() {
        let mut index = PackageDeltaIndex::new("hello");

        index.add_delta(DeltaEntry {
            from_version: "1.0".to_string(),
            from_release: 1,
            to_version: "1.1".to_string(),
            to_release: 1,
            filename: "hello-1.0-1_to_1.1-1.x86_64.rookdelta".to_string(),
            size: 200,
            sha256: "abc123".to_string(),
        });

        assert_eq!(index.deltas.len(), 1);

        let found = index.find_delta("1.0", 1, "1.1", 1);
        assert!(found.is_some());
        assert_eq!(found.unwrap().size, 200);

        let not_found = index.find_delta("1.0", 1, "2.0", 1);
        assert!(not_found.is_none());
    }

    #[test]
    fn test_repo_delta_index() {
        let mut index = RepoDeltaIndex::new();

        index.add_delta("hello", DeltaEntry {
            from_version: "1.0".to_string(),
            from_release: 1,
            to_version: "1.1".to_string(),
            to_release: 1,
            filename: "hello-1.0-1_to_1.1-1.x86_64.rookdelta".to_string(),
            size: 200,
            sha256: "abc123".to_string(),
        });

        index.add_delta("world", DeltaEntry {
            from_version: "2.0".to_string(),
            from_release: 1,
            to_version: "2.1".to_string(),
            to_release: 1,
            filename: "world-2.0-1_to_2.1-1.x86_64.rookdelta".to_string(),
            size: 300,
            sha256: "def456".to_string(),
        });

        assert_eq!(index.packages.len(), 2);

        let found = index.find_delta("hello", "1.0", 1, "1.1", 1);
        assert!(found.is_some());

        let not_found = index.find_delta("hello", "1.0", 1, "2.0", 1);
        assert!(not_found.is_none());
    }

    #[test]
    fn test_delta_serialization() {
        let delta = DeltaData {
            ops: vec![
                DeltaOp::Copy { offset: 0, length: 100 },
                DeltaOp::Insert { data: vec![1, 2, 3, 4] },
                DeltaOp::Copy { offset: 200, length: 50 },
            ],
            output_size: 154,
            output_sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_string(),
        };

        // Create a temporary builder just to test serialization
        let temp = tempdir().unwrap();
        let builder = DeltaBuilder {
            old_path: temp.path().join("old.rookpkg"),
            new_path: temp.path().join("new.rookpkg"),
            old_info: PackageInfo {
                name: "test".to_string(),
                version: "1.0".to_string(),
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
            },
            new_info: PackageInfo {
                name: "test".to_string(),
                version: "1.1".to_string(),
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
            },
        };

        let serialized = builder.serialize_delta(&delta).unwrap();

        // Verify magic
        assert_eq!(&serialized[0..10], b"ROOKDELTA\x01");

        // Parse it back using DeltaApplier's parse method
        let applier = DeltaApplier {
            old_path: temp.path().join("old.rookpkg"),
            delta_path: temp.path().join("delta.rookdelta"),
            delta_info: DeltaInfo {
                name: "test".to_string(),
                old_version: "1.0".to_string(),
                old_release: 1,
                new_version: "1.1".to_string(),
                new_release: 1,
                arch: "x86_64".to_string(),
                old_sha256: String::new(),
                new_sha256: String::new(),
                old_size: 0,
                new_size: 0,
                delta_size: 0,
                created: 0,
                algorithm: DeltaAlgorithm::Bsdiff,
            },
        };

        let parsed = applier.parse_delta(&serialized).unwrap();
        assert_eq!(parsed.output_size, delta.output_size);
        assert_eq!(parsed.output_sha256, delta.output_sha256);
        assert_eq!(parsed.ops.len(), delta.ops.len());
    }
}
