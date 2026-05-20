# RFC: terminal interaction — capability authority + modern terminal primitives

**Status**: Draft
**Author**: Corey Leavitt
**Supersedes**: #64 (the original "rich indicators" umbrella) and #59 (capability detection)
**Companion to**: `docs/rfc-intonaco-fresco-split.md` (depends on the split's `RenderTarget` interface), `docs/rfc-reactive-observability.md`

## Why an RFC and not a /tdd cycle

The original framing of #64 ("rich indicators: capability-detected truecolor + image protocols + animation") and #59 (capability detection layer) was a 5-bucket feature taxonomy. That taxonomy missed two architecturally significant unifications:

1. **Terminal capabilities and program capabilities are the same shape of problem.** intonaco's cap concept system already type-checks "what authority does this code have?" Terminal rendering capabilities ("can this terminal display sixel?") are the same structural pattern: a pre-known set of capability tokens, declared at startup, required by leaf code paths, granted by a wiring site, discharged at compile time. Building a parallel runtime-only capability system for terminal authority would duplicate machinery the substrate already provides.

2. **Modern terminal interaction is more than rich indicators.** Mouse, focus, hyperlinks, bracketed paste, OSC notifications, theme detection — these are the difference between "fresco feels like 1995" and "fresco feels like 2025." A standalone "capability detection" issue misses the broader scope: what does it take for fresco to feel like a modern terminal library?

This RFC reframes the work as a coherent program — *modern terminal interaction, unified with intonaco's capability substrate* — and lays out the phases to ship it.

## Premise

A modern terminal supports a substantially richer interaction surface than ANSI escape codes alone:

- **Color depth tiers** (8 / 16 / 256 / truecolor)
- **Inline graphics protocols** (sixel / kitty / iterm2)
- **Mouse with bounding-box hit testing**
- **Focus events** (terminal reports focus-in/out)
- **Hyperlinks via OSC 8** (clickable text)
- **Bracketed paste** (distinguish typed input from pasted content)
- **OSC notifications, title updates, bell**
- **System theme detection** (dark/light reported via OSC)
- **Unicode width** (East Asian Wide, emoji, combining marks)

Fresco today emits a baseline subset assuming generic ANSI. It has no detection layer, no concept of "what does this terminal support," no mouse, no focus, no hyperlinks, no theme awareness. Consumers writing polished UI hand-roll detection per-feature, get it 70% right, and ship inconsistent quality across the terminal matrix.

The unification thesis: **terminal capabilities ride through the same cap concept substrate as program capabilities.** Detection runs once at startup, populates the supervisor's grants, and render code declares its requirements via `{.needs.}` like every other capability-gated primitive. The fresco user never writes `if capabilities().sixel: ... else: ...`; they write a render call and the type system picks the right tier.

## Non-goals

- **Not Notcurses.** Notcurses is a feature-rich multimedia terminal library that ships its own substrate. fresco-via-intonaco's substrate is already chosen.
- **Not a font installer.** Nerd Font glyphs require user-side setup; that's deliberately out of scope. We support Nerd Font icons via an opt-in flag, but never depend on them.
- **Not a generic terminal library.** This RFC is fresco-specific terminal authority + interaction primitives, riding on intonaco. Other Nim terminal libraries can copy ideas; we're not abstracting for them.

## Layered model

```
┌──────────────────────────────────────────────────────────┐
│  LAYER 6: composed primitives (charts, complex widgets)  │
│  • donut / sparkline / bar / gauge / heatmap             │
│  • file preview / image gallery                          │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 5: tier-specialized render primitives             │
│  • image protocols (sixel/kitty/iterm2)                  │
│  • vector primitives (line/rect/circle/path)             │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 4: universal polish primitives                    │
│  • pill/badge helpers     • spinner/pulse/marquee        │
│  • iconography system     • OSC 8 hyperlinks             │
│  • bell / title / OSC     • system theme detection       │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 3: interaction primitives                         │
│  • mouse (move/click/drag/hover)                         │
│  • focus management (tab/shift-tab/focus events)         │
│  • bracketed paste                                       │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 2: Terminal abstraction                           │
│  • Terminal ref type — owns caps, IO, screen, termios    │
│  • Capability detection (DA queries, env shortcuts)      │
│  • Population of supervisor grants from caps             │
└──────────────────────────────────────────────────────────┘
                          ▲
┌──────────────────────────────────────────────────────────┐
│  LAYER 1: intonaco substrate                             │
│  • Cap concept system (concept satisfaction discharge)   │
│  • Supervisor (with cap grants in its object type)       │
│  • RenderTarget interface                                │
└──────────────────────────────────────────────────────────┘
```

Each upper layer depends on lower layers but not its siblings. Layer 5's image protocols don't know about Layer 4's pills; both consume Layer 2's cap-populated supervisor independently. Layer 6's charts compose across multiple lower layers.

## Layer 2: Terminal abstraction

A first-class `Terminal` ref type centralizes what's today scattered across `terminal/termios.nim`, `terminal/ansi.nim`, `screen.nim`, `input.nim`. It owns:

- Detected capability set (from startup detection)
- Input stream (cancel-safe via the #71 work)
- Current screen / overlay stack (for hot-toggle from the observability RFC)
- Termios state (cbreak / normal mode tracking)
- SIGWINCH handler installation
- Alt-screen state
- Escape emission primitives

```nim
type
  Terminal* = ref object
    caps*: TerminalCaps
    input*: InputStream
    screen*: Screen
    altScreen*: bool
    # ... internal state

proc openTerminal*(): Terminal {.async.}
  ## Run the startup dance: enter cbreak, install SIGWINCH, detect
  ## capabilities (DA queries + env shortcuts + overrides), open the
  ## input stream, allocate the initial screen. Returns a Terminal
  ## value the caller threads through their app.
proc close*(t: Terminal) {.async.}
  ## Reverse: leave alt-screen if entered, restore termios, close
  ## input stream, deregister SIGWINCH. Idempotent + crash-safe.
```

Capability detection populates `t.caps` once at startup. The detection mechanics are well-trodden but have real footguns:

- **Timeout selection**: parallel queries with deadline + early-completion-on-all-replies, not serial 50ms timeouts (ssh over high-latency links breaks the naive approach).
- **Race conditions with output**: alt-screen entered before any queries, so reply bytes don't interleave with app output.
- **DA reply parsing**: a robust parser for multi-segment replies; different terminals respond differently.
- **Kitty graphics query**: use `a=q` query-only mode to avoid the historical destructive-query problem.
- **Env-var shortcuts**: `$COLORTERM=truecolor` is the most reliable signal (95%+ of modern terminals set it). `$TERM` is unreliable post-2010. `$TERM_PROGRAM` works for some.
- **Override flags**: `FRESCO_FORCE_TRUECOLOR=0|1`, `FRESCO_FORCE_SIXEL=0|1`, etc., for misdetecting terminals or for testing degraded paths.

### Cap-substrate unification

This is the architectural payoff. Detected capabilities translate into intonaco-style cap tokens declared in fresco:

```nim
# In fresco/term/caps.nim:
cap TruecolorCap
cap Colors256Cap
cap SixelCap
cap KittyGraphicsCap
cap Iterm2ImagesCap
cap MouseCap
cap FocusCap
cap BracketedPasteCap
cap HyperlinkCap
cap OscNotificationCap
cap NerdFontIconsCap
cap UnicodeWideCap

# In fresco/term/terminal.nim, after detection:
proc buildSupervisor*(t: Terminal): auto =
  supervisor:
    # Standard caps the host app provides go here too...
    if t.caps.truecolor:        provides(TruecolorCap)
    if t.caps.colors256:        provides(Colors256Cap)
    if t.caps.sixel:            provides(SixelCap)
    if t.caps.kittyGraphics:    provides(KittyGraphicsCap)
    if t.caps.iterm2Images:     provides(Iterm2ImagesCap)
    if t.caps.mouse:            provides(MouseCap)
    if t.caps.focus:            provides(FocusCap)
    if t.caps.bracketedPaste:   provides(BracketedPasteCap)
    if t.caps.hyperlinks:       provides(HyperlinkCap)
    if t.caps.oscNotifications: provides(OscNotificationCap)
    if t.caps.nerdFontIcons:    provides(NerdFontIconsCap)
    if t.caps.unicodeWide:      provides(UnicodeWideCap)
    # children come from app code
```

A render primitive declares its required cap and gets tier-specialized at the supervisor type level:

```nim
proc renderDonut(sup: auto, data: Series) =
  when sup is GrantsKittyGraphicsCap:
    kittyDonutImpl(data, sup.kittyGraphicsGrant)
  elif sup is GrantsSixelCap:
    sixelDonutImpl(data, sup.sixelGrant)
  elif sup is GrantsTruecolorCap:
    blockUnicodeDonutImpl(data, sup.truecolorGrant)
  else:
    asciiDonutImpl(data)
```

This is the static-dispatch payoff. The capability check happens at compile time via concept satisfaction. The dead branches are eliminated. The consumer writes one call site; the type system picks the right impl.

### Why this is unification, not parallel system

The cap concept system in intonaco was specifically designed for "declare what's available once, type-check everywhere." Terminal authority fits the same shape exactly: capabilities declared at the wiring site (supervisor construction), consumed by leaf render code, statically discharged. Building a parallel `capabilities().sixel` runtime check would duplicate the substrate's mechanism for cosmetic reasons.

Counter-argument considered: terminal capabilities are runtime-detected (might change on re-detection across an ssh tunnel), while program caps are statically declared. Reply: detection is one runtime step; *after detection*, the caps are static for the session and behave identically to program caps. If the terminal changes mid-session (extremely rare), the right answer is a fresh supervisor construction, not a runtime capability mutation.

## Layer 3: interaction primitives

Mouse, focus, bracketed paste — the things that turn a TUI from "text I type at" to "an app I use."

### Mouse

Detection: query terminal mouse-protocol support (SGR mouse mode, modern terminals). Cap token: `MouseCap`.

Event capture: input stream parses SGR mouse sequences into `MouseEvent` values (pos, button, modifiers, kind = press/release/move/drag).

Hit testing: each `Region` exposes a bounding box. A global hit-test layer routes mouse events to the topmost region containing the cursor, with optional pass-through for transparent regions. Click handlers register via a `{.onClick.}` pragma or similar on bound widgets.

Hover state: synthetic enter/leave events when the cursor crosses region boundaries. Reactive — bound bindings can react to hover state via signals.

```nim
proc statusBadge(sup: auto, label: string) {.needs: TruecolorCap.} =
  let hovered = hoverSignal()
  bindRow region, 0:
    if hovered():
      emitPillBright(label)
    else:
      emitPill(label)
```

### Focus

`FocusCap` indicates the terminal reports focus-in/focus-out events. Combined with intonaco's reactive substrate, a `focused: Signal[bool]` is a binding-driven view of whether the terminal currently has OS-level focus.

Within fresco, tab navigation routes through a focus manager: widgets register as focusable; tab/shift-tab advances focus; focused widget gets keyboard input.

### Bracketed paste

`BracketedPasteCap` indicates the terminal wraps pasted content in `ESC [ 200 ~` / `ESC [ 201 ~`. Input stream parses these and emits `PasteEvent` instead of a stream of `KeyEvent`s — consumers can distinguish "user typed this" from "user pasted this."

Security and UX implication: pasted content shouldn't trigger hotkeys (avoids the "paste with embedded escape sequences exploits a hotkey" class of attack). Hotkey routing checks event kind and skips paste content.

## Layer 4: universal polish primitives

The "everyone benefits" tier. Each falls back gracefully on terminals that don't support the upper-tier rendering.

### Pill / badge helpers

```nim
proc pillBadge(sup: auto, label: string, color: Color)
```

- `GrantsTruecolorCap`: rounded background, full RGB color, padded label
- `GrantsColors256Cap`: rectangular background, 256-color approximation
- else: bracketed text, bold color from the 16-color palette

### Spinner / pulse / marquee

Built on intonaco's animation tween primitives. Mount-managed lifecycle (animation stops on scope dispose).

```nim
proc spinner(sup: auto, label: string): Mount
proc pulse(sup: auto, label: string, period: Duration): Mount
proc marquee(sup: auto, text: string, width: int): Mount
```

Tier-aware:
- `GrantsTruecolorCap`: smooth color transitions, sub-cell animation timing
- `GrantsColors256Cap`: stepped color rotation
- else: ASCII spinner glyph cycling

### Iconography system

Three-tier resolution per icon:

- `GrantsNerdFontIconsCap` (user opts in via `FRESCO_NERD_FONT=1`): Nerd Font glyph
- default: box-drawing / unicode block characters
- ASCII-only fallback (terminal limitation): plain text

```nim
proc icon(sup: auto, name: string): string
```

Icon names map to concrete glyphs per tier. A built-in catalog covers common UI icons (file, folder, check, x, arrow-right, spinner-frames, etc.). Consumers can extend with custom icons via a registration macro.

### Hyperlinks (OSC 8)

```nim
proc link(sup: auto, label: string, url: string)
```

- `GrantsHyperlinkCap`: emits OSC 8 sequence, terminal renders as clickable
- else: emits `label (url)` as plain text

### OSC notifications, title, bell

```nim
proc setTitle(t: Terminal, title: string)
proc notify(t: Terminal, msg: string)        # requires OscNotificationCap
proc bell(t: Terminal)                        # universal — always works
```

System-level integrations that modern terminals expose: notifications via OSC 9 / OSC 777, title updates via OSC 0, audible bell via BEL character.

### System theme detection

`GrantsThemeDetectionCap` (set when terminal supports OSC 10/11 query for foreground/background color) populates a reactive `colorScheme: Signal[ColorScheme]` (Dark / Light / Unknown). Apps auto-adapt:

```nim
let bg = colorScheme()
let style = case bg:
  of Dark:  darkPaletteFor("primary")
  of Light: lightPaletteFor("primary")
  of Unknown: defaultPaletteFor("primary")
```

The signal is reactive — if the user changes the system theme mid-session and the terminal re-emits the OSC report, fresco apps respond automatically.

## Layer 5: tier-specialized render primitives

### Image protocols

The biggest single LoC investment in this RFC. Three protocol encoders, each independent:

- **Sixel**: 24-bit RGB → terminal-specific palette quantization → DECSIXEL bytestream. Universal across most modern terminals (xterm, mlterm, wezterm, mintty, kitty in fallback mode).
- **Kitty graphics**: chunked image transfer with image IDs, persistent resource management. Native to kitty + wezterm. Use `a=q` query mode for capability detection.
- **iTerm2 inline images**: base64-encoded image data in OSC 1337 escape. iTerm2 + WezTerm.

Image decoding: stb_image via Nim wrapper, or a pure-Nim PNG decoder. Decoder is shared across protocols; encoders are protocol-specific.

```nim
proc image(sup: auto, path: string, cells: tuple[w, h: int])
```

Cell-grid alignment: images sized to integer cell counts; resampled to terminal cell dimensions; Z-ordered against text content; scroll/redraw handling per protocol.

### Vector primitives

Lower-level than image protocols. Line, rect, circle, polygon, path. Renders to whatever tier is available:

- `GrantsKittyGraphicsCap` / `GrantsSixelCap`: rasterized vector via internal raster engine
- `GrantsTruecolorCap`: approximated with quarter-block / Braille characters (popular for sparkline-style work)
- else: ASCII representation

```nim
proc line(sup: auto, target: RenderTarget, p1, p2: Point, color: Color)
proc rect(sup: auto, target: RenderTarget, area: Rect, color: Color)
proc circle(sup: auto, target: RenderTarget, center: Point, radius: int, color: Color)
proc path(sup: auto, target: RenderTarget, path: Path, color: Color)
```

This is the foundation for Layer 6's chart primitives — donut is a `circle` + `arc`, sparkline is `line` segments, gauge is `arc`, etc.

## Layer 6: composed primitives

Charts and complex widgets, composed across multiple lower layers.

```nim
proc donut(sup: auto, value: float, label: string)
proc sparkline(sup: auto, series: openArray[float])
proc bar(sup: auto, value: float, label: string)
proc gauge(sup: auto, value: float, min: float, max: float, label: string)
proc heatmap(sup: auto, grid: openArray[openArray[float]])
proc filePreview(sup: auto, path: string)         # image preview if image cap, else text
proc imageGallery(sup: auto, paths: openArray[string])
```

Each composes Layer 5 (vector / image) + Layer 4 (color via TruecolorCap) + Layer 3 (mouse-driven interaction if MouseCap) + Layer 2 (terminal abstraction). Each has tier-specialized impls and ASCII fallback.

Implementation note: chart-design is more *aesthetic* work than *engineering* work. Each chart type needs visual design decisions per tier (what does a donut look like at quarter-block fidelity? at sixel fidelity? in ASCII?). Expect this phase to be design-heavy, not code-heavy.

## Phasing

Six phases, each independently shippable. Bracketed numbers in parentheses are GitHub-issue references (#59-#63 plus new ones).

### Phase 1: Terminal abstraction + capability detection [#59, plus new Terminal abstraction issue]

- `Terminal` ref type centralizes IO, caps, screen, termios, SIGWINCH
- DA queries + env-var shortcuts + override flags
- Cap tokens declared (`TruecolorCap`, `Colors256Cap`, `SixelCap`, `KittyGraphicsCap`, `Iterm2ImagesCap`, `MouseCap`, `FocusCap`, `BracketedPasteCap`, `HyperlinkCap`, `OscNotificationCap`, `NerdFontIconsCap`, `UnicodeWideCap`, `ThemeDetectionCap`)
- `buildSupervisor` template populates grants from detection
- Override env vars work for testing degraded paths

Estimated ~500 LoC. Foundation for everything else.

### Phase 2: Universal polish primitives [#60, #63, plus new iconography, hyperlinks, OSC issues]

- `pillBadge` (tiered)
- `spinner`, `pulse`, `marquee` (tiered, Mount-managed)
- `icon` (three-tier resolution + catalog)
- `link` (OSC 8 conditional)
- `setTitle`, `notify`, `bell`
- System theme detection + reactive `colorScheme` signal

Estimated ~600 LoC.

### Phase 3: Interaction primitives [new mouse + focus + bracketed-paste issues]

- Mouse capture + parsing + hit-testing
- Hover state signals
- `{.onClick.}` / `{.onMouseEvent.}` pragmas on widgets
- Focus manager (tab/shift-tab routing)
- Bracketed paste parsing + `PasteEvent`

Estimated ~700 LoC. Biggest interaction-substrate addition.

### Phase 4: Image protocols [#61]

- Image decoder dependency choice (stb_image vs pure-Nim PNG)
- Sixel encoder
- Kitty graphics encoder
- iTerm2 inline encoder
- `image` primitive with cell-grid alignment

Estimated ~1500 LoC + dependency footprint. Largest single phase.

### Phase 5: Vector primitives [new vector-primitives issue]

- `line`, `rect`, `circle`, `polygon`, `path`
- Tiered rasterization (sixel/kitty for high fidelity, blocks for medium, ASCII for low)
- Foundation for charts

Estimated ~600 LoC.

### Phase 6: Chart primitives [#62]

- `donut`, `sparkline`, `bar`, `gauge`, `heatmap`
- `filePreview`, `imageGallery`
- Per-chart-per-tier aesthetic design

Estimated ~800 LoC. Design-heavy.

## Cross-cutting design decisions

### Color model

Single `Color` type representing RGB; conversion to nearest-256-color / nearest-16-color happens at the tier-specialized impl. Avoids the user thinking about which color space they're in.

```nim
type Color* = object
  r, g, b: uint8
```

Semantic color names map to RGB via a `Theme` context (provide/use): `theme.primary`, `theme.success`, `theme.error`, etc. Themes are reactive — the system-theme-detection signal feeds a `Theme` signal that consumers `use` from.

### Styling layer

No CSS-like text format. Themes + style records expressed in Nim:

```nim
type Style* = object
  fg, bg: Option[Color]
  bold, italic, underline: bool
  blink: bool        # rarely supported; never required

let primaryStyle = Style(fg: some(theme.primary), bold: true)
```

Style records compose: `style.with(bold = false)`. The styling layer is intonaco-side (signals + records) with terminal-emission helpers in fresco. Future frontends (web, headless) can reuse the same `Style` records with their own emission.

### Override surface

Every cap has a force-flag env var. Documented in the cap registration:

- `FRESCO_FORCE_TRUECOLOR=0|1`
- `FRESCO_FORCE_SIXEL=0|1`
- `FRESCO_FORCE_KITTY=0|1`
- `FRESCO_FORCE_MOUSE=0|1`
- `FRESCO_FORCE_NERD_FONT=0|1`
- etc.

Force-flag values override detection. Lets users on misdetecting terminals fix their experience, and lets developers test degraded paths during dev.

## Research artifacts

This RFC's contribution beyond engineering primitives:

### Theoretical contribution: capability substrate unification

Terminal authority and program authority unified into one compile-time-checked substrate. The paper-worthy claim: capability tokens as a structural concept are domain-agnostic; the same machinery that gates filesystem access can gate terminal feature access; the unification provides cleaner code, stronger static guarantees, and avoids the parallel-system anti-pattern that plagues most TUI libraries.

### Engineering primitives that follow

Listed throughout the phases — every primitive is consumer-facing, immediately usable without understanding the unification.

### Research artifact

A blog post documenting the unification thesis. Working title: *"One capability substrate, two domains: how intonaco's type system gates filesystem access and sixel rendering with the same primitive."* Could grow into a workshop paper at an FRP or PL venue.

## Migration plan

### Pre-split (Phase 0)

Land Phase 1 (terminal abstraction + caps) before the intonaco/fresco split is mechanically executed. The cap tokens are intonaco-substrate-shaped but declared in `src/fresco/term/caps.nim` for now.

### Post-split

After the split (per `docs/rfc-intonaco-fresco-split.md` Phase 3), the cap tokens stay in fresco (they're terminal-domain), and they consume intonaco's `cap T` macro to declare themselves. No re-design, just a package relocation.

### Existing #59-#63 issues

Each existing issue's body is updated with a reference to this RFC. The original 2-bucket framing is preserved as context; the phasing in this RFC is what drives implementation order.

## Open questions

### Q1: Image decoding dependency

stb_image (well-tested C, requires Nim wrapper) vs pure-Nim PNG decoder. Lean: stb_image for now; revisit if pure-Nim becomes a project goal.

### Q2: Mouse hit-testing performance

Naive impl iterates all bound widgets per event. For dense UIs (~1000+ widgets) this becomes the hot path. Open question: do we need a spatial-index structure (R-tree, quad-tree) from day 1, or land naive and optimize later?

Lean: naive first; add spatial index only when a real use case hits the wall.

### Q3: Focus manager scope

Single tab-cycle ring vs nested focus scopes (a modal dialog has its own focus ring that intercepts tab). Lean: nested from day 1; tab cycles within the topmost focused container.

### Q4: Vector primitives precision

Subcell precision (cells are 1×1 spatially but visually 1×2 due to aspect ratio) requires antialiasing-equivalent for block-character rendering. Real research: how to render a smooth diagonal line at quarter-block fidelity. Likely takes multiple iterations to get the aesthetic right.

### Q5: How does NerdFontIconsCap detection work?

Nerd Font detection is unreliable from the terminal side (terminal can't tell which font is loaded). Two options:
- **Opt-in only**: `FRESCO_NERD_FONT=1` env var; no automatic detection
- **Probe-based**: emit a Nerd Font glyph, query cursor position, deduce from advance width (hacky, breaks on terminals with broken cursor reporting)

Lean: opt-in only. Auto-detection is too brittle.

## Decision log

(Empty initially. Decisions made during implementation get appended.)
