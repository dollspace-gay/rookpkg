//! CVE vulnerability tracking and auto-patching system
//!
//! This module provides functionality for:
//! - Querying CVE databases (NVD, OSV)
//! - Matching vulnerabilities to installed packages
//! - Fetching patches from upstream sources
//! - Auto-updating .rook specs with security fixes

mod database;
mod matcher;
mod patcher;

pub use database::{CveDatabase, CveRecord, NvdClient, OsvClient, ReferenceType, Severity};
pub use matcher::{CveMatcher, VulnerablePackage};
pub use patcher::{PatchFetcher, SpecUpdater};
// Note: PatchInfo is used internally and returned by PatchFetcher methods,
// but callers access it through the returned Vec without needing to import the type.

use crate::config::Config;
use anyhow::Result;
use std::collections::HashMap;

/// Result of a vulnerability audit
#[derive(Debug)]
pub struct AuditResult {
    /// Packages with known vulnerabilities
    pub vulnerable: Vec<VulnerablePackage>,
    /// Packages that are up to date
    pub secure: Vec<String>,
    /// Packages that couldn't be checked (not in CVE databases)
    pub unknown: Vec<String>,
    /// Total CVEs found
    pub total_cves: usize,
    /// Critical severity count
    pub critical_count: usize,
    /// High severity count
    pub high_count: usize,
    /// Medium severity count
    pub medium_count: usize,
    /// Low severity count
    pub low_count: usize,
}

impl AuditResult {
    /// Create a new empty audit result
    pub fn new() -> Self {
        Self {
            vulnerable: Vec::new(),
            secure: Vec::new(),
            unknown: Vec::new(),
            total_cves: 0,
            critical_count: 0,
            high_count: 0,
            medium_count: 0,
            low_count: 0,
        }
    }

    /// Check if any critical or high severity vulnerabilities were found
    pub fn has_severe_vulnerabilities(&self) -> bool {
        self.critical_count > 0 || self.high_count > 0
    }

    /// Check if any vulnerabilities were found
    pub fn has_vulnerabilities(&self) -> bool {
        !self.vulnerable.is_empty()
    }
}

impl Default for AuditResult {
    fn default() -> Self {
        Self::new()
    }
}

/// CVE auditor that coordinates vulnerability scanning
pub struct CveAuditor {
    nvd_client: NvdClient,
    osv_client: OsvClient,
    matcher: CveMatcher,
    patcher: PatchFetcher,
    /// Cache of CVE data by package name
    cve_cache: HashMap<String, Vec<CveRecord>>,
}

impl CveAuditor {
    /// Create a new CVE auditor
    pub fn new(config: &Config) -> Result<Self> {
        let cache_dir = config.paths.cache_dir.join("cve");
        std::fs::create_dir_all(&cache_dir)?;

        Ok(Self {
            nvd_client: NvdClient::new(cache_dir.clone())?,
            osv_client: OsvClient::new(cache_dir)?,
            matcher: CveMatcher::new(),
            patcher: PatchFetcher::new()?,
            cve_cache: HashMap::new(),
        })
    }

    /// Query CVE databases for a specific package
    pub fn query_package(&mut self, name: &str, version: &str) -> Result<Vec<CveRecord>> {
        let cache_key = format!("{}:{}", name, version);

        if let Some(cached) = self.cve_cache.get(&cache_key) {
            return Ok(cached.clone());
        }

        // Query both databases and merge results
        let mut cves = Vec::new();

        // Try OSV first (faster, more package-aware)
        match self.osv_client.query(name, version) {
            Ok(osv_cves) => cves.extend(osv_cves),
            Err(e) => tracing::debug!("OSV query failed for {}: {}", name, e),
        }

        // Then NVD for additional coverage
        match self.nvd_client.query(name, version) {
            Ok(nvd_cves) => {
                // Deduplicate by CVE ID
                for cve in nvd_cves {
                    if !cves.iter().any(|c| c.id == cve.id) {
                        cves.push(cve);
                    }
                }
            }
            Err(e) => tracing::debug!("NVD query failed for {}: {}", name, e),
        }

        // Cache the results
        self.cve_cache.insert(cache_key, cves.clone());

        Ok(cves)
    }

    /// Run a full audit of installed packages
    pub fn audit(&mut self, packages: &[(String, String)]) -> Result<AuditResult> {
        let mut result = AuditResult::new();

        for (name, version) in packages {
            match self.query_package(name, version) {
                Ok(cves) if cves.is_empty() => {
                    result.secure.push(name.clone());
                }
                Ok(cves) => {
                    let vuln = self.matcher.match_cves(name, version, &cves);
                    if vuln.cves.is_empty() {
                        result.secure.push(name.clone());
                    } else {
                        // Count severities
                        for cve in &vuln.cves {
                            result.total_cves += 1;
                            match cve.severity {
                                Severity::Critical => result.critical_count += 1,
                                Severity::High => result.high_count += 1,
                                Severity::Medium => result.medium_count += 1,
                                Severity::Low => result.low_count += 1,
                                Severity::Unknown => {}
                            }
                        }
                        result.vulnerable.push(vuln);
                    }
                }
                Err(e) => {
                    tracing::warn!("Could not check {}: {}", name, e);
                    result.unknown.push(name.clone());
                }
            }
        }

        Ok(result)
    }

    /// Get detailed information about a specific CVE
    pub fn get_cve(&self, cve_id: &str) -> Result<Option<CveRecord>> {
        // Try OSV first (usually faster)
        if let Ok(Some(record)) = self.osv_client.get_cve(cve_id) {
            return Ok(Some(record));
        }

        // Fall back to NVD
        self.nvd_client.get_cve(cve_id)
    }

    /// Clear all cached CVE data
    pub fn clear_cache(&mut self) -> Result<()> {
        self.osv_client.clear_cache()?;
        self.nvd_client.clear_cache()?;
        self.cve_cache.clear();
        Ok(())
    }

    /// Get the patch fetcher for downloading patches
    pub fn patcher(&self) -> &PatchFetcher {
        &self.patcher
    }
}
