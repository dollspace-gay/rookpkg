//! CVE-to-package matcher
//!
//! Matches CVE records to installed packages based on version ranges,
//! fixed versions, and other criteria.

use super::database::{CveRecord, Severity, VersionRange};
use semver::Version;

/// A package with known vulnerabilities
#[derive(Debug, Clone)]
pub struct VulnerablePackage {
    /// Package name
    pub name: String,
    /// Installed version
    pub version: String,
    /// List of CVEs affecting this package
    pub cves: Vec<CveRecord>,
    /// Recommended upgrade version (if available)
    pub recommended_version: Option<String>,
}

impl VulnerablePackage {
    /// Get the highest severity among all CVEs
    pub fn max_severity(&self) -> Severity {
        self.cves
            .iter()
            .map(|c| c.severity)
            .max_by_key(|s| match s {
                Severity::Critical => 4,
                Severity::High => 3,
                Severity::Medium => 2,
                Severity::Low => 1,
                Severity::Unknown => 0,
            })
            .unwrap_or(Severity::Unknown)
    }

    /// Get the highest CVSS score
    pub fn max_cvss(&self) -> Option<f64> {
        self.cves.iter().filter_map(|c| c.cvss_score).reduce(f64::max)
    }

    /// Check if any CVE has a patch available
    pub fn has_patch_available(&self) -> bool {
        self.cves.iter().any(|c| {
            c.references.iter().any(|r| {
                matches!(r.ref_type, super::database::ReferenceType::Patch)
            })
        })
    }
}

/// Matches CVEs to packages based on version information
pub struct CveMatcher {
    /// Package name aliases (e.g., "openssl" -> ["OpenSSL", "openssl-src"])
    aliases: std::collections::HashMap<String, Vec<String>>,
}

impl CveMatcher {
    /// Create a new CVE matcher
    pub fn new() -> Self {
        let mut aliases = std::collections::HashMap::new();

        // Common package name variations
        aliases.insert(
            "openssl".to_string(),
            vec!["OpenSSL".to_string(), "openssl-src".to_string()],
        );
        aliases.insert(
            "curl".to_string(),
            vec!["cURL".to_string(), "libcurl".to_string()],
        );
        aliases.insert(
            "zlib".to_string(),
            vec!["zlib1g".to_string(), "zlib-ng".to_string()],
        );
        aliases.insert(
            "glibc".to_string(),
            vec!["libc".to_string(), "GNU C Library".to_string()],
        );
        aliases.insert(
            "linux".to_string(),
            vec!["Linux Kernel".to_string(), "linux-kernel".to_string()],
        );

        Self { aliases }
    }

    /// Match CVEs to a specific package version
    pub fn match_cves(
        &self,
        package: &str,
        version: &str,
        cves: &[CveRecord],
    ) -> VulnerablePackage {
        let mut matching_cves = Vec::new();
        let mut highest_fixed: Option<String> = None;

        for cve in cves {
            if self.cve_affects_version(cve, version) {
                matching_cves.push(cve.clone());

                // Track the highest fixed version
                if let Some(ref fixed) = cve.fixed_version {
                    if let Some(ref current_highest) = highest_fixed {
                        if self.version_greater(fixed, current_highest) {
                            highest_fixed = Some(fixed.clone());
                        }
                    } else {
                        highest_fixed = Some(fixed.clone());
                    }
                }
            }
        }

        VulnerablePackage {
            name: package.to_string(),
            version: version.to_string(),
            cves: matching_cves,
            recommended_version: highest_fixed,
        }
    }

    /// Check if a CVE affects a specific version
    fn cve_affects_version(&self, cve: &CveRecord, version: &str) -> bool {
        // If no version info, assume NOT affected (reduces noise)
        // CVEs without version data are usually not actionable anyway
        if cve.affected_versions.is_empty() && cve.fixed_version.is_none() {
            return false;
        }

        // Check if version is in any affected range
        for range in &cve.affected_versions {
            if self.version_in_range(version, range) {
                // Check if there's a fixed version and we're past it
                if let Some(ref fixed) = cve.fixed_version {
                    if self.version_greater_or_equal(version, fixed) {
                        return false; // We're on or past the fix
                    }
                }
                return true;
            }
        }

        // If we have a fixed version, check if we're below it
        if let Some(ref fixed) = cve.fixed_version {
            if !self.version_greater_or_equal(version, fixed) {
                return true;
            }
        }

        false
    }

