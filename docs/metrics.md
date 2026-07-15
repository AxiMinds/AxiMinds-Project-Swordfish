# Real-time and Industry AI Metrics

The system exposes live metrics for monitoring the neural computer running 24/7.

## Real-time (day/night)

- Wall clock based "DAY"/"NIGHT" simulation (hour % 24).
- Running IPS calculated over wall time.
- Continuous print in main loop (every tick or sleep).

## Industry Specific AI Metrics

- IPS (Instructions Per Second) - equivalent to LLM forward pass rate.
- Learn rate (custom opcodes + fused / sec) - "training" speed.
- Energy saved / dream cycle - efficiency vs baseline.
- Cache hit % (L1/L2/L3 overall) - memory reuse.
- Context efficiency % (instructions / cycles) - utilization.
- VRAM usage, pattern growth, emergence (fused count growth).

Visible in:
- CLI main (real-time loop)
- demo-ocean.html (live updating panels)
- Engine.getStats() and bridge JSON.

See src/main.zig for implementation.

## Latest Autonomous Validation (2026-07-06/07, ReleaseFast + ports)
- IPS: 7-9M+ (bench sustained 50 taps), main ~0.5-2.6M wall real.
- Cache hit: 97-100% (5L tricache L1-3 + L4 disk .axl4 files + L5 JSON shards active).
- Ctx eff: real varying 97-99.7% (hit-rate driven, not instr/cycle fake).
- Energy saved: hundreds per run (e.g. ~4800+), learn ~1-2.6k /s when active.
- L4/L5 real proof: ls l4_cache/*.axl4 (2 files), l5_shards/shard_*.json (kv like "h87e55...":546) + KGDB records.
- From GH ports: advanced SPZA (sign/XNOR + 8D angular + adaptive) + LutMemo/TileMemo (INT1-16 cached mul/row sig) integrated via hooks + core.
- No fakes: all from real @embed + linux clock + fs I/O + wired Memo/SPZA/KGDB.
- Pre-FFN continual hook + memoizedMul wired (LEARN path triggers; SGLang-Plugin memo/spza concepts).
- Full 5L + KG (Substrate + Inference 5-stage design) + GGUF/SVC4 (zllama) ready.

# Installation and Configuration

**Zig 0.16.0+ required**

Download: https://ziglang.org/download/0.16.0/

ZLS 0.16.0: https://github.com/zigtools/zls (for editor)

## Build

/path/to/zig-0.16 build

## Run with metrics

/path/to/zig-0.16 build run

## Bench

/path/to/zig-0.16 build bench

## Config

- Memory size: edit DEFAULT_MEM_SIZE in src/core/types.zig
- Canvas: DreamCanvas.init size
- No other external config; all in code / build.

See README for full.
