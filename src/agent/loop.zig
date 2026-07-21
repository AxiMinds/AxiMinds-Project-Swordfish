// Continuous Qwen/Ollama + axiNC agent loop.
//
// SOURCES (AxiMinds GitHub patterns adapted into Swordfish):
//   - AxiMinds-Claude-Remote/src/orchestrators/ollama.zig  — local Ollama chat
//   - AxiMinds-NoDev/src/ollama/*                        — model defaults, system inject
//   - AxiMinds-Discovery/explorer-ollama.sh              — continuous multi-model work
//   - AxiMinds-SGLang-Plugin/.../bridges/hooks.py        — LOOP_TICK / continuous stages
//   - AxiMinds-Project-Swordfish asm/assembler + engine  — axiASM load & execute
//
// This is NOT yet "spawn a second GGUF and train it" — that needs zllama/SVC4
// wiring. It IS a working loop: Ollama (Qwen) → axiASM → NC execute → feedback.

const std = @import("std");
const core = @import("../core/types.zig");
const engine_mod = @import("../core/engine.zig");
const assembler = @import("../asm/assembler.zig");
const ollama = @import("../bridge/ollama_client.zig");

pub const AgentConfig = struct {
    ollama: ollama.Config = .{},
    /// Max agent ticks (0 = run until error / HALT policy)
    max_ticks: u32 = 8,
    /// Sleep between ticks (ms) for "throughout the day" pacing
    tick_sleep_ms: u64 = 500,
    /// Cycles per NC tap after loading program
    max_cycles_per_tap: u64 = 256,
    /// Standing instructions for continuous work
    standing_goal: []const u8 =
        \\You inhabit an AxiMinds Neural Computer (axiNC). Work continuously on the goal.
        \\When you want to run code on the NC, emit a fenced axiASM block:
        \\```axiasm
        \\MOVI R1, 10
        \\MOVI R2, 3
        \\MUL R3, R1, R2
        \\HALT
        \\```
        \\Use only documented opcodes (MOVI, ADD, SUB, MUL, DIV, JMP, JZ, JNZ, DREAM, WAKE, HALT, NOP, LEARN, FUSE, LANG, HOOK, DPIX, ...).
        \\After NC feedback, improve the program. Prefer small complete programs that HALT.
        \\If asked to prepare a second model, describe steps and emit axiASM that records metrics in registers;
        \\full GGUF spawn is not yet hooked — plan then refine NC programs.
    ,
};

pub const TickResult = struct {
    tick: u32,
    llm_ok: bool,
    llm_text: []const u8, // borrowed from caller-owned buffer or empty
    asm_found: bool,
    asm_ran: bool,
    cycles: u64,
    r3: i64,
    hit_rate: f32,
};

/// Extract first ```axiasm ... ``` or ```axiASM ... ``` block body (not owned).
pub fn extractAxiAsm(text: []const u8) ?[]const u8 {
    const needles = [_][]const u8{ "```axiasm", "```axiASM", "```axi-asm", "```AXIASM" };
    var start: ?usize = null;
    var open_len: usize = 0;
    for (needles) |n| {
        if (std.mem.indexOf(u8, text, n)) |i| {
            start = i;
            open_len = n.len;
            break;
        }
    }
    const s = start orelse return null;
    var body_start = s + open_len;
    // skip optional newline after fence
    if (body_start < text.len and (text[body_start] == '\n' or text[body_start] == '\r')) {
        body_start += 1;
        if (body_start < text.len and text[body_start - 1] == '\r' and text[body_start] == '\n') body_start += 1;
    }
    const rest = text[body_start..];
    const end_rel = std.mem.indexOf(u8, rest, "```") orelse return null;
    return std.mem.trim(u8, rest[0..end_rel], " \t\r\n");
}

