# Package metadata for fresco — see DESIGN.md for architecture.

version       = "0.1.0"
author        = "Corey Leavitt"
description   = "Terminal-UI kernel: raw-mode input + region-based rendering + reactive task system."
license       = "Apache-2.0"
srcDir        = "src"

# Library only — no `bin` line. Callers depend on `fresco` and import
# from `fresco/...` paths.

requires "nim >= 2.0.0"

# All other deps (intonaco substrate + chronos async runtime + chronos's
# named transitives) are managed by milpa — see milpa.kdl. milpa fetches
# them into _deps/, emits nim.cfg with the right --path: lines, and
# generates milpa.lock with cryptographic pins (sha + content_hash).
#
# nimble v0.22.2's vnext SAT solver cannot resolve chained URL requires
# (fresco → intonaco URL + intonaco → chronos URL) — that's the bug
# that motivated milpa. With milpa managing URL deps + chronos's named
# transitives, fresco.nimble only declares `nim >= 2.0.0` and nimble's
# resolver has nothing to choke on.

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
    "tests/unit/test_screen_v2.nim",
    "tests/unit/test_layout.nim",
    "tests/unit/test_reactive.nim",
    "tests/unit/test_binding.nim",
    "tests/unit/test_render_target.nim",
    "tests/unit/test_layout_sink.nim",
    "tests/unit/test_synthetic_input.nim",
    "tests/unit/test_run_headless.nim",
    "tests/unit/test_terminal_sink.nim",
    "tests/unit/test_context.nim",
    "tests/unit/test_dsl.nim",
    "tests/unit/test_aggregate_import.nim",
    "tests/unit/test_journal.nim",
    "tests/unit/test_speculative.nim",
    "tests/unit/test_speculative_reentrancy.nim",
    "tests/unit/test_tracked.nim",
    "tests/unit/test_mailbox.nim",
    "tests/unit/test_receive_multi.nim",
    "tests/unit/test_bitemporal.nim",
    "tests/unit/test_journal_snapshots.nim",
    "tests/unit/test_collection.nim",
    "tests/unit/test_static_graph.nim",
    "tests/unit/test_capabilities.nim",
    "tests/unit/test_concurrency.nim",
    "tests/unit/test_capconcept.nim",
    "tests/unit/test_grant_inject.nim",
    "tests/unit/test_infer_caps.nim",
    "tests/unit/test_xmodule_caps.nim",
    "tests/unit/test_devtools.nim",
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
    "tests/integration/test_supervisor_bridge.nim",
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
    "tests/integration/test_devtools_panel.nim",
    "tests/integration/test_devtools_panel_memorysink.nim",
    "tests/integration/test_context_isolation.nim",
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

task strictcheck, "proof-of-discipline: row bindings over baked signals build under -d:intonacoStrict":
  # A strict misclassification (a binding wrongly falling to the runtime floor)
  # is a hard compile error, so this can't live in the runtime `test` loop.
  exec "nim check -d:intonacoStrict --hints:off --warnings:off --path:src " &
    "tests/strict_binding_probe.nim"
