//! System-wide hooks for rookpkg
//!
//! Hooks are scripts stored in /etc/rookpkg/hooks.d/ that are triggered
//! on certain events during package transactions.
//!
//! Hook naming convention: `NN-name.hook` where NN is the execution order (00-99)
//!
//! Hooks receive environment variables with transaction context:
//! - ROOKPKG_HOOK_EVENT: The event type (pre-transaction, post-transaction)
//! - ROOKPKG_PACKAGES: Space-separated list of packages involved
//! - ROOKPKG_OPERATIONS: Space-separated list of operations (install, remove, upgrade)
//! - ROOKPKG_TRANSACTION_ID: Unique transaction identifier
//! - ROOKPKG_ROOT: Root filesystem path (usually /)

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

/// Hook event types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HookEvent {
    /// Before a transaction begins
    PreTransaction,
    /// After a transaction completes successfully
    PostTransaction,
    /// After a transaction fails (before rollback)
    TransactionFailed,
}

impl HookEvent {
    /// Get the event name as a string
    pub fn as_str(&self) -> &'static str {
        match self {
            HookEvent::PreTransaction => "pre-transaction",
            HookEvent::PostTransaction => "post-transaction",
            HookEvent::TransactionFailed => "transaction-failed",
        }
    }
}

impl std::fmt::Display for HookEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

/// Operation types for hook context
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookOperation {
    Install,
    Remove,
    Upgrade,
}

impl HookOperation {
    pub fn as_str(&self) -> &'static str {
        match self {
            HookOperation::Install => "install",
            HookOperation::Remove => "remove",
            HookOperation::Upgrade => "upgrade",
        }
    }
}

impl std::fmt::Display for HookOperation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

/// Context passed to hooks
#[derive(Debug, Clone)]
pub struct HookContext {
    /// The event being triggered
    pub event: HookEvent,
    /// Transaction ID
    pub transaction_id: String,
    /// Root filesystem path
    pub root: PathBuf,
    /// Packages involved in the transaction
    pub packages: Vec<String>,
    /// Operations being performed (package -> operation)
    pub operations: HashMap<String, HookOperation>,
}

impl HookContext {
    /// Create a new hook context
    pub fn new(event: HookEvent, transaction_id: &str, root: &Path) -> Self {
        Self {
            event,
            transaction_id: transaction_id.to_string(),
            root: root.to_path_buf(),
            packages: Vec::new(),
            operations: HashMap::new(),
        }
    }

    /// Add a package with its operation to the context
    pub fn add_package(&mut self, name: &str, operation: HookOperation) {
        if !self.packages.contains(&name.to_string()) {
            self.packages.push(name.to_string());
        }
        self.operations.insert(name.to_string(), operation);
    }

    /// Get environment variables for hooks
    pub fn env_vars(&self) -> HashMap<String, String> {
        let mut env = HashMap::new();

        env.insert(
            "ROOKPKG_HOOK_EVENT".to_string(),
            self.event.as_str().to_string(),
        );
        env.insert(
            "ROOKPKG_TRANSACTION_ID".to_string(),
            self.transaction_id.clone(),
        );
        env.insert(
            "ROOKPKG_ROOT".to_string(),
            self.root.to_string_lossy().to_string(),
        );
        env.insert(
            "ROOKPKG_PACKAGES".to_string(),
            self.packages.join(" "),
        );

        // Unique operation types
        let ops: Vec<&str> = self
            .operations
            .values()
            .map(|o| o.as_str())
            .collect::<std::collections::HashSet<_>>()
            .into_iter()
            .collect();
        env.insert("ROOKPKG_OPERATIONS".to_string(), ops.join(" "));

        // Individual package operations
        for (pkg, op) in &self.operations {
            let key = format!("ROOKPKG_OP_{}", pkg.to_uppercase().replace('-', "_"));
            env.insert(key, op.as_str().to_string());
        }

        env
    }
}

/// A system hook definition
#[derive(Debug, Clone)]
pub struct Hook {
    /// Hook file path
    pub path: PathBuf,
    /// Hook name (derived from filename)
    pub name: String,
    /// Execution order (from NN- prefix)
    pub order: u32,
    /// Events this hook triggers on
    pub events: Vec<HookEvent>,
}

impl Hook {
    /// Parse a hook file
    pub fn from_path(path: &Path) -> Result<Self> {
        let filename = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| anyhow::anyhow!("Invalid hook path: {}", path.display()))?;

