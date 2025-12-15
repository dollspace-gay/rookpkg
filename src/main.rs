//! rookpkg - Rookery OS Package Manager
//!
//! A lightweight, reliable package management system for Rookery OS.
//! Built in Rust for safety and performance.

use anyhow::Result;
use clap::Parser;
use tracing_subscriber::EnvFilter;

mod archive;
mod build;
mod cli;
mod config;
mod database;
mod delta;
mod download;
mod error;
mod hooks;
mod package;
mod repository;
mod resolver;
mod signing;
mod spec;
mod transaction;

use cli::Commands;

// Re-export error types for library users
pub use error::{Result as RookpkgResult, RookpkgError};

/// Rookery OS Package Manager
#[derive(Parser)]
#[command(name = "rookpkg")]
#[command(author = "Friendly Society of Corvids")]
#[command(version)]
#[command(about = "Rookery OS Package Manager", long_about = None)]
#[command(propagate_version = true)]
struct Cli {
    /// Increase verbosity (-v, -vv, -vvv)
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    verbose: u8,

    /// Suppress non-error output
    #[arg(short, long, global = true)]
    quiet: bool,

    /// Path to config file
    #[arg(long, global = true)]
    config: Option<std::path::PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    // Initialize logging
    let filter = match cli.verbose {
        0 if cli.quiet => "error",
        0 => "warn",
        1 => "info",
        2 => "debug",
        _ => "trace",
    };

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| filter.into()))
        .with_target(false)
        .init();

    // Load configuration
    let config = config::Config::load(cli.config.as_deref())?;

    // Execute command
    cli::execute(cli.command, &config)
}
