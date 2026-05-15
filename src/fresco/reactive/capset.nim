## Compile-time capability sets via `static[uint64]` bitmap (#35 C1).
##
## # Encoding choice
##
## A capability set is a `uint64`, with each bit position representing
## one `CapKind` enum value. The set is carried as a `static[uint64]`
## generic parameter on `StaticSupervisor` and friends.
##
## **Why uint64 and not `set[CapKind]`?** The cleaner-looking
## `Supervisor[Caps: static[set[CapKind]]]` *should* give type
## identity by set-value (since bitsets compare structurally), and
## the Nim language reference suggests `static[T]` parameters share
## instantiation by value. **In practice, Nim 2.x's generic
## instantiation cache does NOT share `static[set[X]]` instantiations
## by value** — `Phantom[{ckA, ckB}]` and `Phantom[{ckB, ckA}]` are
## treated as different types even though the bitset values are
## identical. The same test with `static[uint64]` *does* share
## (verified by `tests/unit/test_capset.nim`). So we pay one
## indirection — encode the set as a uint64 — to get type identity
## by value.
##
## # User-facing API
##
## Users never see `CapSet` directly: the `{.requires.}` pragma and
## `staticSupervisor:` DSL take capability *types* (FsReadCap,
## NetworkCap, ...) and the macros convert to bitmasks at compile
## time. The bitmap representation is purely internal plumbing.
##
## # Closed universe
##
## `CapKind` is a fixed enum with 6 built-in caps and 58 reserved
## user slots — 64 total to fit a uint64. `registerCap` (a separate
## macro in capabilities.nim) allocates user slots on demand.
## Cross-module slot stability is tracked at #53.

type
  CapKind* = enum
    # Built-in capability kinds. Order is stable — bit positions are
    # part of the encoded set value; reordering would shift every
    # cap's bit and invalidate any persisted `CapSet` values.
    ckFsRead    ## read from local filesystem
    ckFsWrite   ## write to local filesystem
    ckProcess   ## spawn / exec OS processes
    ckNetwork   ## socket / DNS / HTTP
    ckTerminal  ## raw-mode TTY I/O
    ckStateMut  ## mutate reactive state
    # Reserved slots for user-defined capability types. 58 slots
    # so total CapKind cardinality is 64, fitting a uint64 bitmap.
    ckUser0,  ckUser1,  ckUser2,  ckUser3,  ckUser4,  ckUser5,  ckUser6,  ckUser7
    ckUser8,  ckUser9,  ckUser10, ckUser11, ckUser12, ckUser13, ckUser14, ckUser15
    ckUser16, ckUser17, ckUser18, ckUser19, ckUser20, ckUser21, ckUser22, ckUser23
    ckUser24, ckUser25, ckUser26, ckUser27, ckUser28, ckUser29, ckUser30, ckUser31
    ckUser32, ckUser33, ckUser34, ckUser35, ckUser36, ckUser37, ckUser38, ckUser39
    ckUser40, ckUser41, ckUser42, ckUser43, ckUser44, ckUser45, ckUser46, ckUser47
    ckUser48, ckUser49, ckUser50, ckUser51, ckUser52, ckUser53, ckUser54, ckUser55
    ckUser56, ckUser57

  CapSet* = uint64

const EmptyCaps* = 0'u64

func capBit*(k: CapKind): CapSet {.inline.} = 1'u64 shl ord(k)
  ## Bit-encoding of a single CapKind. Pure CT-evaluable.

func contains*(s: CapSet, k: CapKind): bool {.inline.} =
  (s and capBit(k)) != 0

func union*(a, b: CapSet): CapSet {.inline.} = a or b

func isSubsetOf*(a, b: CapSet): bool {.inline.} = (a and b) == a
  ## True when every cap in `a` is also in `b`.

func missing*(required, provided: CapSet): CapSet {.inline.} =
  ## Bits set in `required` but not in `provided` — the caps the
  ## discharge check would name as unsatisfied. Useful for error
  ## messages.
  required and not provided
