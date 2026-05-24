---
name: python-modern-conventions
description: Use when writing or modifying Python code in a project that uses pyproject.toml, ruff, mypy, or any modern (Python 3.10+) toolchain.
---
# Modern Python Conventions

## Project assumption
- Python ≥ 3.10. Type hints throughout.
- `pyproject.toml` is the source of truth — not `setup.py` or `requirements.txt` for declaration.
- `ruff` for lint + format. `mypy` for type checks.

## Defaults
- Type hints on every public function: args + return.
- `list[str]`, `dict[str, int]` — built-in generics, not `List`/`Dict` from `typing`.
- `X | None` over `Optional[X]`.
- `from __future__ import annotations` at the top of every file when you need forward refs.
- Dataclasses (`@dataclass(frozen=True, slots=True)`) over hand-written `__init__`.

## Toolchain commands
```bash
ruff check . --fix              # lint + autofix
ruff format .                   # format
mypy .                          # type check
pytest                          # tests
pytest -k name_of_test          # single test
pytest -x --ff                  # stop on first fail, rerun failures first
```

## Env management
- `python -m venv .venv && source .venv/bin/activate` is fine for dev.
- `uv` if the project uses it (look for `uv.lock`).
- `poetry` if `poetry.lock` exists.
- Don't install globally with `pip install` — use the project's venv.

## Don't
- Use `os.path` for path manipulation. Use `pathlib.Path`.
- Catch bare `except:`. Catch specific exceptions.
- Use `print()` for diagnostics in library code. Use `logging`.
- Add a dependency without recording it in `pyproject.toml`.

## Verify
- `ruff check .` → no errors.
- `mypy .` → 0 errors (or current baseline if there's a known list).
- `pytest` → N passed, 0 failed. Quote exact count.
