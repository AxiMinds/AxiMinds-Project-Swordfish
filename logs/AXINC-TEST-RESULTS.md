# AxiNC live verification results (plain language)

**Date:** 2026-07-22  
**Project:** AxiMinds Project Swordfish (`axinc`)  
**Scope:** Live FFN consumer, full GGUF forward, compendious tests, llama.cpp + Qwen3.5-0.8B Q4_K_M demo

---

## What we set out to prove

1. A **live host** can call into axiNC during FFN-related work (`axinc_ffn_tap`) and get **nonzero cycles** plus readable stats.
2. Loading a **real GGUF** and running inference produces a **true forward result** (tokens/logits or generated text) — **not** only a weight fingerprint probe.
3. The **in-repo test suite** covers core NC, bridge FFN tap, and forward paths, and **passes**.
4. **llama.cpp** can run **Qwen3.5-0.8B Q4_K_M** from NAS; axiNC can run alongside and log interaction.
5. Write **honest logs** in this `logs/` folder (success, issues, how to re-run).

---

## Model & tools discovered

| Item | Path / value |
|------|----------------|
| Q4_K_M GGUF (used) | `/NAS1/homes/jdare/AI/AxiMinds-Inference/docker/models/gguf/unsloth_Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q4_K_M.gguf` (508 MiB) |
| Q4_0 fallback (available, not needed) | `/NAS1/homes/jdare/AI/AxiMinds-Inference/llama.cpp/models/Qwen3.5-0.8B-Q4_0.gguf` |
| llama tools | Homebrew llama.cpp **b8070**: `llama-completion`, `llama-server`, `llama-cli` |
| zllama (full Zig transformer binary) | `/NAS1/homes/jdare/AI/development/AxiMinds-zllama/zig-out/bin/zllama` |
| Fixture for unit tests | `src/models/fixtures/tiny.gguf` (32×F32 embd) |

Evidence: `logs/model-discovery.log`

---

## Results summary

| Check | Outcome | Evidence |
|-------|---------|----------|
| `zig build test` | **PASS** — **45/45** tests | `logs/axinc-test.log` |
| Live FFN consumer (dual run) | **PASS** — both runs `cycles_ran=7`, same stats | `logs/ffn-consumer.log` |
| In-process GGUF forward (fixture) | **PASS** — `status=forward_ok`, logits + generated tokens | `logs/gguf-forward.log` |
| llama.cpp Qwen Q4_K_M generation | **PASS** — non-empty coherent sentence | `logs/llama-qwen-demo.log` |
| FFN before/after llama generation | **PASS** — cycles=7 both sides | `logs/axinc-live-interaction-qwen.log` |
| Live demo (FFN + GGUF register/infer) | **PASS** — models=1, forward_ok | `logs/axinc-live-interaction.log` |
| llama-server HTTP review URL | **PASS** — health ok; chat API responds | `logs/llama-server-url.txt`, `logs/llama-server-completion.json` |

---

## What each piece means (plain language)

### Live FFN consumer

axiNC now exposes a **CLI host path** that uses the **real C ABI** (not a fake):

```bash
zig build run -- ffn-consumer --cycles 128
```

It initializes the machine, loads a short axiASM program, calls `axinc_ffn_tap`, and prints JSON stats.  
**Success:** both dual runs executed **7 cycles** with consistent stats (`hit_rate=1.0`, energy_saved=3). Zero-cycle failure would have aborted.

### Full GGUF forward (beyond weight probe)

Shipped path `ModelHost.infer(.gguf)` and `forward.forwardAuto`:

1. **Small F32 GGUF** (fixture): in-process **embedding → mean-pool → tied-weight matmul logits → greedy tokens**. Status line is **`status=forward_ok`** (probe fields still printed as diagnostics only).
2. **Large quantized GGUF** (Q4_K_M): external full transformer via **zllama** or **llama-completion** (llama.cpp).

CLI:

```bash
zig build run -- gguf-forward --path src/models/fixtures/tiny.gguf --prompt "hello" --max-tokens 6
zig build run -- live-demo --path <model.gguf> --prompt "..." --cycles 64
```

### llama.cpp + Qwen3.5-0.8B Q4_K_M

Non-interactive generation (v8070 prefers `llama-completion` over interactive `llama-cli` chat):

