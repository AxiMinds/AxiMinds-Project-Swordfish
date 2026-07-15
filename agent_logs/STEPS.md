# Trace Steps for AxiMinds-Project-Swordfish axicore

The trace follows the code from build to execution and metrics. Agents read source only (read_file, grep, etc.). Focus on syntax, logic, order of operations, wiring (imports, module deps), variables, constants, types, performance (e.g. scans, allocations), correctness of algorithms (SPZA angular, shift-add, cache, engine PC safety, lowering).

## Steps 1-6 (Group 1 window)
1. Build system, module creation, test/bench/run steps wiring (build.zig)
2. Main entry point, imports, allocator, MachineState/Engine init and program assembly (src/main.zig top half)
3. Core types: SPZA, RegisterFile, Flags, Memory layout, MemoTable, DreamCanvas, MachineState init/deinit (src/core/types.zig)
4. Axicore: TricacheL1/L2/L3 impl (lookup/store/hitRate), ShiftAdd (mulAsm, computeKey), MEP, AxicoreContext (src/core/axicore.zig)
5. ALU: cachedOp pipeline, add/sub/mul/div/mod/and/or, VectorAlu, tests (src/core/alu.zig)
6. ISA: Opcode enum, Instruction packed struct + encode/decode, Builder helpers, CustomOpcodeRegistry (src/isa/opcodes.zig)

## Steps 4-9 (Group 2, overlap 3 steps with Group 1)
4. (overlap) Axicore primitives as above
5. (overlap) ALU as above
6. (overlap) ISA as above
7. Assembler: line splitting, label collection, tokenize, parseReg, toUpper, LOWER pseudo handling, normal opcode parsing + second pass (src/asm/assembler.zig)
8. Lowerer: lowerExpression (wrap + Ast.parse), lowerNode for literals/idents/binops using std.zig.Ast nodeData/simpleVarDecl, asm intrinsics (src/asm/lower.zig)
9. Engine execution: executeTap while loop, fetch, execute switch (all op handlers), executeCustom, loadProgram, getStats, tests (src/core/engine.zig)

## Steps 7-12 (Group 3, overlap 3 steps with Group 2)
7. (overlap) Assembler as above
8. (overlap) Lowerer as above
9. (overlap) Engine as above
10. Main metrics loop, day/night, IPS/learn calc, sleep, asm_src programs (src/main.zig bottom)
11. Bench main: intrinsics, lower demo, program load, tap loop, final metrics reporting (src/bench.zig)
12. Bridge stub, remaining files (hooks/dream/gpu stubs), docs (ISSUES-0.16.md, README, ARCHITECTURE), test integration, overall concerns (src/bridge/llama_bridge.zig, docs/*, test blocks in files)

## Overlap Rule
Each subsequent group overlaps at least previous 3 steps for cross-verification of wiring and state between components.

Agents must cite exact FILE:LINE for every note.
