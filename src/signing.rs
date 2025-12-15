//! Cryptographic signing for packages
//!
//! Implements hybrid Ed25519 + ML-DSA (FIPS 204) signatures for quantum resistance.
//! All packages MUST be signed - this is non-negotiable.
//!
//! ## Signature Strategy
//!
//! We use a hybrid approach combining:
//! - **Ed25519**: Classical signature (fast, well-audited)
//! - **ML-DSA-65**: Post-quantum signature (NIST FIPS 204, security level 3)
//!
//! Both signatures must verify for a package to be considered valid.
//! This provides security against both classical and quantum adversaries.

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use base64::prelude::*;
use ed25519_dalek::{Signature as Ed25519Signature, Signer as Ed25519Signer, SigningKey, Verifier as Ed25519Verifier, VerifyingKey};
use ml_dsa::MlDsa65;
use ml_dsa::signature::{SignatureEncoding, Signer as MlDsaSigner, Verifier as MlDsaVerifier};
use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::config::Config;

/// Key algorithm type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum KeyAlgorithm {
    /// Classical Ed25519 only (legacy)
    Ed25519,
    /// Post-quantum ML-DSA-65 only
    MlDsa65,
    /// Hybrid Ed25519 + ML-DSA-65 (recommended)
    Hybrid,
}

impl std::fmt::Display for KeyAlgorithm {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            KeyAlgorithm::Ed25519 => write!(f, "ed25519"),
            KeyAlgorithm::MlDsa65 => write!(f, "ml-dsa-65"),
            KeyAlgorithm::Hybrid => write!(f, "hybrid-ed25519-ml-dsa-65"),
        }
    }
}

/// A hybrid signature containing both Ed25519 and ML-DSA signatures
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HybridSignature {
    /// Ed25519 signature (64 bytes, base64 encoded)
    pub ed25519: String,
    /// ML-DSA-65 signature (base64 encoded)
    pub ml_dsa: String,
    /// Key fingerprint that created this signature
    pub fingerprint: String,
    /// Timestamp of signature
    pub timestamp: String,
}

/// A key certification - a signature on a public key by another key (typically master key)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyCertification {
    /// Fingerprint of the key being certified
    pub certified_key: String,
    /// Fingerprint of the certifying key (master key)
    pub certifier_key: String,
    /// Name of the certifier
    pub certifier_name: String,
    /// Certification purpose (e.g., "packager", "repository")
    pub purpose: String,
    /// Expiration timestamp (ISO 8601), or empty for no expiration
    pub expires: String,
    /// The hybrid signature over the certification data
    pub signature: HybridSignature,
}

/// A loaded signing key pair with metadata
pub struct LoadedSigningKey {
    /// Ed25519 signing key
    pub ed25519_key: SigningKey,
    /// ML-DSA-65 signing key
    pub ml_dsa_key: ml_dsa::SigningKey<MlDsa65>,
    /// Key fingerprint
    pub fingerprint: String,
    /// Key owner name
    pub name: String,
    /// Key owner email
    pub email: String,
    /// Key algorithm
    pub algorithm: KeyAlgorithm,
}

/// A loaded public key for verification
#[derive(Clone)]
pub struct LoadedPublicKey {
    /// Ed25519 verifying key
    pub ed25519_key: VerifyingKey,
    /// ML-DSA-65 verifying key
    pub ml_dsa_key: ml_dsa::VerifyingKey<MlDsa65>,
    /// Key fingerprint
    pub fingerprint: String,
    /// Key owner name
    pub name: String,
    /// Key owner email
    pub email: String,
    /// Key algorithm
    pub algorithm: KeyAlgorithm,
    /// Trust level
    pub trust_level: TrustLevel,
}

/// Trust level for a public key
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TrustLevel {
    /// Unknown key, not trusted
    Unknown,
    /// Marginal trust (user added)
    Marginal,
    /// Full trust (signed by trusted key)
    Full,
    /// Ultimate trust (user's own key)
    Ultimate,
}

