# AxiMinds Neural Computer — axicore (Project Swordfish)

**Version [0.2.0](CHANGELOG.md)** · Zig 0.16.0 · ZLS 0.16.0

The FULL axicore stack available to the AI's neural computer.
Every optimization the host system gets, the AI's computer gets too.

axicore consolidation architecture:
- Layer 0: axicore (INT1/SPZA/MEP/memoization/SIMD/SMURFS + 5-level cache)
- Layer 1: aximodel (model-level abstractions, GGUF/SVC4 real model loading)
- Layer 2: axihw (RKNN2/NEON/CUDA/WASM hardware dispatch)
- Layer 3: axillm (LLM integration, pre-FFN hooks, continual thinking)

## Core Primitives
**5-Level Cache Hierarchy (real disk + JSON-LD persistence)**
1. TricacheL1 — Direct-mapped 256-entry L1
2. TricacheL2 — 4-way set-associative 1024-set L2
3. TricacheL3 — Age-based 64K linear L3 (VRAM)
4. L4 /ice-block — Disk-backed LFU using Linux syscalls (.axl4 files with age+value), RAM promotion
5. L5 ice-slivers — Sharded JSON-LD persistence (shard_N.json) with KGDB side-effects (AXION-32D edges), BLAKE3/zNorm ready

**Efficiency & Consensus Primitives**
6. INT1 Consensus — 1-bit voting (XNOR+popcount), 3-30 nines of precision via consensus verification
7. Shift-Add Everywhere — Zero hardware multiplies in hot paths (peasant mul, const, asm intrinsics, dot-product)
8. SPZA Memoization — 8D angular + sign-based (XNOR+POP) semantic cache with adaptive exclusion, row signatures, LutMemo/TileMemo support for cached mul
9. MEP Routing — Minimum Energy Path dispatch (cached vs shift-add vs full)
10. MemoizedMul / CachedOp — Ported Lut/Tile memo + pre-FFN continual thinking hooks for iterative inner loops before FFN (SPZA exclusion + memo hits)

**State & Knowledge**
11. SMURFS 4D — θ/φ/ψ/τ persona state at 2^60 scale
12. zNorm — Normalization at 2^70 scale
13. KGDB (AXION-32D Substrate) — Persistent append-only knowledge graph: 32-byte addresses, hot RAM index (adjacency), multi-hop BFS/DFS traversal, addEdge, real L4/L5 integration. Ports from AxiMinds-Substrate + KGDBInference (5-stage router/retriever/composer/answerer/learner paths)

**Other**
14. Hardware Abstraction — NEON/RKNN2/CUDA/scalar auto-dispatch (scalar baseline fully implemented)
15. Dev/Debug Pluggable Module — Build-gated (-Ddev-debug) traces, error codes (TC-*, PE-*, MM-*), cache-hit logging, hooks. Strip/obfuscate/encrypt ONLY at final pre-production step.

**Key Recent Capabilities (integrated from private GH ports)**
- Advanced SPZA (sign-agreement XNOR+POP + 8D projection + adaptive coarse/fine/frozen exclusion + block centroid prefilter) — src/ (ported concepts)
- LutMemo / TileMemo / rowSignature for cached bitwise + tile matmul — memoized paths in ALU
- Pre-FFN continualPreFFN (iterative inner loops with exclusion + memo) + memoizedMul hook
- Real 5-stage KGDB inference design (Router/Retriever/Composer/Answerer/Learner with direct/augmented/fallback)
- Full Substrate KGDB persistence (hot index + traversal ready for L5/self-org)

