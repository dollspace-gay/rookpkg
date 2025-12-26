//! CVE database API clients for NVD and OSV
//!
//! Provides async-friendly clients for querying vulnerability databases
//! with caching, rate limiting, and retry logic.

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::cell::Cell;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// CVE severity levels (CVSS-based)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Severity {
    Critical, // CVSS 9.0-10.0
    High,     // CVSS 7.0-8.9
    Medium,   // CVSS 4.0-6.9
    Low,      // CVSS 0.1-3.9
    Unknown,  // No CVSS score available
}

impl Severity {
    /// Parse severity from CVSS score
    pub fn from_cvss(score: f64) -> Self {
        match score {
            s if s >= 9.0 => Severity::Critical,
            s if s >= 7.0 => Severity::High,
            s if s >= 4.0 => Severity::Medium,
            s if s > 0.0 => Severity::Low,
            _ => Severity::Unknown,
        }
    }

    /// Parse severity from string (OSV format)
    #[allow(dead_code)]
    pub fn from_str(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "CRITICAL" => Severity::Critical,
            "HIGH" => Severity::High,
            "MEDIUM" | "MODERATE" => Severity::Medium,
            "LOW" => Severity::Low,
            _ => Severity::Unknown,
        }
    }
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Severity::Critical => write!(f, "CRITICAL"),
            Severity::High => write!(f, "HIGH"),
            Severity::Medium => write!(f, "MEDIUM"),
            Severity::Low => write!(f, "LOW"),
            Severity::Unknown => write!(f, "UNKNOWN"),
        }
    }
}

/// A CVE record with all relevant information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CveRecord {
    /// CVE identifier (e.g., CVE-2024-1234)
    pub id: String,
    /// Short description
    pub summary: String,
    /// Detailed description
    pub description: String,
    /// CVSS severity
    pub severity: Severity,
    /// CVSS score (0.0-10.0)
    pub cvss_score: Option<f64>,
    /// Affected version ranges
    pub affected_versions: Vec<VersionRange>,
    /// Fixed version (if known)
    pub fixed_version: Option<String>,
    /// Published date
    pub published: Option<DateTime<Utc>>,
    /// Last modified date
    pub modified: Option<DateTime<Utc>>,
    /// Reference URLs (patches, advisories, etc.)
    pub references: Vec<Reference>,
    /// Source database (NVD, OSV, etc.)
    pub source: String,
}

/// Version range for affected packages
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VersionRange {
    /// Start version (inclusive)
    pub start: Option<String>,
    /// End version (exclusive)
    pub end: Option<String>,
    /// Specific affected versions
    pub exact: Vec<String>,
}

/// Reference URL with type information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reference {
    /// URL
    pub url: String,
    /// Type: PATCH, ADVISORY, VENDOR, etc.
    pub ref_type: ReferenceType,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ReferenceType {
    Patch,
    Advisory,
    Vendor,
    Article,
    Other,
}

impl ReferenceType {
    fn from_nvd_tag(tag: &str) -> Self {
        match tag.to_uppercase().as_str() {
            "PATCH" => ReferenceType::Patch,
            "VENDOR ADVISORY" | "THIRD PARTY ADVISORY" => ReferenceType::Advisory,
            "VENDOR" => ReferenceType::Vendor,
            _ => ReferenceType::Other,
        }
    }
}

/// Trait for CVE database providers
pub trait CveDatabase {
    /// Query for CVEs affecting a package
    fn query(&self, package: &str, version: &str) -> Result<Vec<CveRecord>>;

    /// Get a specific CVE by ID
    fn get_cve(&self, cve_id: &str) -> Result<Option<CveRecord>>;

    /// Clear the local cache
    fn clear_cache(&self) -> Result<()>;
}

/// Cache entry with timestamp
#[derive(Debug, Serialize, Deserialize)]
struct CacheEntry {
    timestamp: DateTime<Utc>,
    records: Vec<CveRecord>,
}

/// NVD (National Vulnerability Database) client
///
/// Uses the NVD 2.0 API: https://nvd.nist.gov/developers/vulnerabilities
pub struct NvdClient {
    client: Client,
    cache_dir: PathBuf,
    /// Rate limiting: max 5 requests per 30 seconds without API key
    /// Uses Cell for interior mutability to work with trait's &self
    last_request: Cell<Option<Instant>>,
    request_count: Cell<u32>,
    /// Optional API key for higher rate limits
    api_key: Option<String>,
}

