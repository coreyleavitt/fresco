# CLAUDE.md

This project follows the [AGENTS.md](AGENTS.md) convention. See that file for project conventions, coding standards, and what not to do.

For full architecture and locked decisions, see [DESIGN.md](DESIGN.md).

## Testing strategy

Three tiers, no quality eval at this stage:

| Tier | Targets | I/O | Frequency | Where |
|---|---|---|---|---|
| **1 — pure unit** | ANSI builder, key event decoder, region geometry — pure functions | none | every save | `tests/unit/test_*.nim` |
| **2 — integration** | real termios + PTY pair driving the input/render loop | local only | every commit | `tests/integration/test_*.nim` |
| **3 — live smoke** | hand-run examples in a real terminal (`examples/`) | terminal | manual, pre-release | `examples/` (not built yet) |

### Running tests locally

```
./dev test         # tiers 1 + 2
./dev check        # nim check
./dev build        # build the package + examples
```

### What NOT to do

- Don't add line-coverage gates.
- Don't write to stdout from library code; reserved for caller's piped output.
- Don't ship without crash-safe terminal restoration. The single worst defect class for this library is "left terminal in raw mode."