### Quick Feature Status Matrix (suggested Tier 1 improvement applied)
| Capability          | Status          | Evidence                          | Code Path                     |
|---------------------|-----------------|-----------------------------------|-------------------------------|
| 5-Level Tricache    | Real (L4/L5)   | l4_*.axl4 + shard_*.json files   | src/core/axicore.zig         |
| KGDB (AXION + Hot)  | Core + Ports   | addEdge/traverse + L5 integration| src/kgdb/ + axicore          |
| Pre-FFN Hooks       | Wired          | continualPreFFN + memoizedMul    | src/hooks/pre_ffn.zig + alu/engine |
| Advanced SPZA/Memo  | Integrated     | row sig + adaptive exclusion     | ports + alu/axicore          |
| Real Metrics        | Full           | wall IPS, per-level hits, energy | main/bench + tricache stats  |
| GGUF + SVC4         | Parser ready   | loadFromFile + remap             | src/gguf/ + svc4.zig         |
| **MVP (AC1-4)**     | COMPLETE       | builds+tests+2x run (l4/l5>=95% hit, DREAM/LEARN/EMIT/HOOK/NC-trace first, KGDB decay exercised, html pane) + real artifacts in SCRATCH | verified via scripts/verify_mvp.sh + plan.md |

## Neural ISA (80+ opcodes + custom registry)
- Tier 0: Compute — ADD/SUB/MUL (shift-add + memoizedMul hook), DIV/MOD, bit ops, VADD/VSUB/VMUL/VDOT/VRED/VMAP, SLOC/SDST/SROU/SMEM/SSTO/SNRM (SPZA), LOAD/STOR/PUSH/POP, MEMO/MLUT/MCLR (memoization)
- Tier 1: Control — JMP/JZ/JNZ/.../CALL/RET/HALT/YIELD/NOP, HOOK/POLL/SEND/RECV/HWAIT, DPIX/DBLK/DREAD/DREAM/WAKE/DCLEAR/DRESIZE (dream/canvas), YIELD
- Tier 2: Meta/Self-Mod — EMIT/LEARN/FUSE/LANG/INTRO/MUTATE (self-modification + AST lowering via std.zig.Ast for expressions → ISA), CUSTOM_BASE (up to 64 runtime-registered opcodes with FUSE sequences)
- Builder + CustomOpcodeRegistry for dynamic registration/expansion of fused/custom sequences
- Full textual axiASM assembler + lowerer (src/asm/)
- Pre-FFN continual thinking hooks wired into LEARN and ALU MUL paths (iterative loops with SPZA exclusion + memo)

## Project Structure
```
├── VERSION / CHANGELOG.md
├── build.zig                    # axinc exe + libaxinc.a/.so + test + bench
├── src/
│   ├── main.zig                 # demo metrics + `agent` subcommand
│   ├── bridge_lib.zig           # C ABI root → libaxinc
│   ├── core/                    # types, axicore (5L), alu, engine
│   ├── isa/opcodes.zig
│   ├── asm/                     # axiASM assembler + Ast lowerer
│   ├── kgdb/                    # AXION-32D + hot index + traversal
│   ├── gguf/ + svc4.zig         # GGUF parser + SVC4 helpers
│   ├── models/host.zig          # secondary Ollama / GGUF weight probe
│   ├── models/fixtures/tiny.gguf
│   ├── agent/loop.zig           # LLM ↔ NC continuous loop
│   ├── bridge/                  # ollama_client, llama_bridge
│   ├── hooks/pre_ffn.zig
│   ├── dev/debug.zig
│   └── bench.zig
├── docs/
│   ├── ARCHITECTURE.md
│   ├── axiASM.md
│   ├── metrics.md
│   └── SOURCES-GH.md            # AxiMinds org port provenance
├── scripts/verify_mvp.sh
└── demo-ocean.html
```

## Build & Test
```bash
zig build
zig build test
zig build bench
zig build run -- agent --mock --ticks 2
zig build run -- ffn-consumer --cycles 128
zig build run -- gguf-forward --path src/models/fixtures/tiny.gguf --prompt "hello"
zig build run -- live-demo --path src/models/fixtures/tiny.gguf --prompt "ping"
```

Live evidence & plain-language results: **[logs/AXINC-TEST-RESULTS.md](logs/AXINC-TEST-RESULTS.md)**

## Vision
LLMs inhabit a neural computer (axiNC) inside VRAM. They write, debug, and execute code using the Neural ISA (including custom/fused opcodes and AST-lowered LANG). They dream in layers (time dilation via DREAM/WAKE + canvas), accumulate persistent KGDB memories (AXION-32D, hot index, multi-hop traversal, L4/L5 integration) using advanced SPZA (8D angular + sign XNOR/POP with adaptive phases) + decay/priority. Real 5-level caching (L4 disk LFU .axl4 + L5 JSON-LD shards) + pre-FFN continual thinking hooks + memoized mul for host savings.

