# Changelog

All notable changes to **AxiMinds Project Swordfish** (axicore / axiNC) are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).  
Versioning: [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

## [0.2.0] — 2026-07-22

Live FFN consumer + full GGUF forward (beyond weight probe) + llama.cpp Qwen3.5-0.8B Q4_K_M verification.

### Added

- **`src/models/forward.zig`**: in-process F32 embd→logits→tokens (`status=forward_ok`); external full transformer via zllama / `llama-completion`.
- **`src/bridge/ffn_consumer.zig`**: live C ABI FFN host path; dual-run consistency tests.
- CLI modes: `ffn-consumer`, `gguf-forward`, `live-demo` (`src/main.zig`).
- Project **`logs/`** operational transcripts + plain-language `logs/AXINC-TEST-RESULTS.md`.
- `scripts/verify_live_axinc.sh` re-verify harness.

### Changed

- `ModelHost.infer(.gguf)` and `axinc_model_infer` return **forward** results (not probe-only).
- Weight probe retained as register-time diagnostics only.

### Verified

- 45/45 unit tests; dual FFN runs (cycles=7); Qwen3.5-0.8B Q4_K_M via llama.cpp; optional `http://127.0.0.1:18081`.

## [0.1.0] — 2026-07-22

First tagged **MVP** release: offline-complete neural computer with agent loop, C ABI, and honest secondary-model paths.

### Added

- **Agent loop** (`src/agent/loop.zig`): Ollama/Qwen → extract fenced `axiasm` → assemble → NC execute → stats feedback; `--mock` offline path.
- **Ollama client** (`src/bridge/ollama_client.zig`): `/api/chat` + `/api/generate` via curl; default endpoint `http://127.0.0.1:11534`.
- **ModelHost** (`src/models/host.zig`): secondary slots for Ollama and GGUF; GGUF **weight probe** (F32 sum + fingerprint, `status=weight_probe_ok`).
- **C ABI** (`src/bridge_lib.zig` → `libaxinc.a` / `libaxinc.so`): `axinc_init`, `axinc_ffn_tap`, `axinc_load_program`, `axinc_load_axiasm`, `axinc_get_stats_json`, `axinc_model_register`, `axinc_model_infer`, `axinc_shutdown`.
- **Fixture** `src/models/fixtures/tiny.gguf` (32×F32, sum=512) for deterministic GGUF tests.
- **axiASM** full textual assembler + `std.zig.Ast` expression lowerer (`src/asm/`).
- **5-level Tricache** L1–L5 (disk L4 `.axl4`, sharded L5 JSON-LD + KGDB side-effects).
- **Pre-FFN hooks** + memoizedMul; SPZA/MEP/INT1/ShiftAdd primitives in core.
- Docs: `docs/SOURCES-GH.md` (org port provenance), agent/bridge usage in README.

### Fixed

- Zig **0.16** build surface: `addLibrary` + modules, `ArrayList .empty`, `callconv(.c)`, `process.Init` / `process.run`+Io, DebugAllocator.
- 5L test isolation (L5 shard wipe) so mixed-volume hit rates stay ≥95%.
- Skeptic gaps: real GGUF weight probe (not metadata-only); mock agent drives real secondary; `axinc_model_infer` success tests; Ollama test inject.

### Deferred (post-0.1)

- Full in-process GGUF **transformer forward** (zllama `Transformer`).
- Live llama.cpp / SGLang FFN consumer on `axinc_ffn_tap`.
- Production KGDB decay e^(-λt), CUDA backends, multi-Ollama pool.

### Verify

```bash
zig build && zig build test
zig build run -- agent --mock --ticks 2
# expect: weight_probe_ok sum=512, axiASM R3=30
```

## Earlier (untagged foundation)

Pre-tag work on `master` includes Phase-1 core (ISA, engine, ALU, KGDB substrate, metrics, demo-ocean, verify scripts) and repeated skeptic hardening of 5L hit-rate proofs. See git history before `v0.1.0`.

[0.2.0]: https://github.com/AxiMinds/AxiMinds-Project-Swordfish/releases/tag/v0.2.0
[0.1.0]: https://github.com/AxiMinds/AxiMinds-Project-Swordfish/releases/tag/v0.1.0
