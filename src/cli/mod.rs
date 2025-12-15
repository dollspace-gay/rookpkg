//! Command-line interface for rookpkg

use anyhow::{bail, Result};
use clap::Subcommand;
use colored::Colorize;

use crate::config::Config;

/// Check if the current user is root (UID 0)
fn is_root() -> bool {
    // On Unix systems, check effective UID
    #[cfg(unix)]
    {
        unsafe { libc::geteuid() == 0 }
    }
    // On non-Unix (shouldn't happen for rookpkg, but handle gracefully)
    #[cfg(not(unix))]
    {
        true // Assume root on non-Unix for now
    }
}

/// Require root privileges for system-modifying operations
///
/// If `dry_run` is true, root is not required (we're just showing what would happen).
fn require_root(operation: &str, dry_run: bool) -> Result<()> {
    if dry_run || is_root() {
        return Ok(());
    }

    bail!(
        "{} requires root privileges.\n\n\
        Run with sudo:\n  \
        {} rookpkg {}\n\n\
        Or use --dry-run to preview without making changes.",
        operation.cyan().bold(),
        "sudo".green(),
        operation
    );
}

mod autoremove;
mod build;
mod check;
mod delta;
mod depends;
mod groups;
mod hold;
mod hooks;
mod info;
mod inspect;
mod install;
mod keygen;
mod keys;
mod list;
mod recover;
mod remove;
mod repo;
mod search;
mod update;
mod upgrade;
mod verify;

#[derive(Subcommand)]
pub enum Commands {
    /// Install a package
    Install {
        /// Package name(s) to install, or path(s) to local .rookpkg files with --local
        #[arg(required = true)]
        packages: Vec<String>,

        /// Install from local .rookpkg file(s) instead of repository
        #[arg(long)]
        local: bool,

        /// Don't actually install, just show what would happen
        #[arg(long)]
        dry_run: bool,

        /// Download packages to cache but don't install them
        #[arg(long)]
        download_only: bool,
    },

    /// Remove a package
    Remove {
        /// Package name(s) to remove
        #[arg(required = true)]
        packages: Vec<String>,

        /// Also remove packages that depend on this package
        #[arg(long)]
        cascade: bool,

        /// Don't actually remove, just show what would happen
        #[arg(long)]
        dry_run: bool,
    },

    /// List installed packages
    List {
        /// Show all available packages (not just installed)
        #[arg(long)]
        available: bool,

        /// Filter by pattern
        #[arg(short, long)]
        filter: Option<String>,

        /// Show all versions of packages (with --available)
        #[arg(long)]
        all_versions: bool,
    },

    /// Show package information
    Info {
        /// Package name
        package: String,

        /// Show detailed dependency information
        #[arg(long)]
        deps: bool,
    },

    /// Search for packages
    Search {
        /// Search query
        query: String,
    },

    /// Build a package from a .rook spec file
    Build {
        /// Path to .rook spec file
        spec: std::path::PathBuf,

        /// Install after building
        #[arg(long)]
        install: bool,

        /// Output directory for built package
        #[arg(short, long)]
        output: Option<std::path::PathBuf>,

        /// Run all phases in sequence without detailed progress
        #[arg(long)]
        batch: bool,

        /// Update local repository index (packages.json) with built package
        #[arg(long)]
        index: bool,

        /// Generate delta from a previous package version
        #[arg(long)]
        delta_from: Option<std::path::PathBuf>,
    },

    /// Generate a new signing key
    Keygen {
        /// Your name
        #[arg(long)]
        name: String,

        /// Your email
        #[arg(long)]
        email: String,

        /// Output directory for keys
        #[arg(long)]
        output: Option<std::path::PathBuf>,
    },

    /// List trusted signing keys
    Keylist,

    /// Trust a signing key
    #[command(name = "keytrust")]
    KeyTrust {
        /// Key fingerprint or path to .pub file
        key: String,
    },

    /// Revoke trust for a signing key
    #[command(name = "keyuntrust")]
    KeyUntrust {
        /// Key fingerprint
        fingerprint: String,
    },