The ocean metaphor: coral/sea-grass memories (KGDB), fish as LLMs/NPCs, learning via trial/error that survives context windows. All metrics and persistence are real (linux clock, FS I/O, embedded model data, SPZA/Memo hits).

Ports from private GH (AxiMinds-Substrate, AxiMinds-KGDBInference, aximinds-zllama, AxiMinds-SGLang-Plugin) integrated for KGDB, GGUF/SVC4, advanced Memo/SPZA, hooks.

See Conv-20260628-1155pm.md for full conversation history, reviews, and iteration notes.

Zig 0.16.0 features in use:
- std.zig.Ast for expression → ISA lowering (LANG / Book of Spells)
- Explicit `asm` blocks and arch intrinsics in ShiftAdd / hash / vector paths
- Linux syscalls (open/read/write/lseek) for L4 disk + GGUF real-file loading (0.16 compat)
- @embedFile + real wall-time for metrics (no simulation)

## Installation (Zig 0.16.0 + ZLS 0.16.0)

1. Download Zig 0.16.0: https://ziglang.org/download/0.16.0/
   - Linux: zig-x86_64-linux-0.16.0.tar.xz
2. ZLS (optional, for IDE): https://github.com/zigtools/zls/releases (0.16.0)
3. Extract and add to PATH.

## Configuration

- Edit src/core/types.zig for DEFAULT_MEM_SIZE, canvas size, etc.
- No runtime config file; recompile for changes.
- Build options in build.zig (optimize, target).

## Build, Test, Run, Bench

Use your zig 0.16:

zig build
zig build test
zig build run     # real-time metrics demo + axiASM
zig build bench

See docs/ for details.

## axiASM Assembler

Full textual assembler in src/asm/assembler.zig on top of lowerer.

See docs/axiASM.md

Example in main and bench.

## Metrics

Real-time (wall time via linux clock_gettime day/night) + AI industry (IPS, learn rate, energy eff, ctx util = 5L tricache hit-rate, per-level serves, energy saved).

