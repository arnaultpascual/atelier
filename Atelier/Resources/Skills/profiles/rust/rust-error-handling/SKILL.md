---
name: rust-error-handling
description: Use when adding error types, propagating errors, or refactoring `Result` handling in a Rust project. Picks between `anyhow`, `thiserror`, and bare `Result`.
---
# Rust Error Handling

## When to use what
- **Library crate** (others depend on you): hand-rolled enum + `thiserror` derive. Errors are part of the API.
- **Binary / application code** (top-level main, scripts): `anyhow::Result` for ergonomic propagation + context.
- **Internal module within a binary**: still prefer typed errors when there's branching on variant. `anyhow` is fine when you only ever bubble up.

## thiserror pattern
```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("missing field {0}")]
    MissingField(&'static str),
    #[error("invalid value for {field}: {value}")]
    InvalidValue { field: &'static str, value: String },
    #[error("io error")]
    Io(#[from] std::io::Error),
}
```

## anyhow pattern
```rust
use anyhow::{Context, Result, bail};

fn load(path: &Path) -> Result<Config> {
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("reading config at {}", path.display()))?;
    parse(&raw).context("parsing config")?
}
```
Always add `.context(...)` or `.with_context(...)` at boundaries — the trail of contexts IS the error message.

## Don't
- Use `.unwrap()` outside `main`, tests, or after a documented `panic!`-worthy invariant.
- Convert errors to `String` and lose the type. Use `From` impls or `?`.
- Mix `anyhow` and `thiserror` types in the same function signature without conversion.
- Catch errors just to print them — propagate, let the top decide what to log.

## Verify
- `cargo build` exit 0.
- `cargo test` — error paths covered.
- Trigger one error path manually if feasible and verify the message is useful: clear, contextual, no `<unknown>`.