    /// Sign (certify) a packager key with a master key
    #[command(name = "keysign")]
    KeySign {
        /// Path to public key file to certify
        key: std::path::PathBuf,

        /// Path to master signing key (secret key)
        #[arg(long)]
        master: std::path::PathBuf,

        /// Certification purpose (default: "packager")
        #[arg(long)]
        purpose: Option<String>,

        /// Output path for certification file
        #[arg(short, long)]
        output: Option<std::path::PathBuf>,
    },

    /// List key certifications
    #[command(name = "keycerts")]
    KeyCerts {
        /// Filter by key fingerprint (optional)
        fingerprint: Option<String>,
    },

    /// Verify a package signature
    Verify {
        /// Path to package file
        package: std::path::PathBuf,
    },

    /// Update repository metadata
    Update,

    /// Upgrade installed packages
    Upgrade {
        /// Don't actually upgrade, just show what would happen
        #[arg(long)]
        dry_run: bool,
    },

    /// Show dependency tree for a package
    Depends {
        /// Package name
        package: String,

        /// Show reverse dependencies (what depends on this)
        #[arg(long)]
        reverse: bool,
    },

    /// Verify integrity of installed packages
    Check {
        /// Package name (or all if not specified)
        package: Option<String>,
    },

    /// Clean package cache
    Clean {
        /// Remove all cached packages
        #[arg(long)]
        all: bool,
    },

    /// List package groups
    Groups {
        /// Show packages in a specific group
        group: Option<String>,
    },

    /// Recover from incomplete transactions
    Recover {
        /// Transaction ID to resume (lists pending if not specified)
        transaction_id: Option<String>,
    },

    /// Hold a package (prevent automatic upgrades)
    Hold {
        /// Package name(s) to hold
        #[arg(required = true)]
        packages: Vec<String>,

        /// Reason for holding the package
        #[arg(long)]
        reason: Option<String>,
    },

    /// Unhold a package (allow automatic upgrades again)
    Unhold {
        /// Package name(s) to unhold
        #[arg(required = true)]
        packages: Vec<String>,
    },

    /// List held packages (or show details for a specific package)
    Holds {
        /// Package name to show detailed hold info for (optional)
        package: Option<String>,
    },

    /// Remove orphan packages (dependencies no longer needed)
    Autoremove {
        /// Don't actually remove, just show what would be removed
        #[arg(long)]
        dry_run: bool,
    },

    /// Mark a package as explicitly installed (won't be autoremoved)
    #[command(name = "mark-explicit")]
    MarkExplicit {
        /// Package name(s) to mark
        #[arg(required = true)]
        packages: Vec<String>,
    },

    /// Mark a package as a dependency (can be autoremoved if no longer needed)
    #[command(name = "mark-dep")]
    MarkDep {
        /// Package name(s) to mark
        #[arg(required = true)]
        packages: Vec<String>,
    },

    /// Inspect a package archive or spec file
    Inspect {
        /// Path to .rookpkg archive or .rook spec file
        path: std::path::PathBuf,

        /// Show all files in the package
        #[arg(long)]
        files: bool,

        /// Show install script contents
        #[arg(long)]
        scripts: bool,

        /// Validate spec file can be parsed and build environment created
        #[arg(long)]
        validate: bool,
    },

    /// Repository management commands
    #[command(subcommand)]
    Repo(RepoCommands),

    /// Delta package operations (incremental updates)
    #[command(subcommand)]
    Delta(DeltaCommands),

    /// Hook management commands
    #[command(subcommand)]
    Hook(HookCommands),
}

/// Repository management subcommands
#[derive(Subcommand)]
pub enum RepoCommands {
    /// Initialize a new repository
    Init {
        /// Path to repository directory
        path: std::path::PathBuf,

        /// Repository name
        #[arg(long)]
        name: String,

        /// Repository description
        #[arg(long, default_value = "A rookpkg package repository")]
        description: String,
    },

    /// Refresh the package index by scanning packages directory
    Refresh {
        /// Path to repository directory (default: current directory)
        #[arg(default_value = ".")]
        path: std::path::PathBuf,
    },

    /// Sign or re-sign the repository index
    Sign {
        /// Path to repository directory (default: current directory)
        #[arg(default_value = ".")]
        path: std::path::PathBuf,
    },
}