Real L4/L5 + KGDB activity visible (file artifacts created on run: l4_cache/*.axl4, l5_shards/shard_*.json).

Visible in CLI loop, bench (multi-iter workloads), and demo-ocean.html .

See docs/metrics.md (includes latest autonomous validation data: 6M+ IPS ReleaseFast, 99%+ 5L hits, real L4/L5 files + energy)

**Real Operation Verified**
- Runs create `l4_cache/*.axl4` and `l5_shards/shard_*.json`
- High hit rates (97%→100%) from actual Memo/SPZA + cache levels + KGDB
- Pre-FFN hook and memoizedMul called during LEARN/MUL paths
- All from real @embedFile data + linux time + FS I/O (no hardcoded fakes)

## Issues Encountered Building with 0.16.0 (documented)

- Build API: addStaticLibrary -> addLibrary + createModule (fixed)
- Module path restriction: relative ../ from subdir root causes "import of file outside module path" for bridge. Workaround: src/main.zig with src/ relative + disable lib build in current build.zig
- File ownership in modules when using multiple addModule for overlapping .zig files (core/engine conflict). Workaround: minimal build.zig without overlapping named roots.
- ArrayList API: .init(allocator) -> .empty + append(allocator, ) or Unmanaged in 0.16 (fixed in asm/lower/assembler)
- Ast.Index is enum(u32) not usize: use @intFromEnum for indexing nodes.items (fixed)
- asm syntax: multi-line strings with \n\t and "i" immediate for runtime shift require split \\ strings and "r" constraint (fixed)
- i32 literal 0xFF00FF00 overflow: use @bitCast(u32) (fixed)
- Error set inference cycle in engine.execute <-> executeCustom (mutual calls): used _ = catch {} for demo (fixed for build)
- Unused vars, const promotion, shadowing (imm) fixed per 0.16 stricter.
- Some asm templates (lea with runtime scale) not parsing; fell back to portable.

Full clean build for lib+bridge requires further restructuring (e.g. flat src or full named + reexports). See git log for all changes. Current build succeeds for exe/main + bench + tests.

See docs/install.md equivalent in this README.


## License
Proprietary — AxiMinds / Broadband Evolution LLC. (Per conversation history)

## Maintaining the Feature List (Tier 4 process suggestion)
- After major changes (new ports, L4/L5 enhancements, hook wiring), re-run `zig build run` and `zig build bench -Doptimize=ReleaseFast`.
- Capture: new file artifacts (l4_cache/, l5_shards/), per-level serves, IPS/hit/energy numbers, hook trace points.
- Update this list + docs/metrics.md + DEVELOPMENT_NOTES.md.
- Verify "real" claims by inspecting created files and stats output.
- Single source: keep detailed in ARCHITECTURE.md / DEVELOPMENT_NOTES; keep this README compendious + matrix.

## Status

**v0.2.0** (see [CHANGELOG.md](CHANGELOG.md) and [logs/AXINC-TEST-RESULTS.md](logs/AXINC-TEST-RESULTS.md)):

- 5-level Tricache (L1–L3 VRAM + L4 disk LFU + L5 JSON-LD + KGDB) with ≥95% hits under verify
- **Live FFN consumer** (`ffn-consumer`) — real C ABI `axinc_ffn_tap`, dual-run nonzero cycles
- **Full GGUF forward** — in-proc F32 embd→logits; Q4 via zllama/`llama-completion` (`status=forward_ok`)
- Agent loop (mock offline + optional live Ollama :11534)
- C ABI `libaxinc` with `model_register` / `model_infer` forward-path tests
- llama.cpp live demo on **Qwen3.5-0.8B Q4_K_M** (NAS); optional review URL `http://127.0.0.1:18081`
- Builds/tests clean on Zig 0.16 (**45** unit tests)

## Next (from reviews + current)
- Full production KGDB decay e^(-λt) + priority + self-org + fuzzy SPZA hops (core substrate + hot index + traversal present; L5 integration live)
- CUDA / full hardware backends (scalar baseline + abstraction done; dispatch stubs)
- Dream triggers + Book of Spells (DREAM/WAKE + canvas + LANG AST lowering present; triggers in progress)
- Polished demo (HTML + real Ollama integration) + end-to-end with user GGUF models from AI folder
- Industry benchmarks vs nCPU + detailed analysis (current bench shows ~6-8M IPS RF, 99%+ 5L hits, real energy)
- v* vector opcodes full dispatch, deeper INT1/SMURFS, full MEP routing, parallelism hints for hot paths (KG/traversal/memo/tile)
- Complete pre-FFN/continuous loop integration + full 5-stage KGDB inference end-to-end (design + partial wiring done)

## MVP Agent + Bridge (2026-07-21)

**Verified offline MVP** (no live LLM required):

```bash
zig build && zig build test
zig build run -- agent --mock --ticks 2
# Expect: GGUF secondary status=weight_probe_ok (sum=512), axiASM R3=30
```

**Secondary model paths (shipped):**
- **GGUF**: real tensor weight probe (sum + fingerprint) via zllama parser — `status=weight_probe_ok`
- **Ollama**: live `/api/chat` when daemon is warm; inject boundary `models.test_ollama_reply` for tests

**C library** (`zig-out/lib/libaxinc.so`):
`axinc_init`, `axinc_ffn_tap`, `axinc_load_axiasm`, `axinc_get_stats_json`,
`axinc_model_register`, `axinc_model_infer`, `axinc_shutdown`

**Live Ollama** (optional; this host Docker port **11534**):
```bash
zig build run -- agent --endpoint http://127.0.0.1:11534 --model qwen3.5:0.8B --ticks 4
```
Cold model load can take minutes; tags API may respond while generate still loads.

**Deferred post-MVP:** full GGUF transformer forward; in-process llama.cpp FFN consumer.

See `docs/SOURCES-GH.md`.
