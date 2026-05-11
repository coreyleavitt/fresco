# fresco/examples

Hand-run smoke programs. Each one exercises one v0 primitive and is
written to print obvious visual pass/fail cues. These don't run under
`./dev test` — they need a real terminal.

| File | Exercises | Pass cue |
|---|---|---|
| `ex01_input_loop.nim` | Raw-mode stdin → KeyEvent decoder | Every key you press prints its semantic name on the next line. Arrows, function keys, Ctrl/Alt combos, `/`, and ESC all decode correctly. Ctrl-C quits cleanly with the terminal restored. |
| `ex02_select.nim` | Select widget | Arrow keys / j-k / number keys all navigate; Enter picks; Ctrl-C and Esc cancel; `/` enters slash mode and typing + Enter returns the command. |
| `ex03_status_line.nim` | Status widget (DECSTBM scroll region) | 30 lines of `output line N` scroll past while the bottom row continuously updates `streaming N/30`. The status row never gets clobbered. |
| `ex04_permission_prompt.nim` | Composite: select-under-header | Looks like recall's permission prompt. Pick any option; outcome prints below. |

## Run

From the repo root, inside the dev container:

```
./dev shell
# then, inside:
nim r --hints:off --path:src examples/ex01_input_loop.nim
```

The examples write the UI to stderr and only print structured results to
stdout-after-cleanup, so you can pipe stdout safely if needed.

## Bailout

If an example leaves your terminal in a bad state (it shouldn't —
that's the whole point of `withCbreak` + signal hooks — but if it
does), `reset` or `stty sane` will recover it.