        // Extract order from NN- prefix
        let (order, name) = if filename.len() > 3 && filename.chars().take(2).all(|c| c.is_ascii_digit()) && filename.chars().nth(2) == Some('-') {
            let order: u32 = filename[..2].parse().unwrap_or(50);
            let name = filename[3..].trim_end_matches(".hook");
            (order, name.to_string())
        } else {
            (50, filename.trim_end_matches(".hook").to_string())
        };

        // Read hook file to parse events
        let content = fs::read_to_string(path)
            .with_context(|| format!("Failed to read hook: {}", path.display()))?;

        let events = Self::parse_events(&content)?;

        Ok(Self {
            path: path.to_path_buf(),
            name,
            order,
            events,
        })
    }

    /// Parse events from hook file content
    ///
    /// Hook files can specify which events they trigger on with a comment:
    /// # EVENTS: pre-transaction post-transaction
    ///
    /// If not specified, defaults to all events.
    fn parse_events(content: &str) -> Result<Vec<HookEvent>> {
        for line in content.lines() {
            let line = line.trim();
            if line.starts_with("# EVENTS:") || line.starts_with("#EVENTS:") {
                let events_str = line
                    .trim_start_matches('#')
                    .trim()
                    .trim_start_matches("EVENTS:")
                    .trim();

                let mut events = Vec::new();
                for event_name in events_str.split_whitespace() {
                    match event_name {
                        "pre-transaction" => events.push(HookEvent::PreTransaction),
                        "post-transaction" => events.push(HookEvent::PostTransaction),
                        "transaction-failed" => events.push(HookEvent::TransactionFailed),
                        _ => {
                            tracing::warn!("Unknown hook event: {}", event_name);
                        }
                    }
                }

                if !events.is_empty() {
                    return Ok(events);
                }
            }
        }

        // Default to post-transaction only (safest default)
        Ok(vec![HookEvent::PostTransaction])
    }

    /// Check if this hook should run for the given event
    pub fn triggers_on(&self, event: HookEvent) -> bool {
        self.events.contains(&event)
    }
}

/// Hook execution result
#[derive(Debug)]
pub struct HookResult {
    /// Hook name
    pub name: String,
    /// Whether the hook succeeded
    pub success: bool,
    /// Exit code
    pub exit_code: Option<i32>,
    /// Standard output
    pub stdout: String,
    /// Standard error
    pub stderr: String,
}

/// Hook manager for discovering and running system hooks
pub struct HookManager {
    /// Directory containing hooks
    hooks_dir: PathBuf,
    /// Root filesystem path
    root: PathBuf,
    /// Cached list of discovered hooks
    hooks: Vec<Hook>,
}

impl HookManager {
    /// Create a new hook manager
    pub fn new(root: &Path) -> Self {
        Self {
            hooks_dir: root.join("etc/rookpkg/hooks.d"),
            root: root.to_path_buf(),
            hooks: Vec::new(),
        }
    }

    /// Create a hook manager with a custom hooks directory
    pub fn with_hooks_dir(root: &Path, hooks_dir: &Path) -> Self {
        Self {
            hooks_dir: hooks_dir.to_path_buf(),
            root: root.to_path_buf(),
            hooks: Vec::new(),
        }
    }

    /// Get the hooks directory path
    pub fn hooks_dir(&self) -> &Path {
        &self.hooks_dir
    }

    /// Discover all available hooks
    pub fn discover_hooks(&mut self) -> Result<&[Hook]> {
        self.hooks.clear();

        if !self.hooks_dir.exists() {
            tracing::debug!("Hooks directory does not exist: {}", self.hooks_dir.display());
            return Ok(&self.hooks);
        }

        let entries = fs::read_dir(&self.hooks_dir)
            .with_context(|| format!("Failed to read hooks directory: {}", self.hooks_dir.display()))?;

        for entry in entries {
            let entry = entry?;
            let path = entry.path();

            // Skip if not a file
            if !path.is_file() {
                continue;
            }

            // Skip if not a .hook file
            let filename = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if !filename.ends_with(".hook") {
                continue;
            }

            // Skip hidden files
            if filename.starts_with('.') {
                continue;
            }

            // Check if executable
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let metadata = fs::metadata(&path)?;
                let permissions = metadata.permissions();
                if permissions.mode() & 0o111 == 0 {
                    tracing::debug!("Skipping non-executable hook: {}", path.display());
                    continue;
                }
            }

            match Hook::from_path(&path) {
                Ok(hook) => {
                    tracing::debug!("Discovered hook: {} (order: {})", hook.name, hook.order);
                    self.hooks.push(hook);
                }
                Err(e) => {
                    tracing::warn!("Failed to parse hook {}: {}", path.display(), e);
                }
            }
        }