/// Delta package subcommands
#[derive(Subcommand)]
pub enum DeltaCommands {
    /// Build a delta package between two versions
    Build {
        /// Path to old package (.rookpkg)
        #[arg(long)]
        old: std::path::PathBuf,

        /// Path to new package (.rookpkg)
        #[arg(long)]
        new: std::path::PathBuf,

        /// Output directory for delta file
        #[arg(short, long, default_value = ".")]
        output: std::path::PathBuf,
    },

    /// Apply a delta to upgrade a package
    Apply {
        /// Path to old package (.rookpkg)
        #[arg(long)]
        old: std::path::PathBuf,

        /// Path to delta file (.rookdelta)
        #[arg(long)]
        delta: std::path::PathBuf,

        /// Output directory for new package
        #[arg(short, long, default_value = ".")]
        output: std::path::PathBuf,
    },

    /// Show information about a delta package
    Info {
        /// Path to delta file (.rookdelta)
        delta: std::path::PathBuf,
    },

    /// Generate delta index for a repository
    Index {
        /// Path to repository directory
        #[arg(default_value = ".")]
        path: std::path::PathBuf,
    },
}

/// Hook management subcommands
#[derive(Subcommand)]
pub enum HookCommands {
    /// List all installed hooks
    List,

    /// Install a hook from a file
    Install {
        /// Path to the hook file
        hook: std::path::PathBuf,

        /// Execution order (lower = earlier, default: 50)
        #[arg(long)]
        order: Option<u32>,
    },

    /// Remove a hook by name
    Remove {
        /// Hook name to remove
        name: String,
    },
}

