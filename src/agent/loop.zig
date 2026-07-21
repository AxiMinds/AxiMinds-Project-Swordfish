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
const build_options = @import("build_options");
comptime {
    _ = build_options.dev_debug;
}
const core = @import("../core/types.zig");
const engine_mod = @import("../core/engine.zig");
const assembler = @import("../asm/assembler.zig");
const ollama = @import("../bridge/ollama_client.zig");
const models = @import("../models/host.zig");

pub const AgentConfig = struct {
    ollama: ollama.Config = .{},
    /// Max agent ticks (0 = run until error / HALT policy)
    max_ticks: u32 = 8,
    /// Sleep between ticks (ms) for "throughout the day" pacing
    tick_sleep_ms: u64 = 500,
    /// Cycles per NC tap after loading program
    max_cycles_per_tap: u64 = 256,
    /// When true, skip Ollama and inject a canned axiASM + model plan (CI / offline MVP).
    mock_llm: bool = false,
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
        \\To run a SECOND model (hosted via Ollama), emit:
        \\```model
        \\ollama qwen3.5:0.8B
        \\Say hello from the secondary model.
        \\```
        \\Or for a GGUF file: first line `gguf /path/to/model.gguf` then optional prompt.
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

/// Extract fenced block body after opening marker (not owned).
fn extractFence(text: []const u8, needles: []const []const u8) ?[]const u8 {
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
    if (body_start < text.len and (text[body_start] == '\n' or text[body_start] == '\r')) {
        body_start += 1;
        if (body_start < text.len and text[body_start - 1] == '\r' and text[body_start] == '\n') body_start += 1;
    }
    const rest = text[body_start..];
    const end_rel = std.mem.indexOf(u8, rest, "```") orelse return null;
    return std.mem.trim(u8, rest[0..end_rel], " \t\r\n");
}

/// Extract first ```axiasm ... ``` block body (not owned).
pub fn extractAxiAsm(text: []const u8) ?[]const u8 {
    const needles = [_][]const u8{ "```axiasm", "```axiASM", "```axi-asm", "```AXIASM" };
    return extractFence(text, &needles);
}

/// Extract ```model ... ``` block: line1 = "ollama TAG" or "gguf PATH", rest = prompt.
pub fn extractModelBlock(text: []const u8) ?[]const u8 {
    const needles = [_][]const u8{ "```model", "```MODEL" };
    return extractFence(text, &needles);
}

pub fn parseModelBlock(body: []const u8) struct { kind: models.ModelKind, name: []const u8, prompt: []const u8 } {
    var lines = std.mem.splitScalar(u8, body, '\n');
    const first = std.mem.trim(u8, lines.next() orelse "", " \t\r");
    const rest_start = if (first.len < body.len) first.len + 1 else body.len;
    const prompt = std.mem.trim(u8, if (rest_start < body.len) body[rest_start..] else "", " \t\r\n");

    if (std.mem.startsWith(u8, first, "gguf ")) {
        return .{ .kind = .gguf, .name = std.mem.trim(u8, first[5..], " \t"), .prompt = prompt };
    }
    if (std.mem.startsWith(u8, first, "ollama ")) {
        return .{ .kind = .ollama, .name = std.mem.trim(u8, first[7..], " \t"), .prompt = prompt };
    }
    // default: treat first token line as ollama tag, rest prompt
    return .{ .kind = .ollama, .name = first, .prompt = if (prompt.len > 0) prompt else "ping" };
}

pub fn runLoop(allocator: std.mem.Allocator, io: std.Io, cfg: AgentConfig) !void {
    std.debug.print("=== axiNC + Ollama agent loop ===\n", .{});
    std.debug.print("endpoint={s} model={s} max_ticks={d}\n", .{ cfg.ollama.endpoint, cfg.ollama.model, cfg.max_ticks });

    if (!cfg.mock_llm) {
        if (!ollama.isReachable(allocator, io, cfg.ollama)) {
            std.debug.print("ERROR: Ollama not reachable at {s}\n", .{cfg.ollama.endpoint});
            std.debug.print("Start with: ollama serve (host may use port 11534) && ollama pull {s}\n", .{cfg.ollama.model});
            std.debug.print("Or use: zig build run -- agent --mock\n", .{});
            return error.OllamaUnreachable;
        }
        std.debug.print("Ollama reachable.\n", .{});
    } else {
        std.debug.print("MOCK LLM mode (offline MVP path).\n", .{});
    }

    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);

    var eng = try engine_mod.Engine.init(allocator, &state, .{
        .max_cycles_per_tap = cfg.max_cycles_per_tap,
        .trace_enabled = false,
    });
    defer eng.deinit();

    var host = models.ModelHost.init(allocator);
    defer host.deinit();

    var feedback: []const u8 = try allocator.dupe(u8, "NC cold start. No program loaded yet. Emit a first axiASM program and/or a ```model block for a secondary model.");
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

        const llm: ollama.Result = if (cfg.mock_llm) blk: {
            // Mock drives REAL secondary GGUF weight-probe infer (fixture), not a skip.
            const canned =
                \\Plan: load axiASM then secondary GGUF model (real weight probe).
                \\```axiasm
                \\MOVI R1, 10
                \\MOVI R2, 3
                \\MUL R3, R1, R2
                \\HALT
                \\```
                \\```model
                \\gguf src/models/fixtures/tiny.gguf
                \\hello-weights
                \\```
            ;
            break :blk .{
                .text = try allocator.dupe(u8, canned),
                .model_used = "mock",
                .ok = true,
            };
        } else try ollama.chat(allocator, io, cfg.ollama, user_msg, cfg.standing_goal);
        defer llm.deinit(allocator);

        if (!llm.ok) {
            std.debug.print("LLM error: {s}\n", .{llm.text});
            allocator.free(feedback);
            feedback = try std.fmt.allocPrint(allocator, "LLM error: {s}", .{llm.text});
            continue;
        }

        std.debug.print("LLM ({s}) response ({d} bytes):\n{s}\n", .{ llm.model_used, llm.text.len, llm.text[0..@min(llm.text.len, 800)] });
        if (llm.text.len > 800) std.debug.print("... [truncated]\n", .{});

        // Secondary model block (Ollama or GGUF) — skip live infer in mock if ollama down
        if (extractModelBlock(llm.text)) |mbody| {
            const parsed = parseModelBlock(mbody);
            std.debug.print("Model block: kind={s} name={s}\n", .{ @tagName(parsed.kind), parsed.name });
            const slot = host.register(parsed.kind, parsed.name) catch |err| {
                allocator.free(feedback);
                feedback = try std.fmt.allocPrint(allocator, "model register error: {}", .{err});
                std.debug.print("{s}\n", .{feedback});
                continue;
            };
            // Always call real ModelHost.infer (GGUF weight probe or Ollama/inject).
            const out = host.infer(allocator, io, slot, parsed.prompt) catch |err| {
                allocator.free(feedback);
                feedback = try std.fmt.allocPrint(allocator, "model infer error slot={d}: {}", .{ slot, err });
                std.debug.print("{s}\n", .{feedback});
                continue;
            };
            defer allocator.free(out);
            std.debug.print("Secondary model output ({d} bytes):\n{s}\n", .{ out.len, out[0..@min(out.len, 600)] });
            allocator.free(feedback);
            feedback = try std.fmt.allocPrint(allocator, "Secondary model slot={d} infer OK ({d} bytes). Also emit axiASM if needed.", .{ slot, out.len });
        }

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

test "extract and parse model block" {
    const t =
        \\```model
        \\ollama qwen3.5:0.8B
        \\Say hi
        \\```
    ;
    const body = extractModelBlock(t) orelse return error.TestUnexpectedResult;
    const p = parseModelBlock(body);
    try std.testing.expect(p.kind == .ollama);
    try std.testing.expectEqualStrings("qwen3.5:0.8B", p.name);
    try std.testing.expect(std.mem.indexOf(u8, p.prompt, "Say hi") != null);
}

test "assembler + engine real path from agent-style source" {
    const allocator = std.testing.allocator;
    const src =
        \\MOVI R1, 10
        \\MOVI R2, 3
        \\MUL R3, R1, R2
        \\HALT
    ;
    const prog = try assembler.assemble(allocator, src);
    defer allocator.free(prog);
    try std.testing.expect(prog.len >= 4);

    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);
    var eng = try engine_mod.Engine.init(allocator, &state, .{ .max_cycles_per_tap = 64 });
    defer eng.deinit();
    try eng.loadProgram(prog);
    const ran = try eng.executeTap();
    try std.testing.expect(ran > 0);
    try std.testing.expectEqual(@as(i64, 30), state.regs.getGP(3));
}

test "mock agent loop end-to-end (no Ollama)" {
    // Uses process.Init-style Io via Threaded for process.run if needed; mock skips Ollama.
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    try runLoop(allocator, threaded.io(), .{
        .mock_llm = true,
        .max_ticks = 1,
        .tick_sleep_ms = 0,
        .max_cycles_per_tap = 64,
    });
}
