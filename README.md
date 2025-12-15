# rookpkg

**The Rookery OS Package Manager**

A modern, security-focused package manager written in Rust featuring quantum-resistant cryptographic signatures.

## Features

- **Quantum-Resistant Signatures**: Hybrid Ed25519 + ML-DSA-65 (NIST FIPS 204) cryptographic signatures protect against both current and future quantum computing threats
- **PubGrub Dependency Resolution**: Advanced SAT-solver based algorithm for intelligent conflict resolution
- **Atomic Transactions**: All operations support rollback on failure, preventing partial/broken states
- **Delta Updates**: Incremental package updates to minimize download sizes
- **SQLite Database**: Robust package tracking with full ACID guarantees
- **Zstd Compression**: Fast, efficient package compression
- **Hook System**: Extensible post-transaction hooks for system integration

## Installation

### Building from Source

rookpkg is built using WSL with a Rookery OS image:

```bash
# In WSL with Rookery OS
cargo build --release

# Binary will be at target/release/rookpkg
```

### Requirements

- Rust 1.70+ (for building)
- SQLite 3.0+ (bundled)

### System Paths

| Path | Purpose |
|------|---------|
| `/etc/rookpkg/config.toml` | System configuration |
| `/etc/rookpkg/keys/master/` | Master signing keys |
| `/etc/rookpkg/keys/packager/` | Packager signing keys |
| `/etc/rookpkg/hooks.d/` | System hooks |
| `/var/lib/rookpkg/packages.db` | Package database |
| `/var/cache/rookpkg/` | Download cache |
| `~/.config/rookpkg/signing-key.secret` | User signing key |

## Usage

### Package Management

```bash
# Install packages
rookpkg install <package>           # From repository
rookpkg install --local file.rookpkg  # From local file

# Remove packages
rookpkg remove <package>
rookpkg remove --cascade <package>  # Also remove dependents

# Upgrade all packages
rookpkg upgrade

# Remove orphaned dependencies
rookpkg autoremove

# Hold/unhold packages from upgrades
rookpkg hold <package>
rookpkg unhold <package>
rookpkg holds                       # List held packages
```

### Querying

```bash
# List packages
rookpkg list                        # Installed packages
rookpkg list --available            # All available packages
rookpkg list --filter "pattern"     # Filter by pattern

# Search packages
rookpkg search <query>

# Show package info
rookpkg info <package>
rookpkg info --deps <package>       # Include dependencies

# Show dependency tree
rookpkg depends <package>
rookpkg depends --reverse <package> # Show reverse dependencies

# Verify installed package integrity
rookpkg check [package]
```

### Building Packages

```bash
# Build from spec file
rookpkg build package.rook

# Build and install
rookpkg build package.rook --install

# Build with delta generation
rookpkg build package.rook --delta-from old-package.rookpkg

# Build and update repository index
rookpkg build package.rook --index
```

### Repository Management

```bash
# Update repository metadata
rookpkg update

# Initialize a new repository
rookpkg repo init /path --name "myrepo"

# Refresh repository index
rookpkg repo refresh /path

# Sign repository index
rookpkg repo sign /path
```

### Key Management

```bash
# Generate signing key pair
rookpkg keygen --name "Your Name" --email "you@example.com"

# List trusted keys
rookpkg keylist

# Trust/untrust keys
rookpkg keytrust <fingerprint-or-file>
rookpkg keyuntrust <fingerprint>

# Create key certification (master certifies packager)
rookpkg keysign key.pub --master master.secret

# List certifications
rookpkg keycerts
```

### Delta Updates

```bash
# Build delta between versions
rookpkg delta build --old v1.rookpkg --new v2.rookpkg

# Apply delta
rookpkg delta apply --old v1.rookpkg --delta update.rookdelta

# Show delta info
rookpkg delta info update.rookdelta

# Generate delta index for repository
rookpkg delta index /repo/path
```

### Inspection & Verification

