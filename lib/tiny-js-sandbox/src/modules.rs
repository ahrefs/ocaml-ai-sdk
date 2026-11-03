//! The module registry behind `import`: names mapped to ES module source held in memory. Nothing is
//! read from the filesystem, so a name resolves only if the embedder registered it. Sources are
//! parsed on first import, not on registration.

use rquickjs::{loader::Loader, module::Declared, Ctx, Error, Module, Result, Runtime};
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    rc::Rc,
};

/// Longest module name, in bytes.
pub const MAX_NAME_BYTES: usize = 256;

#[derive(Debug, PartialEq, Eq)]
pub enum AddError {
    InvalidName,
    Duplicate,
}

impl std::fmt::Display for AddError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidName => write!(
                f,
                "invalid module name (1 to {MAX_NAME_BYTES} bytes of A-Z a-z 0-9 @ / . _ : -, not starting with '.')"
            ),
            Self::Duplicate => write!(f, "module is already registered"),
        }
    }
}

#[derive(Default)]
struct Registry {
    /// Every name ever added, so a name cannot be re-registered after its source was consumed.
    names: HashSet<String>,
    /// Sources not yet imported; the engine caches a module once declared.
    pending: HashMap<String, String>,
}

/// A shared handle on the registry; clones see the same modules.
#[derive(Clone, Default)]
pub struct Modules(Rc<RefCell<Registry>>);

fn valid_name(name: &str) -> bool {
    let allowed = |c: char| c.is_ascii_alphanumeric() || matches!(c, '@' | '/' | '.' | '_' | ':' | '-');
    !name.is_empty() && name.len() <= MAX_NAME_BYTES && !name.starts_with('.') && name.chars().all(allowed)
}

impl Modules {
    /// Registers `source` under `name`. Imports of other modules from inside it resolve by exact name
    /// too; relative specifiers are not supported.
    pub fn add(&self, name: &str, source: String) -> std::result::Result<(), AddError> {
        let mut registry = self.0.borrow_mut();
        match (valid_name(name), registry.names.contains(name)) {
            (false, _) => Err(AddError::InvalidName),
            (true, true) => Err(AddError::Duplicate),
            (true, false) => {
                registry.names.insert(name.to_string());
                registry.pending.insert(name.to_string(), source);
                Ok(())
            }
        }
    }

    /// Makes `import` (static or dynamic) resolve against this registry.
    pub fn install(&self, runtime: &Runtime) {
        runtime.set_loader(self.clone(), self.clone());
    }
}

impl rquickjs::loader::Resolver for Modules {
    fn resolve<'js>(
        &mut self,
        _ctx: &Ctx<'js>,
        base: &str,
        name: &str,
        _attributes: Option<rquickjs::loader::ImportAttributes<'js>>,
    ) -> Result<String> {
        match self.0.borrow().names.contains(name) {
            true => Ok(name.to_string()),
            false => Err(Error::new_resolving(base, name)),
        }
    }
}

impl Loader for Modules {
    fn load<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        name: &str,
        _attributes: Option<rquickjs::loader::ImportAttributes<'js>>,
    ) -> Result<Module<'js, Declared>> {
        // Taken out first: the borrow must not be held while the engine parses.
        let source = self.0.borrow_mut().pending.remove(name);
        match source {
            Some(source) => Module::declare(ctx.clone(), name, source),
            None => Err(Error::new_loading(name)),
        }
    }
}