    /// Check if a version is within an affected range
    fn version_in_range(&self, version: &str, range: &VersionRange) -> bool {
        // Check exact versions first
        if range.exact.iter().any(|v| v == version) {
            return true;
        }

        // Check range bounds
        let after_start = match &range.start {
            Some(start) => self.version_greater_or_equal(version, start),
            None => true,
        };

        let before_end = match &range.end {
            Some(end) => !self.version_greater_or_equal(version, end),
            None => true,
        };

        after_start && before_end
    }

    /// Compare versions (semver-aware with fallback)
    fn version_greater(&self, a: &str, b: &str) -> bool {
        match (Version::parse(a), Version::parse(b)) {
            (Ok(va), Ok(vb)) => va > vb,
            _ => a > b, // Fallback to string comparison
        }
    }

    fn version_greater_or_equal(&self, a: &str, b: &str) -> bool {
        match (Version::parse(a), Version::parse(b)) {
            (Ok(va), Ok(vb)) => va >= vb,
            _ => a >= b,
        }
    }

    /// Get aliases for a package name
    #[allow(dead_code)]
    pub fn get_aliases(&self, package: &str) -> Vec<String> {
        let mut result = vec![package.to_string()];
        if let Some(aliases) = self.aliases.get(package) {
            result.extend(aliases.clone());
        }
        result
    }

    /// Add a package alias
    #[allow(dead_code)]
    pub fn add_alias(&mut self, package: &str, alias: &str) {
        self.aliases
            .entry(package.to_string())
            .or_default()
            .push(alias.to_string());
    }
}

impl Default for CveMatcher {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cve::database::Reference;

    fn make_cve(id: &str, fixed: Option<&str>) -> CveRecord {
        CveRecord {
            id: id.to_string(),
            summary: "Test CVE".to_string(),
            description: "Test description".to_string(),
            severity: Severity::High,
            cvss_score: Some(7.5),
            affected_versions: vec![VersionRange {
                start: Some("1.0.0".to_string()),
                end: fixed.map(String::from),
                exact: vec![],
            }],
            fixed_version: fixed.map(String::from),
            published: None,
            modified: None,
            references: vec![],
            source: "test".to_string(),
        }
    }

    #[test]
    fn test_version_in_range() {
        let matcher = CveMatcher::new();

        let range = VersionRange {
            start: Some("1.0.0".to_string()),
            end: Some("2.0.0".to_string()),
            exact: vec![],
        };

        assert!(matcher.version_in_range("1.5.0", &range));
        assert!(matcher.version_in_range("1.0.0", &range));
        assert!(!matcher.version_in_range("2.0.0", &range));
        assert!(!matcher.version_in_range("0.9.0", &range));
    }

    #[test]
    fn test_cve_affects_version() {
        let matcher = CveMatcher::new();

        let cve = make_cve("CVE-2024-1234", Some("1.5.0"));

        assert!(matcher.cve_affects_version(&cve, "1.2.0")); // Before fix
        assert!(!matcher.cve_affects_version(&cve, "1.5.0")); // At fix
        assert!(!matcher.cve_affects_version(&cve, "2.0.0")); // After fix
    }

    #[test]
    fn test_match_cves() {
        let matcher = CveMatcher::new();

        let cves = vec![
            make_cve("CVE-2024-0001", Some("1.5.0")),
            make_cve("CVE-2024-0002", Some("1.3.0")),
            // Note: CVEs without version info are now skipped (not actionable)
        ];

        // Version 1.2.0 is affected by both (before their fix versions)
        let result = matcher.match_cves("test", "1.2.0", &cves);
        assert_eq!(result.cves.len(), 2);
        assert_eq!(result.recommended_version, Some("1.5.0".to_string()));

        // Version 1.4.0 is only affected by CVE-0001 (fixed in 1.5.0)
        let result = matcher.match_cves("test", "1.4.0", &cves);
        assert_eq!(result.cves.len(), 1);
        assert_eq!(result.cves[0].id, "CVE-2024-0001");

        // Version 1.5.0 is not affected (at or past all fix versions)
        let result = matcher.match_cves("test", "1.5.0", &cves);
        assert_eq!(result.cves.len(), 0);
    }

    #[test]
    fn test_max_severity() {
        let matcher = CveMatcher::new();

        // Use CVEs with version info (fixed version means we're affected if below it)
        let mut cves = vec![make_cve("CVE-2024-0001", Some("2.0.0"))];
        cves[0].severity = Severity::Medium;

        let result = matcher.match_cves("test", "1.0.0", &cves);
        assert_eq!(result.max_severity(), Severity::Medium);

        cves.push(make_cve("CVE-2024-0002", Some("2.0.0")));
        cves[1].severity = Severity::Critical;

        let result = matcher.match_cves("test", "1.0.0", &cves);
        assert_eq!(result.max_severity(), Severity::Critical);
    }
}
