---
name: go-modules-conventions
description: Use when working in a Go project. Reference for go modules, the standard layout, common commands, and idiomatic error handling.
---
# Go / Modules

## Layout
```
go.mod
go.sum
main.go            (if binary)
cmd/<name>/main.go (if multi-binary)
internal/          packages only this module can import
pkg/               importable by others (optional, avoid unless multi-consumer)
```

## Daily commands
```bash
go build ./...
go test ./...
go test -run TestFoo -v ./pkg/foo
go vet ./...
go mod tidy
go mod download
gofmt -w .                       # or `gofumpt -w .` if installed
golangci-lint run                # if configured
```

## Error handling
- Errors are values. Return them, don't panic.
- Wrap with `fmt.Errorf("doing X: %w", err)` to preserve unwrap chain.
- Inspect with `errors.Is` / `errors.As`. Never `err.Error() == "..."`.
- Sentinel errors at package level: `var ErrNotFound = errors.New("not found")`.

## Don't
- Use `interface{}` / `any` when a concrete type works.
- Ignore errors with `_`. If you don't want to handle, comment why.
- Make exported names that don't need to be exported — lowercase by default.
- Add a dependency without `go mod tidy` after.

## Naming
- Package names: short, lowercase, no underscores. `httpcache` not `http_cache`.
- Files: `snake_case.go`.
- Tests: `xxx_test.go` next to the source.

## Verify
- `go build ./...` exit 0.
- `go test ./...` → quote `PASS` / `FAIL` summary.
- `go vet ./...` → 0 issues.
