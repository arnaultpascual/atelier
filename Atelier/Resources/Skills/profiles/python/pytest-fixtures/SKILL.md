---
name: pytest-fixtures
description: Use when writing or refactoring pytest tests, especially when fixtures, parametrization, or conftest.py organization is involved.
---
# Pytest Fixtures

## Layout
- Shared fixtures → `tests/conftest.py` at the relevant scope.
- Fixture scope defaults to `function`. Use `session` / `module` for expensive setup (DB, server).
- One test file per source module. `tests/foo_test.py` tests `src/foo.py`.

## Fixture patterns
```python
@pytest.fixture
def temp_db(tmp_path):
    path = tmp_path / "test.db"
    db = open_db(path)
    yield db          # cleanup after yield
    db.close()
```

## Parametrize, don't loop
```python
@pytest.mark.parametrize("input,expected", [
    ("hello", 5),
    ("", 0),
    ("π", 1),
])
def test_length(input, expected):
    assert length(input) == expected
```

## Markers
- `@pytest.mark.slow` → opt-in, skipped by default in CI fast lane.
- `@pytest.mark.parametrize(..., ids=[...])` to name cases readably.
- `pytest.skip("reason")` for runtime-conditional skips.

## Don't
- Use `setUp` / `tearDown` style — that's `unittest`. Use fixtures.
- Share mutable state between tests via module-level variables.
- Assert booleans only. Show the actual value: `assert result == 5, result`.
- Catch exceptions when testing — use `pytest.raises`.

## Verify
```bash
pytest -q                          # quiet, one char per test
pytest -q --no-header --no-summary # for piping
pytest --collect-only              # list tests without running
```
Quote `N passed, N failed in Xs` from the bottom of the output.
