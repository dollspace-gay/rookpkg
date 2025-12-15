//! Error types for rookpkg

use thiserror::Error;

/// Main error type for rookpkg operations
#[derive(Error, Debug)]
pub enum RookpkgError {
    #[error("Package not found: {0}")]
    PackageNotFound(String),

    #[error("Dependency resolution failed: {0}")]
    DependencyResolution(String),

    #[error("Invalid spec file: {0}")]
    InvalidSpec(String),

    #[error("Signing key not found")]
    SigningKeyNotFound,

    #[error("Signing key has insecure permissions: {0:o} (expected 0600)")]
    InsecureKeyPermissions(u32),

    #[error("Package signature verification failed: {0}")]
    SignatureVerificationFailed(String),

    #[error("Untrusted package signer: {0}")]
    UntrustedSigner(String),

    #[error("Build failed: {0}")]
    BuildFailed(String),

    #[error("Download failed: {0}")]
    DownloadFailed(String),

    #[error("Checksum mismatch: expected {expected}, got {actual}")]
    ChecksumMismatch { expected: String, actual: String },

    #[error("File conflict: {path} is owned by {owner}")]
    FileConflict { path: String, owner: String },

    #[error("Database error: {0}")]
    Database(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Configuration error: {0}")]
    Config(String),
}

/// Result type alias for rookpkg operations
pub type Result<T> = std::result::Result<T, RookpkgError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_display() {
        let err = RookpkgError::PackageNotFound("foo".to_string());
        assert_eq!(err.to_string(), "Package not found: foo");

        let err = RookpkgError::DependencyResolution("circular dep".to_string());
        assert_eq!(err.to_string(), "Dependency resolution failed: circular dep");

        let err = RookpkgError::InvalidSpec("missing name".to_string());
        assert_eq!(err.to_string(), "Invalid spec file: missing name");

        let err = RookpkgError::SigningKeyNotFound;
        assert_eq!(err.to_string(), "Signing key not found");

        let err = RookpkgError::InsecureKeyPermissions(0o644);
        assert!(err.to_string().contains("insecure permissions"));

        let err = RookpkgError::SignatureVerificationFailed("bad sig".to_string());
        assert!(err.to_string().contains("verification failed"));

        let err = RookpkgError::UntrustedSigner("unknown@example.org".to_string());
        assert!(err.to_string().contains("Untrusted"));

        let err = RookpkgError::BuildFailed("make failed".to_string());
        assert!(err.to_string().contains("Build failed"));

        let err = RookpkgError::DownloadFailed("timeout".to_string());
        assert!(err.to_string().contains("Download failed"));

        let err = RookpkgError::ChecksumMismatch {
            expected: "abc123".to_string(),
            actual: "def456".to_string(),
        };
        assert!(err.to_string().contains("abc123"));
        assert!(err.to_string().contains("def456"));

        let err = RookpkgError::FileConflict {
            path: "/usr/bin/foo".to_string(),
            owner: "bar".to_string(),
        };
        assert!(err.to_string().contains("/usr/bin/foo"));
        assert!(err.to_string().contains("bar"));

        let err = RookpkgError::Database("connection failed".to_string());
        assert!(err.to_string().contains("Database"));

        let err = RookpkgError::Config("missing path".to_string());
        assert!(err.to_string().contains("Configuration"));
    }

    #[test]
    fn test_result_type() {
        fn operation_that_succeeds() -> Result<i32> {
            Ok(42)
        }

        fn operation_that_fails() -> Result<i32> {
            Err(RookpkgError::PackageNotFound("missing".to_string()))
        }

        assert!(operation_that_succeeds().is_ok());
        assert!(operation_that_fails().is_err());

        let result: Result<()> = Err(RookpkgError::SigningKeyNotFound);
        assert!(matches!(result, Err(RookpkgError::SigningKeyNotFound)));
    }

    #[test]
    fn test_io_error_conversion() {
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "file not found");
        let err: RookpkgError = io_err.into();
        assert!(matches!(err, RookpkgError::Io(_)));
    }
}