impl NvdClient {
    const NVD_API_URL: &'static str = "https://services.nvd.nist.gov/rest/json/cves/2.0";
    const CACHE_TTL_HOURS: i64 = 24;
    const RATE_LIMIT_REQUESTS: u32 = 5;
    const RATE_LIMIT_WINDOW_SECS: u64 = 30;

    /// Create a new NVD client
    pub fn new(cache_dir: PathBuf) -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(60))
            .user_agent("rookpkg/0.1.0 (Rookery OS Package Manager)")
            .build()
            .context("Failed to create HTTP client")?;

        // Check for API key in environment
        let api_key = std::env::var("NVD_API_KEY").ok();

        fs::create_dir_all(&cache_dir)?;

        Ok(Self {
            client,
            cache_dir,
            last_request: Cell::new(None),
            request_count: Cell::new(0),
            api_key,
        })
    }

    /// Apply rate limiting (uses interior mutability)
    fn rate_limit(&self) {
        // With API key, limit is 50 requests per 30 seconds
        let max_requests = if self.api_key.is_some() { 50 } else { Self::RATE_LIMIT_REQUESTS };

        if let Some(last) = self.last_request.get() {
            let elapsed = last.elapsed();
            if elapsed < Duration::from_secs(Self::RATE_LIMIT_WINDOW_SECS) {
                if self.request_count.get() >= max_requests {
                    let sleep_time = Duration::from_secs(Self::RATE_LIMIT_WINDOW_SECS) - elapsed;
                    tracing::debug!("Rate limiting: sleeping for {:?}", sleep_time);
                    std::thread::sleep(sleep_time);
                    self.request_count.set(0);
                }
            } else {
                self.request_count.set(0);
            }
        }

        self.last_request.set(Some(Instant::now()));
        self.request_count.set(self.request_count.get() + 1);
    }

    /// Get cache file path for a package
    fn cache_path(&self, package: &str) -> PathBuf {
        let safe_name = package.replace(['/', '\\', ':'], "_");
        self.cache_dir.join(format!("nvd_{}.json", safe_name))
    }

    /// Check if cache is valid
    fn check_cache(&self, package: &str) -> Option<Vec<CveRecord>> {
        let path = self.cache_path(package);
        if !path.exists() {
            return None;
        }

        let content = fs::read_to_string(&path).ok()?;
        let entry: CacheEntry = serde_json::from_str(&content).ok()?;

        // Check TTL
        let age = Utc::now().signed_duration_since(entry.timestamp);
        if age.num_hours() > Self::CACHE_TTL_HOURS {
            return None;
        }

        Some(entry.records)
    }

    /// Save to cache
    fn save_cache(&self, package: &str, records: &[CveRecord]) -> Result<()> {
        let entry = CacheEntry {
            timestamp: Utc::now(),
            records: records.to_vec(),
        };

        let path = self.cache_path(package);
        let content = serde_json::to_string_pretty(&entry)?;
        fs::write(path, content)?;

        Ok(())
    }

    /// Parse NVD API response
    fn parse_response(&self, json: &str) -> Result<Vec<CveRecord>> {
        let response: NvdResponse = serde_json::from_str(json)
            .context("Failed to parse NVD response")?;

        let mut records = Vec::new();

        for vuln in response.vulnerabilities {
            let cve = vuln.cve;

            // Extract description (prefer English)
            let description = cve
                .descriptions
                .iter()
                .find(|d| d.lang == "en")
                .map(|d| d.value.clone())
                .unwrap_or_default();

            // Extract CVSS score and severity
            let (cvss_score, severity) = if let Some(metrics) = &cve.metrics {
                if let Some(cvss31) = metrics.cvss_metric_v31.as_ref().and_then(|v| v.first()) {
                    (
                        Some(cvss31.cvss_data.base_score),
                        Severity::from_cvss(cvss31.cvss_data.base_score),
                    )
                } else if let Some(cvss30) = metrics.cvss_metric_v30.as_ref().and_then(|v| v.first()) {
                    (
                        Some(cvss30.cvss_data.base_score),
                        Severity::from_cvss(cvss30.cvss_data.base_score),
                    )
                } else if let Some(cvss2) = metrics.cvss_metric_v2.as_ref().and_then(|v| v.first()) {
                    (
                        Some(cvss2.cvss_data.base_score),
                        Severity::from_cvss(cvss2.cvss_data.base_score),
                    )
                } else {
                    (None, Severity::Unknown)
                }
            } else {
                (None, Severity::Unknown)
            };

            // Extract references
            let references = cve
                .references
                .iter()
                .map(|r| Reference {
                    url: r.url.clone(),
                    ref_type: r
                        .tags
                        .as_ref()
                        .and_then(|t| t.first())
                        .map(|t| ReferenceType::from_nvd_tag(t))
                        .unwrap_or(ReferenceType::Other),
                })
                .collect();

            // Extract affected versions from configurations
            let affected_versions = self.extract_affected_versions(&cve);

            records.push(CveRecord {
                id: cve.id,
                summary: description.chars().take(200).collect(),
                description,
                severity,
                cvss_score,
                affected_versions,
                fixed_version: None, // NVD doesn't always have this
                published: cve.published.and_then(|s| DateTime::parse_from_rfc3339(&s).ok().map(|d| d.into())),
                modified: cve.last_modified.and_then(|s| DateTime::parse_from_rfc3339(&s).ok().map(|d| d.into())),
                references,
                source: "NVD".to_string(),
            });
        }

        Ok(records)
    }

    /// Extract affected version ranges from CPE configurations
    fn extract_affected_versions(&self, _cve: &NvdCve) -> Vec<VersionRange> {
        // CPE parsing is complex; for now return empty
        // Full implementation would parse configurations.nodes[].cpeMatch[]
        Vec::new()
    }
}

