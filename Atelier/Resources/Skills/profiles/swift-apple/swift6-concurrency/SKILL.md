---
name: swift6-concurrency
description: Use when editing Swift code that touches actors, async/await, Sendable, MainActor, or strict concurrency warnings. Project is Swift 6 / strict concurrency.
---
# Swift 6 Concurrency

## Project assumption
Swift 6, strict concurrency on. Builds fail on data races, not just warn.

## Defaults
- Models/views/state holders SwiftUI uses → `@MainActor`.
- Long-running work / shared mutable state → `actor`.
- Plain value types that cross actor boundaries → must be `Sendable`. Add the conformance, don't just `@unchecked Sendable` away.

## Sendable cheatsheet
- Structs with all `Sendable` properties → conform automatically. Just declare.
- Classes → conform `Sendable` only if all stored properties are `let` and `Sendable`. Otherwise make it an actor or `@MainActor`-isolated.
- Closures crossing actor → `@Sendable` annotation.

## `nonisolated(unsafe)` — when allowed
ONLY for foundation types Apple ships that are thread-safe in practice but not formally marked Sendable (e.g. `ISO8601DateFormatter` for parsing). Comment why.

## `Task { ... }` rules
- `Task { @MainActor in ... }` for UI updates from non-main actors.
- `Task.detached` only when you need to escape the current actor's isolation. Document why.
- Always handle cancellation: check `Task.isCancelled` in long loops.

## Common errors and fixes
- "Stored property 'X' of 'Sendable'-conforming class 'Y' is mutable" → make property `let`, or make class an actor.
- "Capture of 'self' with non-sendable type" → mark closure `@Sendable` + ensure self is sendable; or use `await MainActor.run { ... }`.
- "Reference to captured var 'X' in concurrently-executing code" → assign to a `let` before the closure.

## Don't
- Sprinkle `@unchecked Sendable` to silence errors. Fix the real issue.
- Use `DispatchQueue.main.async` in new code. Use `await MainActor.run` or `@MainActor`.
- Mix Combine and async/await in the same flow. Pick one.

## Verify
- `swift build` for Package.swift projects.
- `xcodebuild -project … -scheme … build` for Xcode projects.
- Warnings about concurrency are errors in Swift 6. Treat as failures.