```bash
# Inspect package or spec
rookpkg inspect package.rookpkg
rookpkg inspect package.rook --validate

# Show files in package
rookpkg inspect package.rookpkg --files

# Verify package signature
rookpkg verify package.rookpkg
```

### System Maintenance

```bash
# Clean package cache
rookpkg clean              # Old packages (>30 days)
rookpkg clean --all        # All cached packages

# Recover from interrupted transactions
rookpkg recover

# Manage hooks
rookpkg hook list
rookpkg hook install myhook.hook
rookpkg hook remove myhook
```

### Global Options

```bash
-v, --verbose    # Increase verbosity (-v, -vv, -vvv)
-q, --quiet      # Suppress output
--config <path>  # Custom config file
--dry-run        # Preview changes (supported by install, remove, upgrade, autoremove)
```

## Package Specification (.rook files)

Packages are defined in TOML format:

```toml
[package]
name = "mypackage"
version = "1.0.0"
release = 1
summary = "Short description"
description = "Longer description"
license = "MIT"
maintainer = "you@example.com"
arch = "x86_64"

[sources]
source0 = { url = "https://...", sha256 = "..." }

[depends]
glibc = ">= 2.39"

[build_depends]
gcc = ">= 12"

[build]
prep = "tar xf $ROOKPKG_SOURCES/source0.tar.gz"
configure = "./configure --prefix=/usr"
build = "make -j$ROOKPKG_JOBS"
check = "make check"
install = "make DESTDIR=$ROOKPKG_DESTDIR install"

[files]
"usr/bin/myapp" = { mode = 755 }

[scripts]
post_install = "echo 'Installed!'"
```

## Configuration

Example `/etc/rookpkg/config.toml`:

```toml
[database]
path = "/var/lib/rookpkg/packages.db"

[cache]
dir = "/var/cache/rookpkg"

[signing]
master_keys_dir = "/etc/rookpkg/keys/master"
packager_keys_dir = "/etc/rookpkg/keys/packager"

[build]
dir = "/var/lib/rookpkg/build"
jobs = 0  # 0 = auto-detect CPU cores

[[repositories]]
name = "core"
url = "https://repo.rookeryos.dev/core"
enabled = true
priority = 100
```

## Security

rookpkg implements a defense-in-depth security model:

- **Mandatory Signatures**: All packages must be cryptographically signed
- **Hybrid Cryptography**: Ed25519 for current security, ML-DSA-65 for quantum resistance
- **Key Hierarchy**: Master keys certify packager keys via key certifications
- **Checksum Verification**: SHA256 verification of all downloads
- **Atomic Operations**: No partial states on failure

## Architecture

```
src/
├── main.rs          # Entry point, logging setup
├── cli/             # Command implementations (23+ subcommands)
├── config.rs        # TOML configuration
├── package.rs       # Package metadata types
├── spec.rs          # .rook spec file parser
├── database.rs      # SQLite operations
├── repository.rs    # Repository management
├── resolver.rs      # PubGrub dependency resolution
├── signing.rs       # Cryptographic operations
├── download.rs      # HTTP downloads with verification
├── archive.rs       # tar + zstd handling
├── build.rs         # Package building
├── transaction.rs   # Atomic transactions
├── hooks.rs         # Hook execution
├── delta.rs         # Delta package generation
└── error.rs         # Error types
```

## Dependencies

| Crate | Purpose |
|-------|---------|
| clap | CLI argument parsing |
| rusqlite | SQLite database |
| pubgrub | Dependency resolution |
| ed25519-dalek | Ed25519 signatures |
| ml-dsa | Post-quantum ML-DSA-65 |
| tar, zstd | Archive handling |
| reqwest | HTTP downloads |
| serde, toml | Configuration/spec parsing |

## License

MIT

## Authors

Friendly Society of Corvids

## Links

- Repository: https://github.com/dollspace-gay/rookpkg
- Homepage: https://github.com/dollspace-gay/rookpkg
