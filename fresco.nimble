# Package metadata for fresco — see DESIGN.md for architecture.

version       = "0.0.1"
author        = "Corey Leavitt"
description   = "Terminal-UI kernel: raw-mode input event stream + region rendering + composable widgets."
license       = "MIT"
srcDir        = "src"

# Library only — no `bin` line. Callers depend on `fresco` and import
# from `fresco/...` paths.

requires "nim >= 2.0.0"

# Async runtime. Must match recall (the primary downstream consumer)
# and any other Nim CLI that already commits to chronos. Pin loosely.
requires "chronos >= 4.0.0"

# Test runner. `nimble test` compiles each tests/**/*.nim file with
# std/unittest. Run via `./dev test`. List individual test files here
# as they land — keeps the harness simple + each test runnable in
# isolation.
task test, "run all tests":
  # Tier 1 (pure unit) — list each new test file here as it lands.
  # Tier 2 (PTY integration) tests live in tests/integration/.
  let unitTests = @[
    "tests/unit/test_ansi.nim",
    "tests/unit/test_events.nim",
    "tests/unit/test_termios.nim",
    "tests/unit/test_render.nim",
    "tests/unit/test_screen.nim",
    "tests/unit/test_layout.nim",
    "tests/unit/test_scrollback.nim",
    "tests/unit/test_diff.nim",
    "tests/unit/test_progress.nim",
  ]
  let integrationTests = @[
    "tests/integration/test_termios_pty.nim",
    "tests/integration/test_input_pty.nim",
    "tests/integration/test_select_pty.nim",
    "tests/integration/test_input_widget_pty.nim",
    "tests/integration/test_status_pty.nim",
    "tests/integration/test_review_pty.nim",
  ]
  for t in unitTests & integrationTests:
    exec "nim r --hints:off --warnings:off --path:src " & t

task examples, "compile-check every examples/*.nim":
  let examples = @[
    "examples/ex01_input_loop.nim",
    "examples/ex02_select.nim",
    "examples/ex03_status_line.nim",
    "examples/ex04_permission_prompt.nim",
  ]
  for e in examples:
    exec "nim check --hints:off --warnings:off --path:src " & e
