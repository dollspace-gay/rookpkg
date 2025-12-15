//! Package signature verification CLI

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use colored::Colorize;

use crate::config::Config;
use crate::signing::{self, verify_file, HybridSignature, KeyAlgorithm, TrustLevel};

/// Verify a package's signature
pub fn run(package_path: &Path, config: &Config) -> Result<()> {
    println!("{} {}", "Verifying:".bold(), package_path.display());
    println!();

    // Read the package signature file (package.rookpkg -> package.rookpkg.sig)
    let sig_path = package_path.with_extension("rookpkg.sig");
    if !sig_path.exists() {
        bail!(
            "Signature file not found: {}\n\
            Packages must have a .rookpkg.sig file with the signature.",
            sig_path.display()
        );
    }

    let sig_content = fs::read_to_string(&sig_path)
        .with_context(|| format!("Failed to read signature file: {}", sig_path.display()))?;

    let signature: HybridSignature = serde_json::from_str(&sig_content)
        .with_context(|| "Failed to parse signature file")?;

    println!("  Signature fingerprint: {}", signature.fingerprint.cyan());
    println!("  Signed at: {}", signature.timestamp);

    // Find the public key
    let public_key = find_public_key(&signature.fingerprint, config)?;

    println!("  Signer: {} <{}>", public_key.name, public_key.email);
    println!("  Algorithm: {}", public_key.algorithm);

    // Show trust level
    let trust_status = match public_key.trust_level {
        TrustLevel::Ultimate => "Ultimate (your key)".green(),
        TrustLevel::Full => "Full".cyan(),
        TrustLevel::Marginal => "Marginal".yellow(),
        TrustLevel::Unknown => "Unknown (not trusted)".red(),
    };
    println!("  Trust level: {}", trust_status);
    println!();

    // Verify the signature using verify_file helper
    println!("{}", "Verifying signatures...".dimmed());

    match verify_file(&public_key, package_path, &signature) {
        Ok(()) => {
            println!();
            println!("{}", "  Ed25519 signature:   ✓ VALID".green());
            if public_key.algorithm == KeyAlgorithm::Hybrid {
                println!("{}", "  ML-DSA-65 signature: ✓ VALID (quantum-resistant)".green());
            }
            println!();

            if public_key.trust_level == TrustLevel::Unknown {
                println!("{}", "⚠️  Warning:".yellow().bold());
                println!(
                    "  The signature is valid, but the signing key is NOT trusted."
                );
                println!("  This package may not be from a trusted source.");
                println!();
                println!("  To trust this key, run:");
                println!(
                    "    rookpkg keytrust <path-to-key.pub>"
                );
                println!();

                if !config.signing.allow_untrusted {
                    bail!("Package signature is valid but key is not trusted.");
                }
            } else {
                println!(
                    "{} Package signature verified successfully!",
                    "✓".green().bold()
                );
            }

            Ok(())
        }
        Err(e) => {
            println!();
            println!("{}", "  ✗ SIGNATURE VERIFICATION FAILED".red().bold());
            println!();
            println!("{}", "⚠️  DO NOT INSTALL THIS PACKAGE!".red().bold());
            println!("  The package may have been tampered with or corrupted.");
            println!();
            println!("Error: {}", e);
            bail!("Signature verification failed");
        }
    }
}

/// Find a public key by fingerprint
fn find_public_key(fingerprint: &str, config: &Config) -> Result<signing::LoadedPublicKey> {
    // Search master keys
    if let Some(key) = search_keys_in_dir(&config.signing.master_keys_dir, fingerprint)? {
        let mut key = key;
        key.trust_level = TrustLevel::Full;
        return Ok(key);
    }

    // Search packager keys
    if let Some(key) = search_keys_in_dir(&config.signing.packager_keys_dir, fingerprint)? {
        let mut key = key;

        // Check if this packager key has a valid certification from a master key
        let cert_dir = config.signing.packager_keys_dir.join("certs");
        if let Ok(Some(cert)) = signing::find_certification_for_key(&key.fingerprint, &cert_dir) {
            // Try to find the certifying master key
            if let Some(master_key) = search_keys_in_dir(&config.signing.master_keys_dir, &cert.certifier_key)? {
                // Verify the certification
                if signing::verify_certification(&cert, &key, &master_key).is_ok() {
                    tracing::debug!(
                        "Key {} certified by master key {} for purpose '{}'",
                        key.fingerprint,
                        cert.certifier_key,
                        cert.purpose
                    );
                    key.trust_level = TrustLevel::Full;
                    return Ok(key);
                }
            }
        }

        // No valid certification - marginal trust only
        key.trust_level = TrustLevel::Marginal;
        return Ok(key);
    }

    // Check if it's the user's own key
    let user_pub_path = config
        .signing
        .user_signing_key
        .parent()
        .unwrap_or(Path::new("."))
        .join("signing-key.pub");

    if user_pub_path.exists() {
        if let Ok(key) = signing::load_public_key(&user_pub_path) {
            if key.fingerprint == fingerprint
                || key.fingerprint.ends_with(fingerprint)
                || fingerprint.ends_with(&key.fingerprint)
            {
                let mut key = key;
                key.trust_level = TrustLevel::Ultimate;
                return Ok(key);
            }
        }
    }

    // Key not found - create a placeholder with Unknown trust
    // This allows verification to proceed but shows untrusted warning
    bail!(
        "Unknown signing key: {}\n\
        The signing key is not in the trusted keystore.\n\
        \n\
        To verify this package, you need the signer's public key.\n\
        Ask the package maintainer for their .pub key file, then:\n\
          rookpkg keytrust <key-file.pub>",
        fingerprint
    );
}

/// Search for a key by fingerprint in a directory
fn search_keys_in_dir(
    dir: &Path,
    fingerprint: &str,
) -> Result<Option<signing::LoadedPublicKey>> {
    if !dir.exists() {
        return Ok(None);
    }

    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().map(|e| e == "pub").unwrap_or(false) {
            if let Ok(key) = signing::load_public_key(&path) {
                // Allow partial fingerprint matching
                if key.fingerprint == fingerprint
                    || key.fingerprint.ends_with(fingerprint)
                    || fingerprint.ends_with(&key.fingerprint)
                {
                    return Ok(Some(key));
                }
            }
        }
    }

    Ok(None)
}
