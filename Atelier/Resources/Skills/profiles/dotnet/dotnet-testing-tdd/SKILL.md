---
name: dotnet-testing-tdd
description: Use when adding or changing .NET/C# behavior. Atelier enforces strict TDD — write the test first, run it red, implement, run it green. Covers xUnit/NUnit/MSTest, FluentAssertions/Moq, async tests, and scaffolding a missing test project.
---
# .NET Testing (strict TDD)

## The contract
Atelier runs `dotnet test` in your worktree after you finish. **A non-zero exit blocks the task from review and merge.** So:
1. Write the failing test FIRST. Run it, see it fail for the right reason.
2. Implement until it passes.
3. Re-run before you report done. Quote `Passed! N / Failed: 0`.

The gate is `dotnet test` — it compiles and runs the **test project**. That is fine; it is NOT a `dotnet publish` / app build. Do NOT rely on building or publishing the whole app to verify.

Tests are living: if the design legitimately changes, you MAY update a test to assert the **new** behavior at equal-or-greater strength — but declare it in `.atelier/test-changes/<task-id>.md`. NEVER delete a test, mark it `[Skip = "..."]` / `[Fact(Skip=...)]`, comment it out, or weaken an assertion to dodge a real failure — that is auto-detected and blocks the merge.

## Where tests live
- Test projects are separate `.csproj` files, conventionally `*Tests.csproj` / `*.Tests.csproj` or under a `test/` folder. Run by `dotnet test` (whole solution) or `dotnet test path/To/Project.Tests.csproj` (one project).
- Mirror the production namespace: a test for `Acme.Billing.InvoiceService` lives in `Acme.Billing.Tests/InvoiceServiceTests.cs`.
- Keep tests fast and in-process. There is no device/emulator tier here — everything the gate runs is a fast unit test.

## Toolkit
Use whatever the repo already uses — don't introduce a second framework. Detect it from the test `.csproj` (`xunit`, `nunit` / `NUnit3TestAdapter`, or `MSTest.TestFramework`).
- **xUnit** (default for new projects): `[Fact]` for a single case, `[Theory]` + `[InlineData(...)]` for parameterized. Setup goes in the constructor, teardown via `IDisposable`. Assert with `Assert.Equal(expected, actual)`.
- **NUnit**: `[Test]`, `[TestCase(...)]`, `[SetUp]`/`[TearDown]`, `Assert.That(actual, Is.EqualTo(expected))`.
- **MSTest**: `[TestMethod]`, `[DataRow(...)]`, `[TestInitialize]`, `Assert.AreEqual(expected, actual)`.
- **FluentAssertions** if present: `actual.Should().Be(expected)`, `act.Should().Throw<T>()` — more readable failures. Only if already referenced.
- **Moq** (or NSubstitute) for mocks if present: `var repo = new Mock<IRepo>(); repo.Setup(r => r.Load()).ReturnsAsync(items); repo.Verify(r => r.Load(), Times.Once);`.
- **Async**: make the test `async Task` and `await` the system under test — never `.Result` / `.Wait()` (deadlocks, hides failures).

```csharp
public class InvoiceServiceTests
{
    private readonly Mock<IRepo> _repo = new();

    [Fact]
    public async Task Totals_Sum_LineItems()
    {
        _repo.Setup(r => r.LoadAsync()).ReturnsAsync(new[] { new Line(2m), new Line(3m) });
        var sut = new InvoiceService(_repo.Object);

        var total = await sut.TotalAsync();

        Assert.Equal(5m, total);          // or: total.Should().Be(5m);
    }
}
```

## If no test project exists yet
Scaffold one — don't skip testing:
1. `dotnet new xunit -o <Name>.Tests` (mirror the production project's name).
2. Reference the system under test: `dotnet add <Name>.Tests reference <path/to/Sut>.csproj`.
3. Add it to the solution so the gate picks it up: `dotnet sln add <Name>.Tests` (if a `.sln`/`.slnx` exists).
4. Write the first failing test, then implement.

## Verify before done
- `dotnet test` → exit 0. Quote the summary line (`Passed! - Failed: 0, Passed: N`). **This is the gate.**
- Do NOT verify via `dotnet build`/`dotnet publish` of the app — Atelier does NOT build the app by default (it's opt-in per project). Keep verification to fast `dotnet test`.
- Deterministic only: no real network, no `Thread.Sleep` / wall-clock assumptions, no shared mutable static state across tests — flaky tests block the gate.
- Coverage (`dotnet test --collect:"XPlat Code Coverage"`) is collected by Atelier for the recette as **information only** — never raise or lower it as a goal, and never let a coverage number gate the change.
