---
name: android-testing-tdd
description: Use when adding or changing Android/Kotlin behavior. Atelier enforces strict TDD — write the test first, run it red, implement, run it green. Covers JUnit/MockK/Turbine, the JVM-vs-instrumented split, and scaffolding a missing test source set.
---
# Android Testing (strict TDD)

## The contract
Atelier runs `./gradlew testDebugUnitTest` in your worktree after you finish. **A non-zero exit blocks the task from review and merge.** So:
1. Write the failing test FIRST. Run it, see it fail for the right reason.
2. Implement until it passes.
3. Re-run before you report done. Quote `N passed / N failed`.

Tests are living: if the design legitimately changes, you MAY update a test to assert the **new** behavior at equal-or-greater strength — but declare it in `.atelier/test-changes/<task-id>.md`. NEVER delete, `@Ignore`, or weaken a test to dodge a real failure — that is auto-detected and blocks the merge.

## Where tests live
- **JVM unit tests** → `src/test/java/<pkg>/` or `src/test/kotlin/<pkg>/`. Run by `./gradlew testDebugUnitTest`. Fast, no device. **This is the gate — default here.**
- **Instrumented / UI tests** → `src/androidTest/`. Run by `./gradlew connectedDebugAndroidTest`. Needs a device/emulator. Atelier does NOT auto-run these — only add one when a JVM test genuinely can't cover the change (real UI, real DB, real navigation).

## Toolkit
- **JUnit4** (`@Test`, `@Before`) is the baseline. JUnit5 if the module already uses it.
- **MockK** for mocks: `mockk()`, `every { ... } returns ...`, `coEvery` for suspend, `verify { ... }`.
- **Coroutines**: `runTest { }` + `StandardTestDispatcher`; inject the dispatcher, don't hardcode `Dispatchers.Main`.
- **Flow / StateFlow**: assert with **Turbine** (`flow.test { assertEquals(..., awaitItem()) }`) if available; else collect into a list with a `TestScope`.
- **Compose unit logic**: test the ViewModel's `StateFlow<UiState>` transitions in `src/test` — that's JVM and gates. Reserve `createComposeRule()` UI assertions for `src/androidTest`.

```kotlin
class TaskListViewModelTest {
    private val repo = mockk<TaskRepository>()
    private val dispatcher = StandardTestDispatcher()

    @Test
    fun `emits Success when repo returns tasks`() = runTest(dispatcher) {
        coEvery { repo.load() } returns listOf(Task("t1"))
        val vm = TaskListViewModel(repo, dispatcher)
        vm.uiState.test {
            assertEquals(UiState.Loading, awaitItem())
            assertEquals(UiState.Success(listOf(Task("t1"))), awaitItem())
        }
    }
}
```

## If no test source set exists yet
Scaffold it — don't skip testing:
1. Create `src/test/java/<pkg>/` (mirror the production package).
2. Ensure `build.gradle.kts` has the test deps; add if missing:
```kotlin
testImplementation("junit:junit:4.13.2")
testImplementation("io.mockk:mockk:1.13.+")
testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.+")
// optional: testImplementation("app.cash.turbine:turbine:1.+")
```
3. Write the first failing test, then implement.

## Verify before done
- `./gradlew testDebugUnitTest` → exit 0, quote `N passed / N failed`. **This is the gate.**
- Do NOT rely on assembling the whole app to verify — `./gradlew assembleDebug` can need an SDK/target and take many minutes, and Atelier does NOT build the app by default (it's opt-in per project). Keep verification to fast JVM unit tests.
- Deterministic only: no real network, no `Thread.sleep`, no time-of-day assumptions — flaky tests block the gate.
