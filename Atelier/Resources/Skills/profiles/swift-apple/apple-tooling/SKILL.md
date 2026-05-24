---
name: apple-tooling
description: Use when running Apple toolchain commands — xcodebuild, swift build, xcrun, simctl. Reference for the right flags and output parsing.
---
# Apple Tooling

## Build — Package.swift
```bash
swift build                            # debug
swift build -c release
swift test                             # all tests
swift test --filter MyTestClass.testFoo
```

## Build — Xcode project / workspace
```bash
xcodebuild -project Foo.xcodeproj -scheme Foo -destination 'generic/platform=macOS' build
xcodebuild -workspace Foo.xcworkspace -scheme Foo -destination 'platform=iOS Simulator,name=iPhone 15' build
```
- `-derivedDataPath build/DerivedData` keeps artifacts out of `~/Library`.
- `-quiet` suppresses build commands, keeps errors.
- Pipe through `xcbeautify` if available for readable output.

## Sim control
```bash
xcrun simctl list devices available
xcrun simctl boot "iPhone 15"
xcrun simctl install booted path/to/App.app
xcrun simctl launch booted com.acme.app
```

## Code signing for local runs
- `CODE_SIGN_STYLE=Automatic`
- `CODE_SIGN_IDENTITY="-"` (sign to run locally, no Developer ID)
- For distribution → ask, don't switch identities silently.

## Build error parsing
- `BUILD FAILED` line ends the output. Search upward for `error:`.
- Swift errors come with file:line. Always include both in your report.

## Don't
- Run `xcodebuild clean` unless build is corrupted. Wastes minutes.
- Open Xcode.app from the agent — it's a UI app, not a tool.
- Add `--quiet` and then claim "build succeeded" when you didn't see errors. Check the exit code.

## Verify build
```bash
xcodebuild ... build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10
```
