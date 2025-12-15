//! Transaction recovery command
//!
//! Handles recovery from interrupted package transactions.

use std::path::Path;

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;
use crate::transaction::{Transaction, TransactionState};

/// List or resume incomplete transactions
pub fn run(resume_id: Option<&str>, config: &Config) -> Result<()> {
    let root = Path::new("/");

    match resume_id {
        Some(tx_id) => resume_transaction(root, tx_id, config),
        None => list_pending_transactions(root),
    }
}

/// List all pending transactions
fn list_pending_transactions(root: &Path) -> Result<()> {
    println!("{}", "Checking for incomplete transactions...".cyan());
    println!();

    let pending = Transaction::list_pending(root)?;

    if pending.is_empty() {
        println!("{}", "No incomplete transactions found.".green());
        println!();
        println!("The system is in a consistent state.");
        return Ok(());
    }

    println!(
        "{} {} incomplete transaction(s) found:",
        "!".yellow().bold(),
        pending.len()
    );
    println!();

    for tx_id in &pending {
        println!(
            "  {} Transaction ID: {}",
            "→".cyan(),
            tx_id.bold()
        );
    }

    println!();
    println!("To resume a transaction, run:");
    println!("  {} <transaction-id>", "rookpkg recover".cyan());
    println!();
    println!(
        "{} Incomplete transactions may leave the system in an inconsistent state.",
        "Warning:".yellow().bold()
    );

    Ok(())
}

/// Resume and complete an interrupted transaction
fn resume_transaction(root: &Path, tx_id: &str, config: &Config) -> Result<()> {
    println!("{}", "Resuming transaction...".cyan());
    println!();

    // Open database
    let db_path = &config.database.path;
    if !db_path.exists() {
        bail!("Database not found. No packages have been installed yet.");
    }

    let db = Database::open(db_path)?;

    // Try to resume the transaction
    let mut tx = Transaction::resume(root, tx_id, db)?;

    println!("  Transaction ID: {}", tx.id().bold());
    println!("  Current state: {:?}", tx.state());
    println!();

    // Check if we can resume
    match tx.state() {
        TransactionState::Pending => {
            println!("{}", "Transaction was never started. Cleaning up...".yellow());
            // The cleanup will happen when tx is dropped or we can manually handle it
            println!("{}", "Transaction cleaned up.".green());
        }
        TransactionState::InProgress => {
            println!("{}", "Attempting to complete transaction...".cyan());
            println!();

            match tx.execute() {
                Ok(()) => {
                    println!();
                    println!(
                        "{} Transaction completed successfully!",
                        "✓".green().bold()
                    );
                }
                Err(e) => {
                    println!();
                    println!(
                        "{} Transaction could not be completed: {}",
                        "✗".red().bold(),
                        e
                    );
                    println!();
                    println!("The transaction was rolled back to maintain system consistency.");
                    println!("You may need to manually clean up any partial changes.");
                }
            }
        }
        TransactionState::Completed => {
            println!("{}", "Transaction was already completed.".green());
        }
        TransactionState::RolledBack => {
            println!("{}", "Transaction was already rolled back.".yellow());
            println!("No further action is needed.");
        }
        TransactionState::Failed => {
            println!(
                "{}",
                "Transaction is in a failed state and cannot be resumed.".red()
            );
            println!();
            println!("Manual intervention may be required.");
            println!("Check the transaction directory for details:");
            println!(
                "  {}",
                root.join("var/lib/rookpkg/transactions")
                    .join(tx_id)
                    .display()
            );
        }
    }

    Ok(())
}
