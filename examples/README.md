# fresco/examples

Hand-run smoke programs. Each one exercises one v0 primitive and is
written to print obvious visual pass/fail cues. These don't run under
`./dev test` — they need a real terminal.

| File | Exercises | Pass cue |
|---|---|---|
| `ex01_input_loop.nim` | Raw-mode stdin → KeyEvent decoder | Every key you press prints its semantic name. Arrows, function keys, Ctrl/Alt combos, `/`, and ESC all decode correctly. Ctrl-C quits cleanly with the terminal restored. |
| `ex02_counter.nim` | End-to-end reactive loop — input → Signal write → region binding → render | A two-line panel shows `count: N`. Pressing `+`/`-` updates it in place (no scrollback churn). `q` or Ctrl-C quits with the terminal restored. Exercises the full kernel: cbreak + signal handlers, region render diff, Signal reactivity, `receive` pattern matching. |
| `ex03_devtools.nim` | Journal introspection while a supervisor runs two worker tasks | Watch ekTaskSpawned / ekSignalWrite / ekTaskCompleted / ekSupervisorTerminate events scroll past on stderr; final topology snapshot shows all children completed. Run without a TTY: `nim r --path:src examples/ex03_devtools.nim 2>&1 \| less`. |
| `altscreen_app.nim` | AltScreen surface — `acquireAltScreenGrant` → `withAltScreen` → `enter`/`leave` lifecycle + reactive clock counter | Your shell scrollback disappears on enter (?1049h) and is fully restored on exit (?1049l). The clock ticks in the live region. `q` or Ctrl-C restores the terminal on every exit path. |
| `inline_prompt.nim` | InlineScreen surface — `appendLine` + `commit` scrollback pipeline + `teardownFlush` teardown contract | Type a line and press Enter — the line scrolls into native terminal history above while the prompt stays pinned at the bottom. Press Shift-PgUp to confirm scrollback is intact. Ctrl-C/D quits cleanly. |

## Run

From the repo root, inside the dev container:

```
./dev shell
# then, inside:
nim r --hints:off --path:src examples/ex02_counter.nim
```

The examples write the UI to stderr and only print structured results to
stdout-after-cleanup, so you can pipe stdout safely if needed.

## Bailout

If an example leaves your terminal in a bad state (it shouldn't —
that's the whole point of `withCbreak` + signal hooks — but if it
does), `reset` or `stty sane` will recover it.
