# AxiMinds axicore Architecture

See Conv-20260628-1155pm.md for complete conversation, reviews, suggested improvements and iteration history.

Core idea: Give the inner LLM (hosted in NN) a full native + optimized "computer" (axiNC) with same savings layers as host.

All details, ocean metaphor (sea grass = KGDB priority memories with decay), dream nesting, self modification, SPZA 8D indexing for semantic locality, etc. in the conv log.

Phase 1 (implemented): types + axicore primitives + ISA + ALU + Engine + bridge stub + tests.
Updated for Zig 0.16.0 + ZLS 0.16.0. Uses `std.zig.Ast` for expression lowering (LANG/Book of Spells support) + `asm` blocks + intrinsics in hot paths (ShiftAdd, hashes, bit ops).

Key fixes implemented from reviews:
* Consistent full pipeline where possible (cachedOp wrapper for MUL etc)
* Safe PC advance + bounds clamp in engine (prevent common VM bugs)
* Functional HOOK + DPIX/DBLK stubs + logging
* loadProgram dynamic
* Tricache L3 age improvements noted (future hashmap LRU)
* Demo truthiness concepts noted

Next per checklist: KGDB concrete + decay, CUDA, benchmarks, HTML real integration, 3-dream eval.
