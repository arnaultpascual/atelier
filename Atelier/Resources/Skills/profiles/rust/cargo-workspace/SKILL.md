---
name: cargo-workspace
description: Use when working in a Rust project. Reference for Cargo commands, workspace layout, and the most common build/test/lint flags.
---
# Cargo / Workspace

## Layout — single crate
```
Cargo.toml
src/lib.rs       (library)  OR  src/main.rs (bin)
tests/           integration tests
benches/         benchmarks
```

## Layout — workspace
```
Cargo.toml      [workspace] members = ["crates/*"]
crates/
  foo/          Cargo.toml + src/lib.rs
  bar/
```

## Daily commands
```bash
cargo build                    # debug
cargo build --release
cargo test                     # all tests
cargo test foo::bar            # by name
cargo test -p crate_name       # workspace, one crate
cargo clippy -- -D warnings    # lint, warnings=errors
cargo fmt --all
cargo check                    # type-check only, fast
```

## Workspace-aware
- `cargo build` at the root builds all members.
- `cargo run -p binary_crate` to pick one binary in a workspace.
- Add new member → list it under `[workspace] members` AND it's automatically picked up.

## Dependency rules
- Pin major versions in `Cargo.toml`. `1.x` is implicit; explicit major is fine.
- Use `workspace = true` for shared deps: declare once in root, reference in members.
- Dev-deps under `[dev-dependencies]`. Build-time codegen under `[build-dependencies]`.

## Don't
- Commit `Cargo.lock` for libraries. DO commit it for binaries/apps.
- Add a dep without checking it actually adds value over `std`.
- Use `unwrap()` outside tests and binaries with documented preconditions.

## Verify
- `cargo check` → 0 errors.
- `cargo clippy -- -D warnings` → 0 errors.
- `cargo test` → quote `test result: ok. N passed; M failed; ...`.
