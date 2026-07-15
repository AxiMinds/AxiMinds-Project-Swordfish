# Debug Codebook for AxiMinds axicore

Non-descript error/trace codes for use with src/dev/debug.zig when dev-debug enabled.
These allow pinpointing issues (e.g. via logs or core dumps) without leaking sensitive IP in release builds.
Format: PREFIX-NNN (e.g. LM-409)
Use debug.log_error("CODE", "optional context or ptr");

When disabled (default build), no cost, no emission.

Cross-reference with source for flow: e.g. "LM-409" -> types.zig:xxx or engine flow step "memo-lookup".

## Codes

### Memory / Allocator (MA-)
- MA-001: page_allocator large upfront alloc (types.zig MachineState)
- MA-002: no arena for memos/canvas (performance bloat)
- MA-003: L3 alloc in TricacheL3
- MA-004: MemoTable entry alloc

### Tricache / Cache (TC-)
- TC-001: L1/L2/L3 lookup
- TC-002: L1/L2/L3 store/evict
- TC-003: cache hit in cachedOp (alu)
- TC-004: L3 linear scan warning (known issue)
- TC-005: 5-level extension (L4 disk, L5 shards) - not yet wired

### Memo / SPZA (MM-)
- MM-001: SPZA angularDistance / hash
- MM-002: MemoTable lookup / storeFused (critical, must wire to hot paths)
- MM-003: MemoEntry fused_op
- MM-004: SPZA not integrated in tricache path (cache hits may be incomplete without)

### Engine / Execute (EN-)
- EN-001: executeTap start
- EN-002: fetch
- EN-003: execute switch (opcode)
- EN-004: executeCustom / recurse
- EN-005: loadProgram
- EN-006: PC safety / clamp
- EN-007: dream mode
- EN-008: J* / imm9 u9 limit (0-511)
- EN-009: LANG hardcoded expr
- EN-010: error set (e.g. InvalidOpcode, DivByZero)

### ALU / Shift-Add (AL-)
- AL-001: cachedOp pipeline (add/sub/mul now full)
- AL-002: shift-add compute (mulAsm)
- AL-003: energy_saved_estimate update
- AL-004: VectorAlu (partial @Vector)
- AL-005: bypass for ADD/SUB (now routed for consistency)

### Assembler / Lower (AS-)
- AS-001: assemble tokenize / parse
- AS-002: LOWER expr
- AS-003: label resolution (stub improved for back/forward)
- AS-004: ident hash in lower (not live reg)
- AS-005: second pass

### Metrics / Real (MT-)
- MT-001: IPS calc (real time now)
- MT-002: learn_rate / fused
- MT-003: cache hit rate (from tricache)
- MT-004: energy
- MT-005: ctx_eff (now meaningful, not always 100%)
- MT-006: real file I/O for models (no fake/sim)

### Persistence / KGDB / 5-level (PE-)
- PE-001: L4 /ice-block on-disk LFU
- PE-002: L5 ice-slivers JSON-LD shards
- PE-003: BLAKE3 hash (use std.crypto if avail)
- PE-004: zNorm
- PE-005: JSON-LD KGDB (migrate from in-mem, isolated, self-org)
- PE-006: L4 RAM synced mirror
- PE-007: decay/priority in KGDB

### Wiring / Other (WI-)
- WI-001: endian/LE assumptions (make consistent with std.mem)
- WI-002: import/module path (0.16 fixes)
- WI-003: dead code / unused (imports, MEP.route, memoizedMul in paths)
- WI-004: parallelism (threads for hot paths?)
- WI-005: dev module bypass

## Usage Example in Code
```zig
const debug = @import("dev/debug.zig");
...
debug.log_error("EN-003", "before switch");
switch (op) { ... }
debug.log_cache_hit(1, key, true);
if (error) debug.log_error("LM-409", "in memo lookup");
```

## How to Use
- Build debug: zig build -Ddev-debug=true
- Release (no debug, stripable): zig build (default)
- For obfuscate/dist: build release, then strip symbols, encrypt bins. Debug code paths eliminated.
- Trace error LM-409: grep codebook + search source for "LM-409" or flow "memo".

Update this file as new codes added. Use in all components for full traceback without full stack (good for stripped binaries).

See agent logs / ISSUES for past errors that can be coded (e.g. from previous traces).
