## Compile-time capability sets via multi-word bitmap (#35 C1, #55).
##
## # Encoding
##
## A capability set is `distinct array[CapSetWords, uint64]` — a
## fixed-width bitmap where each `CapKind` enum value owns one bit.
## `CapSetWords = 2` gives 128 total bits (6 built-in caps +
## 122 user-claimable slots), up from the original 64-bit ceiling.
##
## The set is carried as a `static[CapSet]` generic parameter on
## `StaticSupervisor` and friends. Nim 2.x's generic instantiation
## cache shares `static[array[N, scalar]]` by value (empirically
## verified during #55), so `Supervisor[A or B]` and
## `Supervisor[B or A]` resolve to the same type — the same property
## that made the original `static[uint64]` encoding work, generalized
## to N words.
##
## # User-facing API
##
## Users never see `CapSet` directly: the `{.needs.}` pragma and
## `staticSupervisor:` DSL take capability *types* (FsReadCap,
## NetworkCap, ...) and the macros convert to bitmasks at compile
## time. The bitmap representation is purely internal plumbing.
##
## # Closed universe
##
## `CapKind` is a fixed enum with 6 built-in caps and 250 reserved
## user slots — 256 total to fit a four-uint64-word bitmap.
## `registerCap` (in `capabilities.nim`) allocates user slots on
## demand. Cross-module slot stability: `nextUserSlot` is a
## `{.compileTime.}` var shared across the compilation unit, so
## registerCap calls in any imported module advance the same counter.
## Stable within a build; across builds the slot a given type gets
## can differ if the import graph reorders, harmless because CapSet
## values are CT-only and not persisted.
##
## # Beyond 256: sparse encoding (filed but not implemented)
##
## If a consumer ever hits the 250-user-slot ceiling, the
## bitmap-with-larger-N path can keep extending (just bump
## `CapSetWords` and the `CapKind` enum). Past some point, sparse
## encoding becomes more attractive: `static[seq[uint32]]` of
## sorted cap-ids, canonicalized at construction. Empirically
## verified (Nim 2.x shares `static[seq[X]]` instantiations by
## value when the values are structurally equal — the research
## from #35 history flagged this as fragile, but our checks show
## it works for the simple canonical-sorted case).
##
## Trade-offs: sparse loses native bit ops (membership becomes a
## linear scan of the sorted seq); the wins are unbounded cap
## count and smaller per-instantiation memory footprint when most
## tasks need few caps. Not implemented — file a follow-up if a
## real consumer crosses the 250-cap threshold.

const CapSetWords* = 4
  ## Number of 64-bit words in a CapSet. Bumping this widens the cap
  ## universe by 64 slots per word. The CapKind enum below must be
  ## extended in lock-step (each user slot is one enum member).
  ## Current: 4 words × 64 = 256 bits = 6 built-in + 250 user slots.

