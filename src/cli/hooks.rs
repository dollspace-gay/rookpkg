//! Hooks management commands
//!
//! Commands for managing package transaction hooks.

use std::path::Path;

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::hooks::{HookEvent, HookManager};

/// List all installed hooks
pub fn list(config: &Config) -> Result<()> {
    let root = Path::new("/");
    let mut manager = HookManager::new(root);

    // Use custom hooks dir from config if set
    if config.hooks.hooks_dir != Path::new("/etc/rookpkg/hooks.d") {
        manager = HookManager::with_hooks_dir(root, &config.hooks.hooks_dir);
    }

    println!("{}", "Package hooks:".bold());
    println!();
    println!("  {}: {}", "Hooks directory".cyan(), manager.hooks_dir().display());
    println!(
        "  {}: {}",
        "Hooks enabled".cyan(),
        if config.hooks.enabled { "yes".green() } else { "no".red() }
    );
    println!();

    // Discover hooks
    let hooks = manager.discover_hooks()?;

    if hooks.is_empty() {
        println!("  {}", "No hooks installed.".dimmed());
        println!();
        println!("Hooks are scripts that run during package transactions.");
        println!("Place executable .hook files in {} to install hooks.", manager.hooks_dir().display());
        return Ok(());
    }

    println!("{}", "Installed hooks:".bold());
    println!();

    for hook in hooks {
        println!(
            "  {} {} (order: {})",
            "→".cyan(),
            hook.name.bold(),
            hook.order
        );

        // Show triggers
        let triggers: Vec<&str> = hook.events.iter().map(|t| match t {
            HookEvent::PreTransaction => "pre-transaction",
            HookEvent::PostTransaction => "post-transaction",
            HookEvent::TransactionFailed => "transaction-failed",
        }).collect();

        if !triggers.is_empty() {
            println!("    Triggers: {}", triggers.join(", ").cyan());
        }

        println!("    Path: {}", hook.path.display().to_string().dimmed());
        println!();
    }

    println!(
        "{} {} hook(s) installed",
        "→".cyan(),
        hooks.len()
    );

    Ok(())
}

/// Install a hook from a file
pub fn install(hook_path: &Path, order: Option<u32>, config: &Config) -> Result<()> {
    if !hook_path.exists() {
        bail!("Hook file not found: {}", hook_path.display());
    }

    let root = Path::new("/");
    let manager = if config.hooks.hooks_dir != Path::new("/etc/rookpkg/hooks.d") {
        HookManager::with_hooks_dir(root, &config.hooks.hooks_dir)
    } else {
        HookManager::new(root)
    };

    // Read the hook content
    let content = std::fs::read_to_string(hook_path)?;

    // Determine hook name from filename
    let name = hook_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("hook");

    // Use provided order or default to 50
    let hook_order = order.unwrap_or(50);

    // Ensure hooks directory exists
    manager.ensure_hooks_dir()?;

    // Install the hook
    let installed_path = manager.install_hook(name, &content, hook_order)?;

    println!("{}", "Hook installed successfully!".green().bold());
    println!();
    println!("  {}: {}", "Name".cyan(), name.bold());
    println!("  {}: {}", "Order".cyan(), hook_order);
    println!("  {}: {}", "Path".cyan(), installed_path.display());

    Ok(())
}

/// Remove a hook by name
pub fn remove(name: &str, config: &Config) -> Result<()> {
    let root = Path::new("/");
    let manager = if config.hooks.hooks_dir != Path::new("/etc/rookpkg/hooks.d") {
        HookManager::with_hooks_dir(root, &config.hooks.hooks_dir)
    } else {
        HookManager::new(root)
    };

    if manager.remove_hook(name)? {
        println!("{} Hook '{}' removed successfully.", "✓".green(), name.bold());
    } else {
        bail!("Hook '{}' not found.", name);
    }

    Ok(())
}