impl CveDatabase for NvdClient {
    fn query(&self, package: &str, version: &str) -> Result<Vec<CveRecord>> {
        // Check cache first (include version in cache key)
        let cache_key = format!("{}:{}", package, version);
        if let Some(cached) = self.check_cache(&cache_key) {
            tracing::debug!("NVD cache hit for {}:{}", package, version);
            return Ok(cached);
        }

        // Apply rate limiting before making API request
        self.rate_limit();

        // Build query URL with CPE matching for better version filtering
        // Use virtualMatchString to match CPE patterns with version
        let cpe_match = format!("cpe:2.3:*:*:{}:{}:*:*:*:*:*:*:*", package, version);
        let url = format!(
            "{}?virtualMatchString={}&resultsPerPage=100",
            Self::NVD_API_URL,
            urlencoding::encode(&cpe_match)
        );

        tracing::debug!("Querying NVD: {}", url);

        let mut request = self.client.get(&url);

        // Add API key if available
        if let Some(ref key) = self.api_key {
            request = request.header("apiKey", key);
        }

        let response = request.send().context("NVD API request failed")?;

        if !response.status().is_success() {
            anyhow::bail!("NVD API returned status {}", response.status());
        }

        let body = response.text()?;
        let records = self.parse_response(&body)?;

        // Cache the results with version key
        let _ = self.save_cache(&cache_key, &records);

        Ok(records)
    }

    fn get_cve(&self, cve_id: &str) -> Result<Option<CveRecord>> {
        // Apply rate limiting
        self.rate_limit();

        let url = format!("{}?cveId={}", Self::NVD_API_URL, cve_id);

        let mut request = self.client.get(&url);
        if let Some(ref key) = self.api_key {
            request = request.header("apiKey", key);
        }

        let response = request.send().context("NVD API request failed")?;

        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }

        if !response.status().is_success() {
            anyhow::bail!("NVD API returned status {}", response.status());
        }

        let body = response.text()?;
        let records = self.parse_response(&body)?;

        Ok(records.into_iter().next())
    }

    fn clear_cache(&self) -> Result<()> {
        for entry in fs::read_dir(&self.cache_dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().map(|e| e == "json").unwrap_or(false)
                && path.file_name().map(|n| n.to_string_lossy().starts_with("nvd_")).unwrap_or(false)
            {
                fs::remove_file(path)?;
            }
        }
        Ok(())
    }
}

// NVD API response structures
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NvdResponse {
    vulnerabilities: Vec<NvdVulnerability>,
}