```bash
llama-completion -m /NAS1/.../Qwen3.5-0.8B-Q4_K_M.gguf \
  -p "In one short sentence, what is a neural computer?" \
  -n 32 --temp 0.2 -ngl 0 -t 4 -c 512 --no-warmup
```

**Sample generation (success):**  
> “A neural computer is a type of artificial intelligence that uses computers to process information like human brains.”

Load ~10–11 s from NAS mmap; ~4 tok/s eval on CPU (no GPU in this brew build).

### Review URL (localhost)

`llama-server` was started on:

**http://127.0.0.1:18081**

- Health: `{"status":"ok"}` after model load  
- OpenAI-compatible chat: `POST /v1/chat/completions`  
- Web UI (if enabled by build): `http://127.0.0.1:18081/`  

Note: port **18080** was already occupied by another AxiMinds mock service (`mock-canvas-model`), so this demo used **18081**.

Server may stop when the session ends; re-start with:

```bash
llama-server -m /NAS1/homes/jdare/AI/AxiMinds-Inference/docker/models/gguf/unsloth_Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q4_K_M.gguf \
  --host 127.0.0.1 --port 18081 -ngl 0 -c 1024
```

There is **no public internet URL** for this demo (localhost only), by design.

---

## Successes

- Real C ABI FFN tap exercised outside unit tests only, dual-run consistent.
- Forward path no longer ends at `weight_probe_ok`; tests require `status=forward_ok`.
- 45 unit tests green including dual-run FFN consumer and forward logits.
- Qwen3.5-0.8B Q4_K_M generates coherent text via llama.cpp on NAS weights.
- Interaction pattern: FFN → llama generate → FFN, all logged.
- Durable proof under `logs/` (project folder).

## Errors / issues (honest)

| Issue | Severity | Notes |
|-------|----------|--------|
| `llama-cli` interactive chat default | Low | v8070 says use `llama-completion` for non-interactive; first attempt hung in chat UI |
| No GPU in homebrew llama.cpp | Info | CPU-only; slower tokens/s; `-ngl 0` expected |
| Port 18080 busy | Info | Used 18081 instead |
| Qwen “thinking” chat template | Info | Server completions may put draft text in `reasoning_content`; still proves live HTTP path |
| Full in-process Zig transformer for 0.8B Q4 | Deferred | 3k-line zllama `transformer.zig` not vendored; full quant decode uses **llama.cpp/zllama binaries** as the production transformer engine. In-process F32 embd path is shipped and unit-tested. |
| zig build test “failed command” line | Cosmetic | Zig 0.16 listener noise when tests print to stdout; summary still **45/45 passed** |

## Residual / next (not blockers)

- Link pre-FFN-patched llama.cpp so FFN tap is called *inside* each FFN layer (process-level interleaving is live today).
- Optional: vendor or module-import zllama Transformer for pure in-process Q4_K.
- Smaller default n_ctx on llama-completion to cut RAM (demo used -c 512/1024 successfully).

---

## How to re-verify

```bash
cd /home/idare/dev/AxiMinds-Project-Swordfish
export PATH="/tmp/zig-x86_64-linux-0.16.0:/home/linuxbrew/.linuxbrew/bin:$PATH"

zig build && zig build test --summary all
zig build run -- ffn-consumer --cycles 128   # run twice
zig build run -- gguf-forward --path src/models/fixtures/tiny.gguf --prompt "hello" -n 4
zig build run -- live-demo --path src/models/fixtures/tiny.gguf --prompt "ping" --cycles 64

MODEL=/NAS1/homes/jdare/AI/AxiMinds-Inference/docker/models/gguf/unsloth_Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q4_K_M.gguf
llama-completion -m "$MODEL" -p "Hello" -n 16 -ngl 0 -t 4 -c 512 --no-warmup
```

Or: `scripts/verify_live_axinc.sh` (if present).

---

## Code map (what shipped)

| Path | Role |
|------|------|
| `src/models/forward.zig` | In-proc F32 forward + external zllama/llama-completion |
| `src/models/host.zig` | `infer(.gguf)` → full forward (not probe-only) |
| `src/bridge/ffn_consumer.zig` | Live C ABI FFN consumer + dual-run tests |
| `src/bridge_lib.zig` | C ABI + forward-path model_infer test |
| `src/main.zig` | `ffn-consumer`, `gguf-forward`, `live-demo` modes |
