//! Key generation command implementation

use std::path::Path;

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;
use crate::signing;

pub fn run(name: &str, email: &str, output: Option<&Path>, config: &Config) -> Result<()> {
    println!("{}", "Generating hybrid Ed25519 + ML-DSA-65 signing key...".cyan());
    println!();
    println!("  {} Ed25519 (classical, fast verification)", "✓".green());
    println!("  {} ML-DSA-65 (FIPS 204 post-quantum, security level 3)", "✓".green());
    println!();

    let output_dir = output.unwrap_or_else(|| config.signing_key_dir());

    let (signing_key, fingerprint) = signing::generate_key(name, email, output_dir)?;

    println!("{}", "✓ Hybrid key generated successfully!".green().bold());
    println!();
    println!("  {}: {}", "Fingerprint".bold(), fingerprint);
    println!("  {}: {}", "Algorithm".bold(), signing_key.algorithm);
    println!(
        "  {}: {}",
        "Public key".bold(),
        output_dir.join("signing-key.pub").display()
    );
    println!(
        "  {}: {}",
        "Secret key".bold(),
        output_dir.join("signing-key.secret").display()
    );
    println!();
    println!("{}", "⚠️  IMPORTANT:".yellow().bold());
    println!("  This key is NOT trusted by default!");
    println!("  To sign official packages, submit your public key to the");
    println!("  Rookery OS maintainers for signing.");
    println!();
    println!("{}", "🛡️  QUANTUM RESISTANT:".cyan().bold());
    println!("  This key uses hybrid Ed25519 + ML-DSA-65 signatures.");
    println!("  Both signatures must verify, protecting against:");
    println!("  - Classical attacks (Ed25519)");
    println!("  - Quantum attacks (ML-DSA-65, NIST FIPS 204)");
    println!();
    println!("{}", "✓ You can now build and sign packages locally.".green());

    // Return the key so we don't get an unused warning
    drop(signing_key);

    Ok(())
}