impl Default for TrustLevel {
    fn default() -> Self {
        TrustLevel::Unknown
    }
}

/// Generate a new hybrid signing key pair
pub fn generate_key(name: &str, email: &str, output_dir: &Path) -> Result<(LoadedSigningKey, String)> {
    tracing::info!("Generating hybrid Ed25519 + ML-DSA-65 key pair...");

    // Generate Ed25519 key pair
    let mut csprng = OsRng;
    let ed25519_signing_key = SigningKey::generate(&mut csprng);
    let ed25519_verifying_key = ed25519_signing_key.verifying_key();

    // Generate ML-DSA-65 key pair using from_seed (avoids rand_core version conflicts)
    use ml_dsa::KeyGen;
    let mut ml_dsa_seed = [0u8; 32];
    csprng.fill_bytes(&mut ml_dsa_seed);
    let ml_dsa_keypair = MlDsa65::from_seed(&ml_dsa_seed.into());
    ml_dsa_seed.iter_mut().for_each(|b| *b = 0); // Zeroize seed
    let ml_dsa_signing_key = ml_dsa_keypair.signing_key().clone();
    let ml_dsa_verifying_key = ml_dsa_keypair.verifying_key().clone();

    // Calculate hybrid fingerprint (hash of both public keys)
    let fingerprint = calculate_hybrid_fingerprint(&ed25519_verifying_key, &ml_dsa_verifying_key);

    // Create output directory
    fs::create_dir_all(output_dir)
        .with_context(|| format!("Failed to create key directory: {}", output_dir.display()))?;

    // Serialize ML-DSA keys using encode()
    let ml_dsa_signing_bytes = ml_dsa_signing_key.encode();
    let ml_dsa_verifying_bytes = ml_dsa_verifying_key.encode();

    // Save secret key (with secure permissions)
    let secret_path = output_dir.join("signing-key.secret");
    let secret_content = format!(
        r#"# rookery-secretkey-version: 2.0
# WARNING: Keep this file secure! Mode should be 0600.
# This is a HYBRID key containing both Ed25519 and ML-DSA-65 (FIPS 204) keys.
type = "hybrid-ed25519-ml-dsa-65"
purpose = "packager"
fingerprint = "{fingerprint}"

[keys]
ed25519-secret = "{ed25519_secret}"
ml-dsa-65-secret = "{ml_dsa_secret}"

[identity]
name = "{name}"
email = "{email}"

[metadata]
created = "{timestamp}"
algorithm = "hybrid-ed25519-ml-dsa-65"
"#,
        fingerprint = fingerprint,
        ed25519_secret = BASE64_STANDARD.encode(ed25519_signing_key.to_bytes()),
        ml_dsa_secret = BASE64_STANDARD.encode(ml_dsa_signing_bytes.as_slice()),
        name = name,
        email = email,
        timestamp = chrono::Utc::now().to_rfc3339(),
    );

    // Write with secure permissions
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&secret_path)?;
        std::io::Write::write_all(&mut file, secret_content.as_bytes())?;
    }

    #[cfg(not(unix))]
    {
        fs::write(&secret_path, &secret_content)?;
    }

    // Save public key
    let public_path = output_dir.join("signing-key.pub");
    let public_content = format!(
        r#"# rookery-pubkey-version: 2.0
# This is a HYBRID public key containing both Ed25519 and ML-DSA-65 (FIPS 204) keys.
# Quantum-resistant from day one.
type = "hybrid-ed25519-ml-dsa-65"
purpose = "packager"
fingerprint = "{fingerprint}"

[keys]
ed25519-public = "{ed25519_public}"
ml-dsa-65-public = "{ml_dsa_public}"

[identity]
name = "{name}"
email = "{email}"

[metadata]
created = "{timestamp}"
algorithm = "hybrid-ed25519-ml-dsa-65"
"#,
        fingerprint = fingerprint,
        ed25519_public = BASE64_STANDARD.encode(ed25519_verifying_key.to_bytes()),
        ml_dsa_public = BASE64_STANDARD.encode(ml_dsa_verifying_bytes.as_slice()),
        name = name,
        email = email,
        timestamp = chrono::Utc::now().to_rfc3339(),
    );
    fs::write(&public_path, &public_content)?;

    tracing::info!("Generated hybrid key pair with fingerprint: {}", fingerprint);

    let loaded_key = LoadedSigningKey {
        ed25519_key: ed25519_signing_key,
        ml_dsa_key: ml_dsa_signing_key,
        fingerprint: fingerprint.clone(),
        name: name.to_string(),
        email: email.to_string(),
        algorithm: KeyAlgorithm::Hybrid,
    };

    Ok((loaded_key, fingerprint))
}

