# Package metadata for fresco — see DESIGN.md for architecture.

version       = "0.0.1"
author        = "Corey Leavitt"
description   = "Terminal-UI kernel: raw-mode input + region-based rendering + reactive task system."
license       = "MIT"
srcDir        = "src"

# Library only — no `bin` line. Callers depend on `fresco` and import
# from `fresco/...` paths.

requires "nim >= 2.0.0"

# Async runtime. Pinned to our fork's `feat/contextvars` branch while
# the upstream PR (continuation-local storage primitive — see
# docs/rfc-chronos-contextvars.md) is in review. When upstream accepts,
# this drops back to `requires "chronos >= <version-with-contextvars>"`.
# amoxtli rides the same fork during the interim.
requires "https://github.com/coreyleavitt/chronos.git#feat/contextvars"

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
    "tests/unit/test_reactive.nim",
    "tests/unit/test_binding.nim",
    "tests/unit/test_context.nim",
    "tests/unit/test_dsl.nim",
    "tests/unit/test_aggregate_import.nim",
    "tests/unit/test_journal.nim",
    "tests/unit/test_speculative.nim",
    "tests/unit/test_bitemporal.nim",
    "tests/unit/test_collection.nim",
    "tests/unit/test_static_graph.nim",
    "tests/unit/test_capabilities.nim",
  ]
  let integrationTests = @[
    "tests/integration/test_termios_pty.nim",
    "tests/integration/test_input_pty.nim",
    "tests/integration/test_task.nim",
    "tests/integration/test_receive_pty.nim",
    "tests/integration/test_parallel.nim",
    "tests/integration/test_mount.nim",
    "tests/integration/test_hotkey_pty.nim",
    "tests/integration/test_supervisor.nim",
    "tests/integration/test_spawn_modifiers.nim",
    "tests/integration/test_journal_task.nim",
    "tests/integration/test_journal_signal.nim",
    "tests/integration/test_journal_input_sup.nim",
    "tests/integration/test_supervisor_onerror.nim",
    "tests/integration/test_supervisor_restart.nim",
    "tests/integration/test_supervisor_strategies.nim",
    "tests/integration/test_supervisor_pools.nim",
    "tests/integration/test_animation.nim",
    "tests/integration/test_persist.nim",
    "tests/integration/test_timewarp.nim",
    "tests/integration/test_topology.nim",
  ]
  for t in unitTests & integrationTests:
    exec "nim r --hints:off --warnings:off --path:src " & t

task examples, "compile-check every examples/*.nim":
  let examples = @[
    "examples/ex01_input_loop.nim",
    "examples/ex02_devtools.nim",
  ]
  for e in examples:
    exec "nim check --hints:off --warnings:off --path:src " & e
