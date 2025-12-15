//! Dependency resolution using PubGrub
//!
//! This module implements a dependency provider for the PubGrub algorithm.

use std::borrow::Borrow;
use std::collections::HashMap;
use std::error::Error;
use std::fmt::{self, Display};

use pubgrub::range::Range;
use pubgrub::solver::{Dependencies, DependencyConstraints, DependencyProvider};
use pubgrub::version::{SemanticVersion, Version};

/// A package identifier
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub struct Package(pub String);

impl Display for Package {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl Borrow<str> for Package {
    fn borrow(&self) -> &str {
        &self.0
    }
}

/// The Rookery dependency provider
pub struct RookeryDependencyProvider {
    /// Available packages and their versions
    packages: HashMap<String, Vec<PackageVersion>>,
}

/// A specific version of a package with its dependencies
#[derive(Debug, Clone)]
pub struct PackageVersion {
    pub version: SemanticVersion,
    pub dependencies: HashMap<String, Range<SemanticVersion>>,
}

impl RookeryDependencyProvider {
    /// Create a new empty provider
    pub fn new() -> Self {
        Self {
            packages: HashMap::new(),
        }
    }

    /// Add a package version to the provider
    pub fn add_package(
        &mut self,
        name: &str,
        version: SemanticVersion,
        dependencies: HashMap<String, Range<SemanticVersion>>,
    ) {
        let pkg_version = PackageVersion {
            version,
            dependencies,
        };

        self.packages
            .entry(name.to_string())
            .or_default()
            .push(pkg_version);
    }

    /// Get all versions of a package
    pub fn get_versions(&self, name: &str) -> Option<&Vec<PackageVersion>> {
        self.packages.get(name)
    }
}

impl Default for RookeryDependencyProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl DependencyProvider<Package, SemanticVersion> for RookeryDependencyProvider {
    fn choose_package_version<T: Borrow<Package>, U: Borrow<Range<SemanticVersion>>>(
        &self,
        potential_packages: impl Iterator<Item = (T, U)>,
    ) -> Result<(T, Option<SemanticVersion>), Box<dyn Error>> {
        // Choose the package with the fewest matching versions (most constrained)
        // Then choose the highest matching version for that package
        let mut best_package: Option<(T, Option<SemanticVersion>, usize)> = None;

        for (package, range) in potential_packages {
            let pkg_name: &Package = package.borrow();
            let version_range: &Range<SemanticVersion> = range.borrow();

            let (version, count) = match self.packages.get(&pkg_name.0) {
                Some(versions) => {
                    let mut matching: Vec<_> = versions
                        .iter()
                        .filter(|v| version_range.contains(&v.version))
                        .map(|v| v.version.clone())
                        .collect();
                    matching.sort();
                    (matching.pop(), matching.len() + 1) // +1 because we popped
                }
                None => (None, 0),
            };

            match &best_package {
                Some((_, _, best_count)) if count >= *best_count => continue,
                _ => best_package = Some((package, version, count)),
            }
        }

        match best_package {
            Some((package, version, _)) => Ok((package, version)),
            None => Err("No packages to choose from".into()),
        }
    }

    fn get_dependencies(
        &self,
        package: &Package,
        version: &SemanticVersion,
    ) -> Result<Dependencies<Package, SemanticVersion>, Box<dyn Error>> {
        match self.packages.get(&package.0) {
            Some(versions) => {
                for pkg_version in versions {
                    if &pkg_version.version == version {
                        let mut deps: DependencyConstraints<Package, SemanticVersion> =
                            DependencyConstraints::default();
                        for (name, range) in &pkg_version.dependencies {
                            deps.insert(Package(name.clone()), range.clone());
                        }
                        return Ok(Dependencies::Known(deps));
                    }
                }
                Err(format!(
                    "Version {} not found for package {}",
                    version, package
                ).into())
            }
            None => Err(format!("Package {} not found", package).into()),
        }
    }
}

/// Parse a version constraint string (e.g., ">= 1.0", "= 2.0")
pub fn parse_constraint(constraint: &str) -> Result<Range<SemanticVersion>, String> {
    let constraint = constraint.trim();

    // Handle empty constraint (any version)
    if constraint.is_empty() || constraint == "*" {
        return Ok(Range::any());
    }

    // Handle exact version
    if constraint.starts_with("= ") || constraint.starts_with("==") {
        let version_str = constraint.trim_start_matches("= ").trim_start_matches("==").trim();
        let version = parse_semver(version_str)?;
        return Ok(Range::exact(version));
    }

    // Handle >= constraint
    if constraint.starts_with(">=") {
        let version_str = constraint.trim_start_matches(">=").trim();
        let version = parse_semver(version_str)?;
        return Ok(Range::higher_than(version));
    }

    // Handle > constraint (strictly greater)
    if constraint.starts_with(">") && !constraint.starts_with(">=") {
        let version_str = constraint.trim_start_matches(">").trim();
        let version = parse_semver(version_str)?;
        // Strictly higher than = higher than the next version
        let bumped = version.bump();
        return Ok(Range::higher_than(bumped));
    }

    // Handle < constraint
    if constraint.starts_with("<") && !constraint.starts_with("<=") {
        let version_str = constraint.trim_start_matches("<").trim();
        let version = parse_semver(version_str)?;
        return Ok(Range::strictly_lower_than(version));
    }

    // Handle <= constraint
    if constraint.starts_with("<=") {
        let version_str = constraint.trim_start_matches("<=").trim();
        let version = parse_semver(version_str)?;
        // Lower than or equal = strictly lower than the next version
        let bumped = version.bump();
        return Ok(Range::strictly_lower_than(bumped));
    }

    // Try parsing as a bare version (exact match)
    let version = parse_semver(constraint)?;
    Ok(Range::exact(version))
}

/// Parse a version string to SemanticVersion
fn parse_semver(s: &str) -> Result<SemanticVersion, String> {
    let parts: Vec<&str> = s.split('.').collect();

    let major: u32 = parts
        .first()
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| format!("Invalid major version in: {}", s))?;

    let minor: u32 = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);

    let patch: u32 = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);

    Ok(SemanticVersion::new(major, minor, patch))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_constraint() {
        let range = parse_constraint(">= 1.0").unwrap();
        assert!(range.contains(&SemanticVersion::new(1, 0, 0)));
        assert!(range.contains(&SemanticVersion::new(2, 0, 0)));
        assert!(!range.contains(&SemanticVersion::new(0, 9, 0)));
    }

    #[test]
    fn test_dependency_provider() {
        let mut provider = RookeryDependencyProvider::new();

        // Add package A version 1.0.0 with no dependencies
        provider.add_package("a", SemanticVersion::new(1, 0, 0), HashMap::new());

        // Add package B version 1.0.0 depending on A >= 1.0
        let mut b_deps = HashMap::new();
        b_deps.insert(
            "a".to_string(),
            Range::higher_than(SemanticVersion::new(1, 0, 0)),
        );
        provider.add_package("b", SemanticVersion::new(1, 0, 0), b_deps);

        // Check that we can find versions
        assert!(provider.get_versions("a").is_some());
        assert!(provider.get_versions("b").is_some());
    }
}