/// Load an existing signing key from the config-specified location
pub fn load_signing_key(config: &Config) -> Result<LoadedSigningKey> {
    let key_path = &config.signing.user_signing_key;
    load_signing_key_from_path(key_path)
}

/// Load a signing key from a specific path
pub fn load_signing_key_from_path(key_path: &Path) -> Result<LoadedSigningKey> {
    if !key_path.exists() {
        bail!("Signing key not found at: {}", key_path.display());
    }

    // Check permissions on Unix
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::metadata(key_path)?;
        let mode = metadata.mode() & 0o777;
        if mode != 0o600 {
            bail!(
                "Signing key has insecure permissions: {:o} (expected 0600). Fix with: chmod 600 {}",
                mode,
                key_path.display()
            );
        }
    }

    // Read and parse key file
    let content = Zeroizing::new(fs::read_to_string(key_path)?);
    let parsed: toml::Value = toml::from_str(&content)?;

    // Determine key type
    let key_type = parsed
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("ed25519");

    match key_type {
        "hybrid-ed25519-ml-dsa-65" => load_hybrid_secret_key(&parsed),
        "ed25519" => load_legacy_ed25519_key(&parsed),
        _ => bail!("Unknown key type: {}", key_type),
    }
}

/// Load a hybrid secret key
fn load_hybrid_secret_key(parsed: &toml::Value) -> Result<LoadedSigningKey> {
    let keys = parsed
        .get("keys")
        .ok_or_else(|| anyhow::anyhow!("Missing [keys] section in key file"))?;

    // Load Ed25519 key
    let ed25519_secret_b64 = keys
        .get("ed25519-secret")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Missing ed25519-secret in key file"))?;

    let ed25519_bytes = BASE64_STANDARD.decode(ed25519_secret_b64)?;
    if ed25519_bytes.len() != 32 {
        bail!("Invalid Ed25519 secret key length");
    }

    let mut ed25519_key_bytes = [0u8; 32];
    ed25519_key_bytes.copy_from_slice(&ed25519_bytes);
    let ed25519_key = SigningKey::from_bytes(&ed25519_key_bytes);
    ed25519_key_bytes.iter_mut().for_each(|b| *b = 0);

    // Load ML-DSA key
    let ml_dsa_secret_b64 = keys
        .get("ml-dsa-65-secret")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Missing ml-dsa-65-secret in key file"))?;

    let ml_dsa_bytes = BASE64_STANDARD.decode(ml_dsa_secret_b64)?;
    let ml_dsa_key = ml_dsa::SigningKey::<MlDsa65>::decode(
        ml_dsa_bytes.as_slice().try_into()
            .map_err(|_| anyhow::anyhow!("Invalid ML-DSA-65 secret key length"))?
    );

    // Get metadata
    let fingerprint = parsed
        .get("fingerprint")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let identity = parsed.get("identity");
    let name = identity
        .and_then(|i| i.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("Unknown")
        .to_string();
    let email = identity
        .and_then(|i| i.get("email"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown@example.org")
        .to_string();

    // Verify keys work
    let test_msg = b"rookery-signing-test";
    let ed25519_sig = ed25519_key.sign(test_msg);
    ed25519_key
        .verifying_key()
        .verify(test_msg, &ed25519_sig)
        .map_err(|_| anyhow::anyhow!("Ed25519 key verification failed"))?;

    Ok(LoadedSigningKey {
        ed25519_key,
        ml_dsa_key,
        fingerprint,
        name,
        email,
        algorithm: KeyAlgorithm::Hybrid,
    })
}

/// Load a legacy Ed25519-only key (for backwards compatibility)
fn load_legacy_ed25519_key(parsed: &toml::Value) -> Result<LoadedSigningKey> {
    let secret_key_b64 = parsed
        .get("secret-key")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Missing secret-key in key file"))?;

    let secret_bytes = BASE64_STANDARD.decode(secret_key_b64)?;
    if secret_bytes.len() != 32 {
        bail!("Invalid secret key length");
    }

    let mut key_bytes = [0u8; 32];
    key_bytes.copy_from_slice(&secret_bytes);
    let ed25519_key = SigningKey::from_bytes(&key_bytes);
    key_bytes.iter_mut().for_each(|b| *b = 0);

    // Generate an ML-DSA key from the Ed25519 seed (deterministic for legacy keys)
    let mut seed_hasher = Sha256::new();
    seed_hasher.update(b"rookery-ml-dsa-seed-from-ed25519");
    seed_hasher.update(ed25519_key.to_bytes());
    let seed = seed_hasher.finalize();

    // Use from_seed for deterministic key generation (avoids rand_core version conflicts)
    use ml_dsa::KeyGen;
    let ml_dsa_seed: [u8; 32] = seed.as_slice().try_into().unwrap();
    let ml_dsa_keypair = MlDsa65::from_seed(&ml_dsa_seed.into());
    let ml_dsa_key = ml_dsa_keypair.signing_key().clone();

    let fingerprint = parsed
        .get("fingerprint")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let identity = parsed.get("identity");
    let name = identity
        .and_then(|i| i.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("Unknown")
        .to_string();
    let email = identity
        .and_then(|i| i.get("email"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown@example.org")
        .to_string();

    tracing::warn!(
        "Loaded legacy Ed25519-only key. Consider regenerating with hybrid support for quantum resistance."
    );

    Ok(LoadedSigningKey {
        ed25519_key,
        ml_dsa_key,
        fingerprint,
        name,
        email,
        algorithm: KeyAlgorithm::Ed25519,
    })
}

/// Load a public key from a file
pub fn load_public_key(path: &Path) -> Result<LoadedPublicKey> {
    let content = fs::read_to_string(path)?;
    let parsed: toml::Value = toml::from_str(&content)?;

    let key_type = parsed
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("ed25519");

    match key_type {
        "hybrid-ed25519-ml-dsa-65" => load_hybrid_public_key(&parsed),
        "ed25519" => load_legacy_public_key(&parsed),
        _ => bail!("Unknown key type: {}", key_type),
    }
}

/// Load a hybrid public key
fn load_hybrid_public_key(parsed: &toml::Value) -> Result<LoadedPublicKey> {
    let keys = parsed
        .get("keys")
        .ok_or_else(|| anyhow::anyhow!("Missing [keys] section in key file"))?;

    // Load Ed25519 public key
    let ed25519_pub_b64 = keys
        .get("ed25519-public")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Missing ed25519-public in key file"))?;

    let ed25519_bytes = BASE64_STANDARD.decode(ed25519_pub_b64)?;
    let ed25519_key = VerifyingKey::from_bytes(
        ed25519_bytes
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("Invalid Ed25519 public key length"))?,
    )
    .map_err(|_| anyhow::anyhow!("Invalid Ed25519 public key"))?;

    // Load ML-DSA public key
    let ml_dsa_pub_b64 = keys
        .get("ml-dsa-65-public")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Missing ml-dsa-65-public in key file"))?;

    let ml_dsa_bytes = BASE64_STANDARD.decode(ml_dsa_pub_b64)?;
    let ml_dsa_key = ml_dsa::VerifyingKey::<MlDsa65>::decode(
        ml_dsa_bytes.as_slice().try_into()
            .map_err(|_| anyhow::anyhow!("Invalid ML-DSA-65 public key length"))?
    );

    let fingerprint = parsed
        .get("fingerprint")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let identity = parsed.get("identity");
    let name = identity
        .and_then(|i| i.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("Unknown")
        .to_string();
    let email = identity
        .and_then(|i| i.get("email"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown@example.org")
        .to_string();

    Ok(LoadedPublicKey {
        ed25519_key,
        ml_dsa_key,
        fingerprint,
        name,
        email,
        algorithm: KeyAlgorithm::Hybrid,
        trust_level: TrustLevel::Unknown,
    })
}

/// Load a legacy Ed25519-only public key
fn load_legacy_public_key(parsed: &toml::Value) -> Result<LoadedPublicKey> {
    let pub_key_b64 = parsed
        .get("key")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Missing key in public key file"))?;

    let pub_bytes = BASE64_STANDARD.decode(pub_key_b64)?;
    let ed25519_key = VerifyingKey::from_bytes(
        pub_bytes
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("Invalid Ed25519 public key length"))?,
    )
    .map_err(|_| anyhow::anyhow!("Invalid Ed25519 public key"))?;

    // Derive ML-DSA public key from Ed25519 public key (deterministic)
    let mut seed_hasher = Sha256::new();
    seed_hasher.update(b"rookery-ml-dsa-seed-from-ed25519");
    seed_hasher.update(ed25519_key.to_bytes());
    let seed = seed_hasher.finalize();

    // Use from_seed for deterministic key generation (avoids rand_core version conflicts)
    use ml_dsa::KeyGen;
    let ml_dsa_seed: [u8; 32] = seed.as_slice().try_into().unwrap();
    let ml_dsa_keypair = MlDsa65::from_seed(&ml_dsa_seed.into());
    let ml_dsa_key = ml_dsa_keypair.verifying_key().clone();

    // Use stored fingerprint if available, otherwise calculate from the Ed25519 key
    let fingerprint = parsed
        .get("fingerprint")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(|| calculate_fingerprint(&ed25519_key));

    let identity = parsed.get("identity");
    let name = identity
        .and_then(|i| i.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("Unknown")
        .to_string();
    let email = identity
        .and_then(|i| i.get("email"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown@example.org")
        .to_string();

    Ok(LoadedPublicKey {
        ed25519_key,
        ml_dsa_key,
        fingerprint,
        name,
        email,
        algorithm: KeyAlgorithm::Ed25519,
        trust_level: TrustLevel::Unknown,
    })
}

/// Calculate the hybrid fingerprint of Ed25519 + ML-DSA public keys
pub fn calculate_hybrid_fingerprint(ed25519: &VerifyingKey, ml_dsa: &ml_dsa::VerifyingKey<MlDsa65>) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"rookery-hybrid-fingerprint-v1");
    hasher.update(ed25519.as_bytes());
    hasher.update(ml_dsa.encode().as_slice());
    let hash = hasher.finalize();
    format!("HYBRID:SHA256:{}", hex::encode(&hash[..16]))
}

/// Calculate the fingerprint of an Ed25519 verifying key (legacy)
pub fn calculate_fingerprint(key: &VerifyingKey) -> String {
    let hash = Sha256::digest(key.as_bytes());
    format!("ED25519:SHA256:{}", hex::encode(&hash[..16]))
}

/// Sign a message with hybrid Ed25519 + ML-DSA signatures
pub fn sign_message(key: &LoadedSigningKey, message: &[u8]) -> Result<HybridSignature> {
    // Hash the message first
    let message_hash = Sha256::digest(message);

    // Create Ed25519 signature
    let ed25519_sig = key.ed25519_key.sign(&message_hash);

    // Create ML-DSA signature
    let ml_dsa_sig = key.ml_dsa_key.sign(&message_hash);

    Ok(HybridSignature {
        ed25519: BASE64_STANDARD.encode(ed25519_sig.to_bytes()),
        ml_dsa: BASE64_STANDARD.encode(ml_dsa_sig.to_bytes().as_slice()),
        fingerprint: key.fingerprint.clone(),
        timestamp: chrono::Utc::now().to_rfc3339(),
    })
}

/// Verify a hybrid signature
pub fn verify_signature(
    public_key: &LoadedPublicKey,
    message: &[u8],
    signature: &HybridSignature,
) -> Result<()> {
    // Hash the message
    let message_hash = Sha256::digest(message);

    // Verify Ed25519 signature
    let ed25519_sig_bytes = BASE64_STANDARD.decode(&signature.ed25519)?;
    let ed25519_sig = Ed25519Signature::from_bytes(
        ed25519_sig_bytes
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("Invalid Ed25519 signature length"))?,
    );

    public_key
        .ed25519_key
        .verify(&message_hash, &ed25519_sig)
        .map_err(|_| anyhow::anyhow!("Ed25519 signature verification failed"))?;

    // Verify ML-DSA signature
    let ml_dsa_sig_bytes = BASE64_STANDARD.decode(&signature.ml_dsa)?;
    let ml_dsa_sig = ml_dsa::Signature::<MlDsa65>::decode(
        ml_dsa_sig_bytes.as_slice().try_into()
            .map_err(|_| anyhow::anyhow!("Invalid ML-DSA signature length"))?
    ).ok_or_else(|| anyhow::anyhow!("Invalid ML-DSA signature"))?;

    public_key
        .ml_dsa_key
        .verify(&message_hash, &ml_dsa_sig)
        .map_err(|_| anyhow::anyhow!("ML-DSA signature verification failed"))?;

    tracing::debug!("Hybrid signature verified successfully");
    Ok(())
}

/// Sign a file and return the signature
pub fn sign_file(key: &LoadedSigningKey, file_path: &Path) -> Result<HybridSignature> {
    let content = fs::read(file_path)?;
    sign_message(key, &content)
}

/// Verify a file signature
pub fn verify_file(
    public_key: &LoadedPublicKey,
    file_path: &Path,
    signature: &HybridSignature,
) -> Result<()> {
    let content = fs::read(file_path)?;
    verify_signature(public_key, &content, signature)
}

/// Get the fingerprint of a loaded signing key
pub fn get_fingerprint(key: &LoadedSigningKey) -> &str {
    &key.fingerprint
}

/// Certify (sign) a public key with a master key
///
/// This creates a certification that attests the public key is authorized
/// for a specific purpose (e.g., "packager").
pub fn certify_key(
    master_key: &LoadedSigningKey,
    public_key: &LoadedPublicKey,
    purpose: &str,
    expires: Option<&str>,
) -> Result<KeyCertification> {
    // Create the certification data to sign
    // Format: certified_key|certifier_key|purpose|expires
    let expires_str = expires.unwrap_or("");
    let cert_data = format!(
        "ROOKERY-KEY-CERTIFICATION-V1|{}|{}|{}|{}",
        public_key.fingerprint,
        master_key.fingerprint,
        purpose,
        expires_str
    );

    // Sign the certification data
    let signature = sign_message(master_key, cert_data.as_bytes())?;

    Ok(KeyCertification {
        certified_key: public_key.fingerprint.clone(),
        certifier_key: master_key.fingerprint.clone(),
        certifier_name: format!("{} <{}>", master_key.name, master_key.email),
        purpose: purpose.to_string(),
        expires: expires_str.to_string(),
        signature,
    })
}

/// Verify a key certification
pub fn verify_certification(
    certification: &KeyCertification,
    certified_key: &LoadedPublicKey,
    certifier_key: &LoadedPublicKey,
) -> Result<()> {
    // Check fingerprints match
    if certification.certified_key != certified_key.fingerprint {
        bail!(
            "Certification is for key {} but got {}",
            certification.certified_key,
            certified_key.fingerprint
        );
    }

    if certification.certifier_key != certifier_key.fingerprint {
        bail!(
            "Certification is from key {} but verifying with {}",
            certification.certifier_key,
            certifier_key.fingerprint
        );
    }

    // Check expiration
    if !certification.expires.is_empty() {
        if let Ok(expires) = chrono::DateTime::parse_from_rfc3339(&certification.expires) {
            if expires < chrono::Utc::now() {
                bail!("Key certification has expired ({})", certification.expires);
            }
        }
    }

    // Recreate the certification data
    let cert_data = format!(
        "ROOKERY-KEY-CERTIFICATION-V1|{}|{}|{}|{}",
        certification.certified_key,
        certification.certifier_key,
        certification.purpose,
        certification.expires
    );

    // Verify the signature
    verify_signature(certifier_key, cert_data.as_bytes(), &certification.signature)
        .context("Key certification signature verification failed")?;

    tracing::debug!(
        "Key {} certified by {} for purpose '{}'",
        certification.certified_key,
        certification.certifier_key,
        certification.purpose
    );

    Ok(())
}

/// Save a key certification to a file
pub fn save_certification(certification: &KeyCertification, path: &Path) -> Result<()> {
    let content = serde_json::to_string_pretty(certification)?;
    fs::write(path, content)?;
    Ok(())
}

/// Load a key certification from a file
pub fn load_certification(path: &Path) -> Result<KeyCertification> {
    let content = fs::read_to_string(path)?;
    let certification: KeyCertification = serde_json::from_str(&content)?;
    Ok(certification)
}

/// Find certification for a key in a directory
pub fn find_certification_for_key(
    key_fingerprint: &str,
    cert_dir: &Path,
) -> Result<Option<KeyCertification>> {
    if !cert_dir.exists() {
        return Ok(None);
    }

    for entry in fs::read_dir(cert_dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().map(|e| e == "cert").unwrap_or(false) {
            if let Ok(cert) = load_certification(&path) {
                if cert.certified_key == key_fingerprint
                    || cert.certified_key.ends_with(key_fingerprint)
                    || key_fingerprint.ends_with(&cert.certified_key)
                {
                    return Ok(Some(cert));
                }
            }
        }
    }

    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_hybrid_key_generation() {
        let dir = tempdir().unwrap();
        let (key, fingerprint) =
            generate_key("Test User", "test@example.org", dir.path()).unwrap();

        assert!(fingerprint.starts_with("HYBRID:SHA256:"));
        assert!(dir.path().join("signing-key.secret").exists());
        assert!(dir.path().join("signing-key.pub").exists());
        assert_eq!(key.algorithm, KeyAlgorithm::Hybrid);
    }

    #[test]
    fn test_hybrid_sign_verify() {
        let dir = tempdir().unwrap();
        let (key, _) = generate_key("Test User", "test@example.org", dir.path()).unwrap();

        let message = b"test message for signing";
        let signature = sign_message(&key, message).unwrap();

        // Load public key and verify
        let pub_key = load_public_key(&dir.path().join("signing-key.pub")).unwrap();
        verify_signature(&pub_key, message, &signature).unwrap();
    }

    #[test]
    fn test_signature_tamper_detection() {
        let dir = tempdir().unwrap();
        let (key, _) = generate_key("Test User", "test@example.org", dir.path()).unwrap();

        let message = b"original message";
        let signature = sign_message(&key, message).unwrap();

        let pub_key = load_public_key(&dir.path().join("signing-key.pub")).unwrap();

        // Verify with wrong message should fail
        let wrong_message = b"tampered message";
        let result = verify_signature(&pub_key, wrong_message, &signature);
        assert!(result.is_err());
    }

    #[test]
    fn test_fingerprint_format() {
        let dir = tempdir().unwrap();
        let (_, fingerprint) = generate_key("Test", "test@test.org", dir.path()).unwrap();

        // Hybrid fingerprint format
        assert!(fingerprint.starts_with("HYBRID:SHA256:"));
        // 32 hex chars (16 bytes)
        let hash_part = fingerprint.strip_prefix("HYBRID:SHA256:").unwrap();
        assert_eq!(hash_part.len(), 32);
    }
}
