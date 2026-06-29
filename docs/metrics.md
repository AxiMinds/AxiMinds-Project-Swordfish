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