type
  CapKind* = enum
    # Built-in capability kinds. Order is stable — bit positions are
    # part of the encoded set value; reordering would shift every
    # cap's bit and invalidate any persisted `CapSet` values.
    # (Note: CapSets aren't currently persisted anywhere, but the
    # stability constraint costs nothing and future-proofs the
    # contract.)
    ckFsRead    ## read from local filesystem
    ckFsWrite   ## write to local filesystem
    ckProcess   ## spawn / exec OS processes
    ckNetwork   ## socket / DNS / HTTP
    ckTerminal  ## raw-mode TTY I/O
    ckStateMut  ## mutate reactive state
    # Reserved slots for user-defined capability types. 250 slots,
    # filling out the 256-bit bitmap (CapSetWords * 64 - 6).
    ckUser0,   ckUser1,   ckUser2,   ckUser3,   ckUser4,   ckUser5,   ckUser6,   ckUser7
    ckUser8,   ckUser9,   ckUser10,  ckUser11,  ckUser12,  ckUser13,  ckUser14,  ckUser15
    ckUser16,  ckUser17,  ckUser18,  ckUser19,  ckUser20,  ckUser21,  ckUser22,  ckUser23
    ckUser24,  ckUser25,  ckUser26,  ckUser27,  ckUser28,  ckUser29,  ckUser30,  ckUser31
    ckUser32,  ckUser33,  ckUser34,  ckUser35,  ckUser36,  ckUser37,  ckUser38,  ckUser39
    ckUser40,  ckUser41,  ckUser42,  ckUser43,  ckUser44,  ckUser45,  ckUser46,  ckUser47
    ckUser48,  ckUser49,  ckUser50,  ckUser51,  ckUser52,  ckUser53,  ckUser54,  ckUser55
    ckUser56,  ckUser57,  ckUser58,  ckUser59,  ckUser60,  ckUser61,  ckUser62,  ckUser63
    ckUser64,  ckUser65,  ckUser66,  ckUser67,  ckUser68,  ckUser69,  ckUser70,  ckUser71
    ckUser72,  ckUser73,  ckUser74,  ckUser75,  ckUser76,  ckUser77,  ckUser78,  ckUser79
    ckUser80,  ckUser81,  ckUser82,  ckUser83,  ckUser84,  ckUser85,  ckUser86,  ckUser87
    ckUser88,  ckUser89,  ckUser90,  ckUser91,  ckUser92,  ckUser93,  ckUser94,  ckUser95
    ckUser96,  ckUser97,  ckUser98,  ckUser99,  ckUser100, ckUser101, ckUser102, ckUser103
    ckUser104, ckUser105, ckUser106, ckUser107, ckUser108, ckUser109, ckUser110, ckUser111
    ckUser112, ckUser113, ckUser114, ckUser115, ckUser116, ckUser117, ckUser118, ckUser119
    ckUser120, ckUser121, ckUser122, ckUser123, ckUser124, ckUser125, ckUser126, ckUser127
    ckUser128, ckUser129, ckUser130, ckUser131, ckUser132, ckUser133, ckUser134, ckUser135
    ckUser136, ckUser137, ckUser138, ckUser139, ckUser140, ckUser141, ckUser142, ckUser143
    ckUser144, ckUser145, ckUser146, ckUser147, ckUser148, ckUser149, ckUser150, ckUser151
    ckUser152, ckUser153, ckUser154, ckUser155, ckUser156, ckUser157, ckUser158, ckUser159
    ckUser160, ckUser161, ckUser162, ckUser163, ckUser164, ckUser165, ckUser166, ckUser167
    ckUser168, ckUser169, ckUser170, ckUser171, ckUser172, ckUser173, ckUser174, ckUser175
    ckUser176, ckUser177, ckUser178, ckUser179, ckUser180, ckUser181, ckUser182, ckUser183
    ckUser184, ckUser185, ckUser186, ckUser187, ckUser188, ckUser189, ckUser190, ckUser191
    ckUser192, ckUser193, ckUser194, ckUser195, ckUser196, ckUser197, ckUser198, ckUser199
    ckUser200, ckUser201, ckUser202, ckUser203, ckUser204, ckUser205, ckUser206, ckUser207
    ckUser208, ckUser209, ckUser210, ckUser211, ckUser212, ckUser213, ckUser214, ckUser215
    ckUser216, ckUser217, ckUser218, ckUser219, ckUser220, ckUser221, ckUser222, ckUser223
    ckUser224, ckUser225, ckUser226, ckUser227, ckUser228, ckUser229, ckUser230, ckUser231
    ckUser232, ckUser233, ckUser234, ckUser235, ckUser236, ckUser237, ckUser238, ckUser239
    ckUser240, ckUser241, ckUser242, ckUser243, ckUser244, ckUser245, ckUser246, ckUser247
    ckUser248, ckUser249

  CapSet* = distinct array[CapSetWords, uint64]

const EmptyCaps*: CapSet = CapSet([0'u64, 0'u64, 0'u64, 0'u64])
  ## The empty capability set. Hand-construct rather than a default
  ## init so the literal flows cleanly through `static[CapSet]`
  ## parameters at macro emission sites. Length matches CapSetWords.

func words*(s: CapSet): array[CapSetWords, uint64] {.inline.} =
  ## Read-side unwrap. `distinct` keeps the outside API tight; the
  ## bit-ops internally need the array.
  array[CapSetWords, uint64](s)

func `==`*(a, b: CapSet): bool {.inline.} =
  ## Structural equality — required for `==` over `static[CapSet]`
  ## and for `isSubsetOf`'s `(a and b) == a` shortcut.
  array[CapSetWords, uint64](a) == array[CapSetWords, uint64](b)

func `or`*(a, b: CapSet): CapSet {.inline.} =
  ## Set union — bitwise OR per word.
  var w: array[CapSetWords, uint64]
  for i in 0 ..< CapSetWords:
    w[i] = a.words[i] or b.words[i]
  CapSet(w)

func `and`*(a, b: CapSet): CapSet {.inline.} =
  ## Set intersection — bitwise AND per word.
  var w: array[CapSetWords, uint64]
  for i in 0 ..< CapSetWords:
    w[i] = a.words[i] and b.words[i]
  CapSet(w)

func `not`*(s: CapSet): CapSet {.inline.} =
  ## Set complement — bitwise NOT per word. Used in `missing` to
  ## compute `required and not provided`.
  var w: array[CapSetWords, uint64]
  for i in 0 ..< CapSetWords:
    w[i] = not s.words[i]
  CapSet(w)

func capBit*(k: CapKind): CapSet {.inline.} =
  ## Bit-encoding of a single CapKind. The bit lives in word
  ## `ord(k) div 64` at position `ord(k) mod 64`. Pure
  ## compile-time-evaluable; used by every higher-level constructor.
  var w: array[CapSetWords, uint64]
  let idx = ord(k) div 64
  let bit = ord(k) mod 64
  w[idx] = 1'u64 shl bit
  CapSet(w)

func contains*(s: CapSet, k: CapKind): bool {.inline.} =
  let idx = ord(k) div 64
  let bit = ord(k) mod 64
  (s.words[idx] and (1'u64 shl bit)) != 0

func union*(a, b: CapSet): CapSet {.inline.} = a or b

func isSubsetOf*(a, b: CapSet): bool {.inline.} = (a and b) == a
  ## True when every cap in `a` is also in `b`.

func missing*(required, provided: CapSet): CapSet {.inline.} =
  ## Bits set in `required` but not in `provided` — the caps the
  ## discharge check would name as unsatisfied. Useful for error
  ## messages.
  required and (not provided)
