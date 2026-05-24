---
name: android-compose-conventions
description: Use when editing Android Kotlin code, especially Jetpack Compose UI, Hilt DI, coroutines, or ViewModel state. Project uses modern AndroidX stack.
---
# Android / Compose Conventions

## Project assumption
- Kotlin 2.x, Compose BOM, Material 3.
- Gradle Kotlin DSL (`build.gradle.kts`).
- Hilt for DI unless evidence says otherwise.

## State + ViewModel
- UI state held in `ViewModel`, exposed as `StateFlow<UiState>`.
- One sealed class `UiState` per screen — `Loading | Success(data) | Error(message)`.
- Compose reads with `collectAsStateWithLifecycle()`. NOT plain `collectAsState()`.

```kotlin
@HiltViewModel
class TaskListViewModel @Inject constructor(...) : ViewModel() {
    private val _uiState = MutableStateFlow<UiState>(UiState.Loading)
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()
}
```

## Compose rules
- `@Composable` functions: PascalCase, return `Unit`.
- Hoist state: composables take state + callbacks, don't hold mutable state.
- Use `remember` only for local UI state (expanded/collapsed, scroll position).
- Preview parameters via `@PreviewParameter`, not by mutating in the preview body.
- Modifier always last parameter, defaults to `Modifier`.

## Don't
- Use `LiveData` in new code. `StateFlow` everywhere.
- Use `findViewById` / View XML in a Compose-first module.
- Catch all exceptions in a coroutine — let them propagate to a `CoroutineExceptionHandler`.
- Hardcode strings in composables — use `stringResource(R.string.…)`.

## Gradle commands
```bash
./gradlew assembleDebug
./gradlew test                            # unit tests
./gradlew connectedAndroidTest            # instrumentation, needs device
./gradlew lint
./gradlew :app:dependencies | head -60    # check actual classpath
```

## Verify
- `./gradlew assembleDebug` exit 0.
- `./gradlew test` — quote N passed / N failed.
- For UI work: state the test device (emulator API level) or admit "manual smoke needed".
