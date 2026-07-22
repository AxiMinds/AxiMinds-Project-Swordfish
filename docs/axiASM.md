# axiASM Textual Assembler

**Release:** v0.1.0 — used by demo, bench, agent loop (```axiasm blocks), and `axinc_load_axiasm`.

Full assembler for the AxiMinds Neural ISA, built on top of the `lower.zig` expression lowerer (using `std.zig.Ast` in Zig 0.16).

## Usage in code

```zig
const code = try assembler.assemble(allocator, 
    \\MOVI R1, 42
    \\MOVI R2, 10
    \\MUL R3, R1, R2
    \\LOWER R4 = R3 + 5
    \\DREAM 1000
    \\HALT
);
try engine.loadProgram(code);
```

## Syntax

- Opcodes: all from the ISA (ADD, MUL, DREAM, EMIT, LANG, etc.)
- Registers: R0-R31 (or r0)
- Immediates: 123 or 0x2A
- Labels: `loop: ` then `JMP loop`
- Comments: `; foo`
- High level on top of lowerer: `LOWER Rdst = R1 + R2 * 3`

See src/asm/assembler.zig for implementation and demo.

## Integration

Used in main demo and bench. The inner LLM can "emit" axiASM text via HOOK or memory for self modification.

## Limitations (0.16 port)

Label resolution for JMP is numeric; full symbol resolution is partial in current.

# Installation & Configuration

See README.md .
