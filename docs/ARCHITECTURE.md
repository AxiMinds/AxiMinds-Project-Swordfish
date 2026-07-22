# AxiMinds axicore Architecture

**Version:** see root `VERSION` / `CHANGELOG.md`.  
**Zig:** 0.16.0 | **ZLS:** 0.16.0

## Intent

Give the inner LLM a full native neural computer (**axiNC**) with the same savings layers as the host: 5-level cache, shift-add, INT1, SPZA memo, MEP, KGDB, pre-FFN hooks.

Ocean metaphor (coral/sea-grass = KGDB memories, fish = models/agents) and full design discussion: `Conv-20260628-1155pm.md`.

## Layers

| Layer | Name | Role |
|-------|------|------|
| 0 | axicore | INT1 / SPZA / MEP / memo / SIMD / SMURFS + Tricache L1–L5 |
| 1 | aximodel | GGUF/SVC4 load; ModelHost secondary (probe / Ollama) |
| 2 | axihw | NEON / RKNN2 / CUDA / WASM dispatch (scalar baseline shipped) |
| 3 | axillm | Agent loop, pre-FFN hooks, C ABI for external FFN consumers |

## Runtime components

```
Ollama/Qwen (optional) ──► agent/loop ──► axiASM assemble ──► engine.execute
                                │                                  │
                                ▼                                  ▼
                         ModelHost (GGUF probe / Ollama)     Tricache L1–L5 + KGDB
                                │
                         libaxinc.so C ABI (init / ffn_tap / model_infer / stats)
```

### Core (`src/core/`)

- **types** — memory defaults, canvas, shared enums.
- **axicore** — Tricache L1–L3 (VRAM), L4 disk LFU (`.axl4`), L5 JSON-LD shards + KGDB edges; INT1, ShiftAdd, MEP, SMURFS.
- **alu** — `cachedOp` pipeline, `memoizedMul` hook.
- **engine** — `executeTap`, self-mod (EMIT/LEARN/FUSE/LANG), hooks, stats.

### ISA & assembly

- **opcodes** — 80+ ops + CustomOpcodeRegistry (up to 64 runtime customs).
- **asm/assembler** — textual axiASM; **asm/lower** — `std.zig.Ast` expressions → ISA (`LOWER Rdst = …`).

### Persistence & knowledge

- **kgdb/** — AXION-32D addresses, append log, hot adjacency index, BFS/DFS traversal; L5 integration.
- L4/L5 artifacts appear under `l4_cache/`, `l5_shards/` on real runs.

### Models & bridge

- **gguf/** — real GGUF parser (zllama lineage); SVC4 remap helpers.
- **models/host** — register Ollama or GGUF path; GGUF path does **weight probe** (not full transformer decode in 0.1.0).
- **bridge/ollama_client** — host HTTP via curl.
- **bridge_lib** — C ABI root for `libaxinc`.

### Agent

- **agent/loop** — continuous tick: LLM reply → ````axiasm` / ````model` blocks → NC + secondary infer → feedback.
- CLI: `zig build run -- agent [--mock] [--endpoint URL] [--model NAME] [--ticks N]`.

## Zig 0.16 notes

- Build: `addLibrary` + `createModule`; single test module via main root.
- Collections: `ArrayList` `.empty` + allocator on mutators.
- Main: `process.Init` / `process.run` + Io where required.
- Ast: `Ast.Index` is `enum(u32)` — use `@intFromEnum` for node indexing.
- Hot paths: portable shift-add; limited `asm` where templates parse cleanly.

## MVP acceptance (0.1.0)

| Criterion | Status |
|-----------|--------|
| Build + unit tests | Pass |
| Offline agent mock | GGUF probe + axiASM (R3=30) |
| 5L hit rates in verify | ≥95% (isolated test + volume) |
| C ABI model_infer | Success path tested |
| Live Ollama | Optional (warm daemon on :11534) |
| Full GGUF forward | Deferred |

## Next

See README **Next** and CHANGELOG **Deferred**. Full conversation/reviews: `Conv-20260628-1155pm.md`, `DEVELOPMENT_NOTES.md`.