        // Sort by order
        self.hooks.sort_by_key(|h| h.order);

        Ok(&self.hooks)
    }

    /// Get hooks that trigger on a specific event
    pub fn hooks_for_event(&self, event: HookEvent) -> Vec<&Hook> {
        self.hooks
            .iter()
            .filter(|h| h.triggers_on(event))
            .collect()
    }

    /// Run all hooks for an event
    ///
    /// Returns a list of results for each hook that was run.
    /// If `fail_fast` is true, stops on the first failure and returns an error.
    pub fn run_hooks(
        &self,
        context: &HookContext,
        fail_fast: bool,
    ) -> Result<Vec<HookResult>> {
        let hooks = self.hooks_for_event(context.event);

        if hooks.is_empty() {
            tracing::debug!("No hooks for event: {}", context.event);
            return Ok(Vec::new());
        }

        tracing::info!("Running {} hook(s) for event: {}", hooks.len(), context.event);

        let mut results = Vec::new();
        let env_vars = context.env_vars();

        for hook in hooks {
            let result = self.run_single_hook(hook, &env_vars)?;

            let success = result.success;
            results.push(result);

            if !success && fail_fast {
                let failed = results.last().unwrap();
                bail!(
                    "Hook '{}' failed with exit code {}: {}",
                    failed.name,
                    failed.exit_code.unwrap_or(-1),
                    failed.stderr.lines().next().unwrap_or("unknown error")
                );
            }
        }

        Ok(results)
    }

    /// Run a single hook
    fn run_single_hook(
        &self,
        hook: &Hook,
        env_vars: &HashMap<String, String>,
    ) -> Result<HookResult> {
        tracing::debug!("Running hook: {} ({})", hook.name, hook.path.display());

        // Create a wrapper script that sources the hook
        // This allows hooks to be either executable scripts or shell scripts
        let mut cmd = Command::new("/bin/bash");
        cmd.arg(&hook.path)
            .current_dir(&self.root);

        // Set environment variables
        for (key, value) in env_vars {
            cmd.env(key, value);
        }

        let output = cmd
            .output()
            .with_context(|| format!("Failed to execute hook: {}", hook.name))?;

        let result = HookResult {
            name: hook.name.clone(),
            success: output.status.success(),
            exit_code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        };

        if result.success {
            tracing::debug!("Hook '{}' completed successfully", hook.name);
        } else {
            tracing::warn!(
                "Hook '{}' failed with exit code {}",
                hook.name,
                result.exit_code.unwrap_or(-1)
            );
            if !result.stderr.is_empty() {
                tracing::warn!("Hook stderr: {}", result.stderr);
            }
        }

        Ok(result)
    }

    /// Create the hooks directory if it doesn't exist
    pub fn ensure_hooks_dir(&self) -> Result<()> {
        if !self.hooks_dir.exists() {
            fs::create_dir_all(&self.hooks_dir)
                .with_context(|| format!("Failed to create hooks directory: {}", self.hooks_dir.display()))?;
        }
        Ok(())
    }

    /// Install a hook from content
    pub fn install_hook(&self, name: &str, content: &str, order: u32) -> Result<PathBuf> {
        self.ensure_hooks_dir()?;

        let filename = format!("{:02}-{}.hook", order, name);
        let hook_path = self.hooks_dir.join(&filename);

        let mut file = fs::File::create(&hook_path)
            .with_context(|| format!("Failed to create hook: {}", hook_path.display()))?;

        file.write_all(content.as_bytes())?;

        // Make executable on Unix
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&hook_path)?.permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&hook_path, perms)?;
        }

        tracing::info!("Installed hook: {}", filename);
        Ok(hook_path)
    }

    /// Remove a hook by name
    pub fn remove_hook(&self, name: &str) -> Result<bool> {
        // Find the hook file (might have NN- prefix)
        if !self.hooks_dir.exists() {
            return Ok(false);
        }

        let entries = fs::read_dir(&self.hooks_dir)?;

        for entry in entries {
            let entry = entry?;
            let path = entry.path();
            let filename = path.file_name().and_then(|n| n.to_str()).unwrap_or("");

            // Check if this matches our hook name
            let hook_name = if filename.len() > 3
                && filename.chars().take(2).all(|c| c.is_ascii_digit())
                && filename.chars().nth(2) == Some('-')
            {
                filename[3..].trim_end_matches(".hook")
            } else {
                filename.trim_end_matches(".hook")
            };

            if hook_name == name {
                fs::remove_file(&path)?;
                tracing::info!("Removed hook: {}", filename);
                return Ok(true);
            }
        }

        Ok(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_hook_event_as_str() {
        assert_eq!(HookEvent::PreTransaction.as_str(), "pre-transaction");
        assert_eq!(HookEvent::PostTransaction.as_str(), "post-transaction");
        assert_eq!(HookEvent::TransactionFailed.as_str(), "transaction-failed");
    }

    #[test]
    fn test_hook_context_env_vars() {
        let mut ctx = HookContext::new(HookEvent::PreTransaction, "tx-123", Path::new("/"));
        ctx.add_package("foo", HookOperation::Install);
        ctx.add_package("bar", HookOperation::Remove);

        let env = ctx.env_vars();

        assert_eq!(env.get("ROOKPKG_HOOK_EVENT").unwrap(), "pre-transaction");
        assert_eq!(env.get("ROOKPKG_TRANSACTION_ID").unwrap(), "tx-123");
        assert_eq!(env.get("ROOKPKG_ROOT").unwrap(), "/");
        assert!(env.get("ROOKPKG_PACKAGES").unwrap().contains("foo"));
        assert!(env.get("ROOKPKG_PACKAGES").unwrap().contains("bar"));
        assert_eq!(env.get("ROOKPKG_OP_FOO").unwrap(), "install");
        assert_eq!(env.get("ROOKPKG_OP_BAR").unwrap(), "remove");
    }

    #[test]
    fn test_hook_parse_events() {
        let content_with_events = r#"#!/bin/bash
# EVENTS: pre-transaction post-transaction
echo "Hello from hook"
"#;
        let events = Hook::parse_events(content_with_events).unwrap();
        assert_eq!(events.len(), 2);
        assert!(events.contains(&HookEvent::PreTransaction));
        assert!(events.contains(&HookEvent::PostTransaction));

        let content_no_events = r#"#!/bin/bash
echo "Hello from hook"
"#;
        let events = Hook::parse_events(content_no_events).unwrap();
        // Default is post-transaction only
        assert_eq!(events, vec![HookEvent::PostTransaction]);
    }

    #[test]
    fn test_hook_from_path() {
        let temp = tempdir().unwrap();
        let hook_path = temp.path().join("10-test-hook.hook");

        fs::write(&hook_path, "#!/bin/bash\n# EVENTS: pre-transaction\necho test").unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&hook_path).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&hook_path, perms).unwrap();
        }

        let hook = Hook::from_path(&hook_path).unwrap();

        assert_eq!(hook.name, "test-hook");
        assert_eq!(hook.order, 10);
        assert!(hook.triggers_on(HookEvent::PreTransaction));
        assert!(!hook.triggers_on(HookEvent::PostTransaction));
    }

    #[test]
    fn test_hook_manager_discover() {
        let temp = tempdir().unwrap();
        let hooks_dir = temp.path().join("etc/rookpkg/hooks.d");
        fs::create_dir_all(&hooks_dir).unwrap();

        // Create some hooks
        let hook1 = hooks_dir.join("10-first.hook");
        let hook2 = hooks_dir.join("20-second.hook");

        fs::write(&hook1, "#!/bin/bash\necho first").unwrap();
        fs::write(&hook2, "#!/bin/bash\necho second").unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for path in [&hook1, &hook2] {
                let mut perms = fs::metadata(path).unwrap().permissions();
                perms.set_mode(0o755);
                fs::set_permissions(path, perms).unwrap();
            }
        }

        let mut manager = HookManager::new(temp.path());

        // Verify hooks_dir() returns the correct path
        assert_eq!(manager.hooks_dir(), hooks_dir);

        let hooks = manager.discover_hooks().unwrap();

        assert_eq!(hooks.len(), 2);
        // Should be sorted by order
        assert_eq!(hooks[0].name, "first");
        assert_eq!(hooks[0].order, 10);
        assert_eq!(hooks[1].name, "second");
        assert_eq!(hooks[1].order, 20);
    }

    #[test]
    fn test_hook_manager_install_remove() {
        let temp = tempdir().unwrap();
        let manager = HookManager::new(temp.path());

        let content = "#!/bin/bash\n# EVENTS: pre-transaction\necho test";
        let path = manager.install_hook("my-hook", content, 15).unwrap();

        assert!(path.exists());
        assert!(path.file_name().unwrap().to_str().unwrap().contains("15-my-hook"));

        let removed = manager.remove_hook("my-hook").unwrap();
        assert!(removed);
        assert!(!path.exists());

        let removed_again = manager.remove_hook("my-hook").unwrap();
        assert!(!removed_again);
    }
}