#[derive(Debug, Deserialize)]
struct NvdVulnerability {
    cve: NvdCve,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NvdCve {
    id: String,
    descriptions: Vec<NvdDescription>,
    metrics: Option<NvdMetrics>,
    references: Vec<NvdReference>,
    published: Option<String>,
    last_modified: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NvdDescription {
    lang: String,
    value: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NvdMetrics {
    cvss_metric_v31: Option<Vec<NvdCvssMetric>>,
    cvss_metric_v30: Option<Vec<NvdCvssMetric>>,
    cvss_metric_v2: Option<Vec<NvdCvssMetricV2>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NvdCvssMetric {
    cvss_data: NvdCvssData,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NvdCvssMetricV2 {
    cvss_data: NvdCvssDataV2,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NvdCvssData {
    base_score: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NvdCvssDataV2 {
    base_score: f64,
}

#[derive(Debug, Deserialize)]
struct NvdReference {
    url: String,
    tags: Option<Vec<String>>,
}

/// OSV (Open Source Vulnerabilities) client
///
/// Uses the OSV API: https://osv.dev/docs/
/// OSV is package-aware and covers many ecosystems
pub struct OsvClient {
    client: Client,
    cache_dir: PathBuf,
}

impl OsvClient {
    const OSV_API_URL: &'static str = "https://api.osv.dev/v1";
    const CACHE_TTL_HOURS: i64 = 12;

    /// Create a new OSV client
    pub fn new(cache_dir: PathBuf) -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .user_agent("rookpkg/0.1.0 (Rookery OS Package Manager)")
            .build()
            .context("Failed to create HTTP client")?;

        fs::create_dir_all(&cache_dir)?;

        Ok(Self { client, cache_dir })
    }

    /// Get cache file path
    fn cache_path(&self, package: &str, version: &str) -> PathBuf {
        let safe_name = format!("{}_{}", package, version).replace(['/', '\\', ':'], "_");
        self.cache_dir.join(format!("osv_{}.json", safe_name))
    }

    /// Check cache
    fn check_cache(&self, package: &str, version: &str) -> Option<Vec<CveRecord>> {
        let path = self.cache_path(package, version);
        if !path.exists() {
            return None;
        }

        let content = fs::read_to_string(&path).ok()?;
        let entry: CacheEntry = serde_json::from_str(&content).ok()?;

        let age = Utc::now().signed_duration_since(entry.timestamp);
        if age.num_hours() > Self::CACHE_TTL_HOURS {
            return None;
        }

        Some(entry.records)
    }

    /// Save to cache
    fn save_cache(&self, package: &str, version: &str, records: &[CveRecord]) -> Result<()> {
        let entry = CacheEntry {
            timestamp: Utc::now(),
            records: records.to_vec(),
        };

        let path = self.cache_path(package, version);
        let content = serde_json::to_string_pretty(&entry)?;
        fs::write(path, content)?;

        Ok(())
    }

    /// Parse OSV response into CveRecords
    fn parse_vulns(&self, vulns: Vec<OsvVulnerability>) -> Vec<CveRecord> {
        vulns
            .into_iter()
            .map(|v| {
                // Get severity from database_specific or severity array
                let (severity, cvss_score) = v
                    .severity
                    .as_ref()
                    .and_then(|s| s.first())
                    .map(|s| {
                        // Try to parse as CVSS score first, fall back to string severity
                        if let Ok(score) = s.score.parse::<f64>() {
                            (Severity::from_cvss(score), Some(score))
                        } else {
                            // Score might be a severity string like "HIGH"
                            (Severity::from_str(&s.score), None)
                        }
                    })
                    .unwrap_or((Severity::Unknown, None));

                // Extract affected versions
                let affected_versions = v
                    .affected
                    .iter()
                    .flat_map(|a| {
                        a.ranges.iter().map(|r| VersionRange {
                            start: r
                                .events
                                .iter()
                                .find_map(|e| e.get("introduced").cloned()),
                            end: r.events.iter().find_map(|e| e.get("fixed").cloned()),
                            exact: a.versions.clone().unwrap_or_default(),
                        })
                    })
                    .collect();

                // Get fixed version
                let fixed_version = v.affected.iter().find_map(|a| {
                    a.ranges.iter().find_map(|r| {
                        r.events.iter().find_map(|e| e.get("fixed").cloned())
                    })
                });

                // Extract references
                let references = v
                    .references
                    .unwrap_or_default()
                    .into_iter()
                    .map(|r| Reference {
                        url: r.url,
                        ref_type: match r.ref_type.as_str() {
                            "FIX" => ReferenceType::Patch,
                            "ADVISORY" => ReferenceType::Advisory,
                            "PACKAGE" => ReferenceType::Vendor,
                            "ARTICLE" => ReferenceType::Article,
                            _ => ReferenceType::Other,
                        },
                    })
                    .collect();

                CveRecord {
                    id: v.id,
                    summary: v.summary.unwrap_or_default(),
                    description: v.details.unwrap_or_default(),
                    severity,
                    cvss_score,
                    affected_versions,
                    fixed_version,
                    published: v.published.and_then(|s| DateTime::parse_from_rfc3339(&s).ok().map(|d| d.into())),
                    modified: v.modified.and_then(|s| DateTime::parse_from_rfc3339(&s).ok().map(|d| d.into())),
                    references,
                    source: "OSV".to_string(),
                }
            })
            .collect()
    }
}

impl CveDatabase for OsvClient {
    fn query(&self, package: &str, version: &str) -> Result<Vec<CveRecord>> {
        // Check cache first
        if let Some(cached) = self.check_cache(package, version) {
            tracing::debug!("OSV cache hit for {}:{}", package, version);
            return Ok(cached);
        }

        // OSV query endpoint
        let url = format!("{}/query", Self::OSV_API_URL);

        // Try different ecosystems that might match
        // For a Linux distro package manager, we check multiple
        let ecosystems = ["Linux", "Debian", "Alpine", "OSS-Fuzz"];

        let mut all_records = Vec::new();

        for ecosystem in ecosystems {
            let query = OsvQuery {
                package: OsvPackage {
                    name: package.to_string(),
                    ecosystem: ecosystem.to_string(),
                },
                version: version.to_string(),
            };

            let response = self
                .client
                .post(&url)
                .json(&query)
                .send()
                .context("OSV API request failed")?;

            if response.status().is_success() {
                let body: OsvQueryResponse = response.json()?;
                let records = self.parse_vulns(body.vulns.unwrap_or_default());
                all_records.extend(records);
            }
        }

        // Deduplicate by CVE ID
        let mut seen = std::collections::HashSet::new();
        all_records.retain(|r| seen.insert(r.id.clone()));

        // Cache results
        let _ = self.save_cache(package, version, &all_records);

        Ok(all_records)
    }

    fn get_cve(&self, cve_id: &str) -> Result<Option<CveRecord>> {
        let url = format!("{}/vulns/{}", Self::OSV_API_URL, cve_id);

        let response = self.client.get(&url).send()?;

        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }

        if !response.status().is_success() {
            anyhow::bail!("OSV API returned status {}", response.status());
        }

        let vuln: OsvVulnerability = response.json()?;
        let records = self.parse_vulns(vec![vuln]);

        Ok(records.into_iter().next())
    }

    fn clear_cache(&self) -> Result<()> {
        for entry in fs::read_dir(&self.cache_dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().map(|e| e == "json").unwrap_or(false)
                && path.file_name().map(|n| n.to_string_lossy().starts_with("osv_")).unwrap_or(false)
            {
                fs::remove_file(path)?;
            }
        }
        Ok(())
    }
}

// OSV API structures
#[derive(Debug, Serialize)]
struct OsvQuery {
    package: OsvPackage,
    version: String,
}

#[derive(Debug, Serialize)]
struct OsvPackage {
    name: String,
    ecosystem: String,
}

#[derive(Debug, Deserialize)]
struct OsvQueryResponse {
    vulns: Option<Vec<OsvVulnerability>>,
}

#[derive(Debug, Deserialize)]
struct OsvVulnerability {
    id: String,
    summary: Option<String>,
    details: Option<String>,
    severity: Option<Vec<OsvSeverity>>,
    affected: Vec<OsvAffected>,
    references: Option<Vec<OsvReference>>,
    published: Option<String>,
    modified: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OsvSeverity {
    score: String,
}

#[derive(Debug, Deserialize)]
struct OsvAffected {
    ranges: Vec<OsvRange>,
    versions: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct OsvRange {
    events: Vec<HashMap<String, String>>,
}

#[derive(Debug, Deserialize)]
struct OsvReference {
    url: String,
    #[serde(rename = "type")]
    ref_type: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_severity_from_cvss() {
        assert_eq!(Severity::from_cvss(9.5), Severity::Critical);
        assert_eq!(Severity::from_cvss(7.5), Severity::High);
        assert_eq!(Severity::from_cvss(5.0), Severity::Medium);
        assert_eq!(Severity::from_cvss(2.0), Severity::Low);
        assert_eq!(Severity::from_cvss(0.0), Severity::Unknown);
    }

    #[test]
    fn test_severity_from_str() {
        assert_eq!(Severity::from_str("CRITICAL"), Severity::Critical);
        assert_eq!(Severity::from_str("high"), Severity::High);
        assert_eq!(Severity::from_str("Moderate"), Severity::Medium);
        assert_eq!(Severity::from_str("LOW"), Severity::Low);
        assert_eq!(Severity::from_str("unknown"), Severity::Unknown);
    }
}
