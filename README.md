# AxiMinds Neural Computer — axicore (Project Swordfish)

The FULL axicore stack available to the AI's neural computer.
Every optimization the host system gets, the AI's computer gets too.

axicore consolidation architecture:
- Layer 0: axicore (INT1/SPZA/MEP/memoization/SIMD/SMURFS)
- Layer 1: aximodel (model-level abstractions)
- Layer 2: axihw (RKNN2/NEON/CUDA/WASM hardware dispatch)
- Layer 3: axillm (LLM integration)

## Core Primitives
1. TricacheL1/L2/L3 — Three-tiered cache hierarchy
2. INT1 Consensus — 1-bit voting, 3-30 nines of precision
3. Shift-Add Everywhere — Zero hardware multiplies in hot paths
4. SPZA Memoization — 8D angular-indexed semantic cache
5. MEP Routing — Minimum Energy Path for compute dispatch
6. SMURFS 4D — θ/φ/ψ/τ at 2^60 scale persona state
7. zNorm — Normalization at 2^70 scale
8. Hardware Abstraction — NEON/RKNN2/CUDA/scalar auto-dispatch

## Neural ISA (80+ opcodes)
- Tier 0: Compute (ADD/SUB/MUL via shift-add, vectors, SPZA)
- Tier 1: Control (DREAM/WAKE, HOOK, YIELD)
- Tier 2: Meta (EMIT/LEARN/FUSE/LANG for self-modification and agency)

## Project Structure
```
├── src/
│   ├── core/
│   │   ├── types.zig
│   │   ├── axicore.zig
│   │   ├── alu.zig
│   │   └── engine.zig
│   ├── isa/
│   │   └── opcodes.zig
│   ├── bridge/
│   │   └── llama_bridge.zig
│   ├── gpu/
│   ├── hooks/
│   ├── dream/
│   └── bench.zig
├── docs/
│   └── ARCHITECTURE.md
├── build.zig
└── README.md
```

Zig 0.16.0 | ZLS 0.16.0

## Build & Test
zig build
zig build test
zig build bench

## Vision
LLMs inhabit a neural computer (axiNC) inside VRAM. They write, debug, and execute code using the Neural ISA. They dream in layers (time dilation), accumulate persistent KGDB memories using SPZA + decay/priority. The ocean metaphor: coral/sea-grass memories, fish as LLMs/NPCs, learning via trial/error that survives context windows.

See Conv-20260628-1155pm.md for full conversation history, reviews, and iteration notes.

Zig 0.16.0 features in use:
- std.zig.Ast for expression → ISA lowering (LANG / spells)
- Explicit `asm` blocks and arch intrinsics in ShiftAdd / hash / vector paths.

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

Real-time (wall time day/night) + AI industry (IPS, learn rate, energy eff, ctx util).

Visible in CLI loop and demo-ocean.html .

See docs/metrics.md

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

## Status
Phase 1 foundation implemented based on reviews and suggested improvements from the Conv log.
Fixes applied for pipeline consistency, PC safety, real metrics in demos (as applicable), etc.

## Next (from reviews)
- Full KGDB with decay e^(-λt) + priority + SPZA fuzzy hops
- CUDA / hardware backends
- Dream triggers + Book of Spells
- Polished demo (HTML + real Ollama integration)
- Benchmarks vs nCPU
