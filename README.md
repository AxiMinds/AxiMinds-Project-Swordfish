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