pub fn runLoop(allocator: std.mem.Allocator, io: std.Io, cfg: AgentConfig) !void {
    std.debug.print("=== axiNC + Ollama agent loop ===\n", .{});
    std.debug.print("endpoint={s} model={s} max_ticks={d}\n", .{ cfg.ollama.endpoint, cfg.ollama.model, cfg.max_ticks });

    if (!ollama.isReachable(allocator, io, cfg.ollama)) {
        std.debug.print("ERROR: Ollama not reachable at {s}\n", .{cfg.ollama.endpoint});
        std.debug.print("Start with: ollama serve && ollama pull {s}\n", .{cfg.ollama.model});
        return error.OllamaUnreachable;
    }
    std.debug.print("Ollama reachable.\n", .{});

    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);

    var eng = try engine_mod.Engine.init(allocator, &state, .{
        .max_cycles_per_tap = cfg.max_cycles_per_tap,
        .trace_enabled = false,
    });
    defer eng.deinit();

    var feedback: []const u8 = try allocator.dupe(u8, "NC cold start. No program loaded yet. Emit a first axiASM program.");
    defer allocator.free(feedback);

    var tick: u32 = 0;
    while (tick < cfg.max_ticks) : (tick += 1) {
        std.debug.print("\n--- LOOP_TICK {d}/{d} ---\n", .{ tick + 1, cfg.max_ticks });

        const user_msg = try std.fmt.allocPrint(allocator,
            \\Standing goal:
            \\{s}
            \\
            \\NC feedback from last tick:
            \\{s}
            \\
            \\Respond with analysis and, when ready, one ```axiasm block to load+run.
        , .{ cfg.standing_goal, feedback });
        defer allocator.free(user_msg);

        const llm = try ollama.chat(allocator, io, cfg.ollama, user_msg, cfg.standing_goal);
        defer llm.deinit(allocator);

        if (!llm.ok) {
            std.debug.print("LLM error: {s}\n", .{llm.text});
            allocator.free(feedback);
            feedback = try std.fmt.allocPrint(allocator, "LLM error: {s}", .{llm.text});
            continue;
        }

        std.debug.print("LLM ({s}) response ({d} bytes):\n{s}\n", .{ llm.model_used, llm.text.len, llm.text[0..@min(llm.text.len, 800)] });
        if (llm.text.len > 800) std.debug.print("... [truncated]\n", .{});

        var cycles: u64 = 0;
        if (extractAxiAsm(llm.text)) |asm_src| {
            std.debug.print("Found axiASM ({d} bytes). Assembling...\n", .{asm_src.len});
            const prog = assembler.assemble(allocator, asm_src) catch |err| {
                allocator.free(feedback);
                feedback = try std.fmt.allocPrint(allocator, "Assemble error: {}. Fix the axiASM.", .{err});
                std.debug.print("{s}\n", .{feedback});
                continue;
            };
            defer allocator.free(prog);

            eng.loadProgram(prog) catch |err| {
                allocator.free(feedback);
                feedback = try std.fmt.allocPrint(allocator, "loadProgram error: {}", .{err});
                continue;
            };
            // reset halt so re-run works
            state.regs.flags.halted = false;
            state.running = true;

            cycles = eng.executeTap() catch |err| {
                allocator.free(feedback);
                feedback = try std.fmt.allocPrint(allocator, "executeTap error: {}", .{err});
                continue;
            };
            const stats = eng.getStats();
            const r3 = state.regs.getGP(3);
            std.debug.print("NC ran: cycles={d} R3={d} hit_rate={d:.2} dream={}\n", .{
                cycles, r3, stats.tricache_overall_hit_rate, stats.dream_mode,
            });

            allocator.free(feedback);
            feedback = try std.fmt.allocPrint(allocator,
                \\OK: assembled {d} instrs, ran {d} cycles. R1={d} R2={d} R3={d} R4={d}. hit_rate={d:.3} energy_saved={d} dream={}. Improve or extend the program.
            , .{
                prog.len,
                cycles,
                state.regs.getGP(1),
                state.regs.getGP(2),
                r3,
                state.regs.getGP(4),
                stats.tricache_overall_hit_rate,
                stats.energy_saved,
                stats.dream_mode,
            });
        } else {
            allocator.free(feedback);
            feedback = try allocator.dupe(u8, "No ```axiasm block found. Please emit one complete program ending in HALT.");
            std.debug.print("{s}\n", .{feedback});
        }

        if (cfg.tick_sleep_ms > 0) {
            std.Io.sleep(io, .fromMilliseconds(@intCast(cfg.tick_sleep_ms)), .awake) catch {};
        }
    }

    std.debug.print("\n=== agent loop finished ===\n", .{});
}

test "extract axiasm fence" {
    const t =
        \\hello
        \\```axiasm
        \\MOVI R1, 1
        \\HALT
        \\```
        \\bye
    ;
    const body = extractAxiAsm(t) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, body, "MOVI") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "HALT") != null);
}