/// Execute a CLI command
pub fn execute(command: Commands, config: &Config) -> Result<()> {
    match command {
        Commands::Install { packages, local, dry_run, download_only } => {
            // download_only doesn't need root since it only caches packages
            require_root("install", dry_run || download_only)?;
            install::run(&packages, local, dry_run, download_only, config)
        }
        Commands::Remove { packages, cascade, dry_run } => {
            require_root("remove", dry_run)?;
            remove::run(&packages, cascade, dry_run, config)
        }
        Commands::List { available, filter, all_versions } => {
            list::run(available, filter.as_deref(), all_versions, config)
        }
        Commands::Info { package, deps } => {
            info::run(&package, deps, config)
        }
        Commands::Search { query } => {
            search::run(&query, config)
        }
        Commands::Build { spec, install, output, batch, index, delta_from } => {
            build::run(&spec, install, output.as_deref(), batch, index, delta_from.as_deref(), config)
        }
        Commands::Keygen { name, email, output } => {
            keygen::run(&name, &email, output.as_deref(), config)
        }
        Commands::Keylist => {
            keys::list_keys(config)
        }
        Commands::KeyTrust { key } => {
            require_root("keytrust", false)?;  // modifies system keyring
            keys::trust_key(&key, config)
        }
        Commands::KeyUntrust { fingerprint } => {
            require_root("keyuntrust", false)?;  // modifies system keyring
            keys::untrust_key(&fingerprint, config)
        }
        Commands::KeySign { key, master, purpose, output } => {
            keys::sign_key(
                key.to_str().unwrap_or(""),
                master.to_str().unwrap_or(""),
                purpose.as_deref(),
                output.as_deref(),
                config,
            )
        }
        Commands::KeyCerts { fingerprint } => {
            keys::list_certifications(fingerprint.as_deref(), config)
        }
        Commands::Verify { package } => {
            verify::run(&package, config)
        }
        Commands::Update => {
            update::run(config)
        }
        Commands::Upgrade { dry_run } => {
            require_root("upgrade", dry_run)?;
            upgrade::run(dry_run, config)
        }
        Commands::Depends { package, reverse } => {
            depends::run(&package, reverse, config)
        }
        Commands::Check { package } => {
            check::run(package.as_deref(), config)
        }
        Commands::Clean { all } => {
            require_root("clean", false)?;  // clean always modifies system cache
            use crate::download::Downloader;
            use crate::repository::RepoManager;

            let manager = RepoManager::new(config)?;

            // Show cache directories
            tracing::debug!("Base cache: {}", manager.cache_dir().display());
            tracing::debug!("Package cache: {}", manager.package_cache_dir().display());

            // Clean package cache
            let pkg_result = if all {
                println!("{}", "Cleaning all cached packages...".cyan());
                manager.clean_all_packages()?
            } else {
                println!("{}", "Cleaning old cached packages (>30 days)...".cyan());
                manager.clean_package_cache(30)?
            };

            println!();
            if pkg_result.any_removed() {
                println!(
                    "  {} Removed {} package file(s), freed {}",
                    "✓".green(),
                    pkg_result.removed_files,
                    pkg_result.removed_bytes_human()
                );
            } else {
                println!("  Package cache is empty or no old packages found.");
            }
            // Show total cache size before cleaning
            println!(
                "  Total package cache: {}",
                pkg_result.total_bytes_human()
            );

            // Clean source download cache
            println!();
            if all {
                println!("{}", "Cleaning source download cache...".cyan());
            } else {
                println!("{}", "Cleaning old source downloads (>30 days)...".cyan());
            }

            let downloader = Downloader::new(config)?;
            println!("  Cache directory: {}", downloader.cache_dir().display());
            let days = if all { 0 } else { 30 };
            let src_bytes = downloader.clean_cache(days)?;

            if src_bytes > 0 {
                println!(
                    "  {} Freed {} from source cache",
                    "✓".green(),
                    format_bytes(src_bytes)
                );
            } else {
                println!("  Source cache is empty or no old downloads found.");
            }

            // Show total
            let total = pkg_result.removed_bytes + src_bytes;
            if total > 0 {
                println!();
                println!(
                    "{} Total space freed: {}",
                    "✓".green().bold(),
                    format_bytes(total)
                );
            }

            Ok(())
        }
        Commands::Groups { group } => {
            groups::run(group.as_deref(), config)
        }
        Commands::Recover { transaction_id } => {
            require_root("recover", false)?;  // recover modifies system state
            recover::run(transaction_id.as_deref(), config)
        }
        Commands::Hold { packages, reason } => {
            require_root("hold", false)?;  // modifies system database
            hold::hold(&packages, reason.as_deref(), config)
        }
        Commands::Unhold { packages } => {
            require_root("unhold", false)?;  // modifies system database
            hold::unhold(&packages, config)
        }
        Commands::Holds { package } => {
            if let Some(name) = package {
                hold::show_hold(&name, config)
            } else {
                hold::list_holds(config)
            }
        }
        Commands::Autoremove { dry_run } => {
            require_root("autoremove", dry_run)?;
            autoremove::run(dry_run, config)
        }
        Commands::MarkExplicit { packages } => {
            require_root("mark-explicit", false)?;  // modifies system database
            autoremove::mark_explicit(&packages, config)
        }
        Commands::MarkDep { packages } => {
            require_root("mark-dep", false)?;  // modifies system database
            autoremove::mark_dependency(&packages, config)
        }
        Commands::Inspect { path, files, scripts, validate } => {
            inspect::run(&path, files, scripts, validate, config)
        }
        Commands::Repo(subcmd) => {
            match subcmd {
                RepoCommands::Init { path, name, description } => {
                    repo::init(&path, &name, &description, config)
                }
                RepoCommands::Refresh { path } => {
                    repo::refresh(&path, config)
                }
                RepoCommands::Sign { path } => {
                    repo::sign(&path, config)
                }
            }
        }
        Commands::Delta(subcmd) => {
            match subcmd {
                DeltaCommands::Build { old, new, output } => {
                    delta::build(&old, &new, &output, config)
                }
                DeltaCommands::Apply { old, delta: delta_file, output } => {
                    delta::apply(&old, &delta_file, &output, config)
                }
                DeltaCommands::Info { delta: delta_file } => {
                    delta::info(&delta_file, config)
                }
                DeltaCommands::Index { path } => {
                    delta::index(&path, config)
                }
            }
        }
        Commands::Hook(subcmd) => {
            match subcmd {
                HookCommands::List => {
                    hooks::list(config)
                }
                HookCommands::Install { hook, order } => {
                    require_root("hook install", false)?;  // modifies system hooks
                    hooks::install(&hook, order, config)
                }
                HookCommands::Remove { name } => {
                    require_root("hook remove", false)?;  // modifies system hooks
                    hooks::remove(&name, config)
                }
            }
        }
    }
}

/// Format bytes as human-readable size
fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
