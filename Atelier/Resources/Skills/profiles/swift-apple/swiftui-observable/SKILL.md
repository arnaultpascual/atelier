---
name: swiftui-observable
description: Use when editing SwiftUI views, view models, or anything that holds UI state. Project uses @Observable macro (iOS 17 / macOS 14+), not ObservableObject.
---
# SwiftUI @Observable

## Project assumption
- Deployment target ≥ iOS 17 / macOS 14.
- New state types use `@Observable`. `ObservableObject` is legacy.

## Models
```swift
@Observable
final class TaskState {
    var items: [Item] = []
    var status: Status = .idle
}
```
- No `@Published` properties.
- No explicit `objectWillChange.send()`.
- Final class. `@MainActor` if it owns UI state.

## In views
```swift
@State private var state = TaskState()           // owning
@Bindable var state: TaskState                   // received, want bindings
let state: TaskState                             // received, read-only
```
- `@StateObject` → don't use. `@State` is enough for `@Observable`.
- `@ObservedObject` → don't use. Pass directly.
- `@EnvironmentObject` → use `.environment(state)` + `@Environment(TaskState.self)`.

## Bindings
Use `@Bindable` for two-way:
```swift
@Bindable var state: TaskState
...
TextField("Title", text: $state.title)
```

For computed bindings:
```swift
Toggle("On", isOn: Binding(
    get: { state.isOn },
    set: { state.isOn = $0 }
))
```

## Watching changes
- `.onChange(of: state.value) { _, newValue in ... }` — `of:` reads the new closure form, two params.
- `withObservationTracking` for non-view subscribers.

## Don't
- Mix `@Observable` and `ObservableObject` in the same model.
- Mark properties `@Published` — it's a no-op and confuses readers.
- Pass `Binding<X>` through 5+ layers of views. Pass the `@Bindable` model down.

## Verify
- Build green.
- Drive the feature in the app, not just type-check.
