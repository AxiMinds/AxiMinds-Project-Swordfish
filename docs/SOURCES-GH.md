# GitHub sources used for Swordfish implementations

Authenticated as **AxiMinds** (`gh`). Searched org repos 2026-07-21 for
Ollama, Qwen, agent loops, FFN hooks, GGUF, and axiNC-related code.

## Directly adapted into this tree

| Source repo | Path | Used for |
|-------------|------|----------|
| [AxiMinds-Claude-Remote](https://github.com/AxiMinds/AxiMinds-Claude-Remote) | `src/orchestrators/ollama.zig` | curl → `/api/generate` / chat pattern → `src/bridge/ollama_client.zig` |
| [AxiMinds-Claude-Remote](https://github.com/AxiMinds/AxiMinds-Claude-Remote) | `src/orchestrators/openai_compat.zig` | chat/completions JSON body + message roles |
| [AxiMinds-NoDev](https://github.com/AxiMinds/AxiMinds-NoDev) | `src/ollama/client.zig`, `injector.zig` | Config defaults (`host`/`port`/`model`), system prompt inject, high-level query API shape |
| [AxiMinds-Discovery](https://github.com/AxiMinds/AxiMinds-Discovery) | `explorer-ollama.sh` | Continuous multi-model Qwen roles, safety loop, standing work pattern |
| [AxiMinds-SGLang-Plugin](https://github.com/AxiMinds/AxiMinds-SGLang-Plugin) | `python/.../bridges/hooks.py`, `docs/HOOKS.md` | `LOOP_TICK` continuous lifecycle; pre-FFN / FFN memo design (partially already ported under `src/hooks/`) |
| [aximinds-zllama](https://github.com/AxiMinds/aximinds-zllama) | `src/lib.zig`, `src/gguf/*` | GGUF load + Qwen3 configs (already partially under `src/gguf/`) — next for “spawn second model” |
| [AxiMinds-Whisperer](https://github.com/AxiMinds/AxiMinds-Whisperer) | `src/llm/qwen35.zig` | Qwen3.5 GGUF metadata keys |
| [AxiMinds-SVC4-llama-cpp](https://github.com/AxiMinds/AxiMinds-SVC4-llama-cpp) | docs + patches | llama.cpp consumer SVC4 / Qwen footprint notes |
| [axi-stack](https://github.com/AxiMinds/axi-stack) | `engines/llama-gguf/patches/*preffn*` | Pre-FFN wire patterns for real FFN tap |
| [qwen3-coder-next](https://github.com/AxiMinds/qwen3-coder-next) | (unified inference) | Future dual Zig/Python backend for coder models |
| [AxiMinds-Qwen35-Megakernel](https://github.com/AxiMinds/AxiMinds-Qwen35-Megakernel) | CUDA megakernel | Future high-perf path, not wired yet |
| [AxiMinds-Project-Infini](https://github.com/AxiMinds/AxiMinds-Project-Infini) | `ollama/ollama_module.py` | Multi-persona Ollama orchestration reference |
| [AxiMinds-MCP-Inner-Monologue](https://github.com/AxiMinds/AxiMinds-MCP-Inner-Monologue) | `zig-mcp/src/ollama/pool.zig` | Connection pool design for multi-user Ollama |

## What is ready after this port

```bash
# Terminal A
ollama serve
ollama pull qwen3.5:0.8b   # or qwen3:8b / whatever you have

# Terminal B
cd /home/idare/dev/AxiMinds-Project-Swordfish
zig build run -- agent --model qwen3.5:0.8b --ticks 8
```

Loop: **Ollama(Qwen) → parse ```axiasm → assemble → NC execute → stats feedback → next tick**.

## Still not complete (need more ports)

1. Real in-process GGUF inference of a *second* model (use **aximinds-zllama** `Transformer` + loadWeightsFromGGUF).
2. llama.cpp / SGLang FFN tap calling `axinc_ffn_tap` (use **axi-stack** preffn patches + **SGLang-Plugin** hooks).
3. Full KGDB injection from **AxiMinds-Substrate** + **AxiMinds-KGDBInference**.
4. Ollama connection pool under load (**MCP-Inner-Monologue** pool.zig).

## Search commands used

```bash
gh auth status   # AxiMinds
gh repo list --limit 50
gh search code "ollama" --owner AxiMinds
gh search code "qwen" --owner AxiMinds
gh search code "axinc OR Tricache OR ffn_tap" --owner AxiMinds
```
