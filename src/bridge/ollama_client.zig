// Ollama HTTP client for axiNC agent loop (Zig 0.16).
//
// SOURCES (AxiMinds GitHub, adapted):
//   - AxiMinds-Claude-Remote/src/orchestrators/ollama.zig
//   - AxiMinds-Claude-Remote/src/orchestrators/openai_compat.zig
//   - AxiMinds-NoDev/src/ollama/injector.zig + client.zig
//   - AxiMinds-Discovery/explorer-ollama.sh (model defaults)

const std = @import("std");

pub const Config = struct {
    endpoint: []const u8 = "http://127.0.0.1:11434",
    model: []const u8 = "qwen3.5:0.8b",
};

pub const Result = struct {
    text: []u8,
    model_used: []const u8,
    ok: bool,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn chat(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    user_message: []const u8,
    system_prompt: ?[]const u8,
) !Result {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"model\":");
    try appendJsonString(allocator, &body, config.model);
    try body.appendSlice(allocator, ",\"stream\":false,\"messages\":[");

    if (system_prompt) |sp| {
        try body.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try appendJsonString(allocator, &body, sp);
        try body.appendSlice(allocator, "},");
    }
    try body.appendSlice(allocator, "{\"role\":\"user\",\"content\":");
    try appendJsonString(allocator, &body, user_message);
    try body.appendSlice(allocator, "}]}");

    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{config.endpoint});

    const run = std.process.run(allocator, io, .{
        .argv = &.{
            "curl", "-sf",
            "--connect-timeout", "10",
            "--max-time", "300",
            "-X", "POST",
            url,
            "-H", "Content-Type: application/json",
            "-d", body.items,
        },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        return Result{
            .text = try std.fmt.allocPrint(allocator, "Ollama process error: {}", .{err}),
            .model_used = config.model,
            .ok = false,
        };
    };
    defer allocator.free(run.stderr);

    const ok_http = switch (run.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok_http) {
        allocator.free(run.stdout);
        return Result{
            .text = try std.fmt.allocPrint(allocator, "Ollama HTTP failed (is ollama serve running at {s}? model={s})", .{ config.endpoint, config.model }),
            .model_used = config.model,
            .ok = false,
        };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, run.stdout, .{}) catch {
        return Result{ .text = run.stdout, .model_used = config.model, .ok = true };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return Result{ .text = run.stdout, .model_used = config.model, .ok = true };
    }
    const obj = parsed.value.object;

    if (obj.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |m| {
                if (m == .string) {
                    allocator.free(run.stdout);
                    return Result{
                        .text = try allocator.dupe(u8, m.string),
                        .model_used = config.model,
                        .ok = false,
                    };
                }
            }
        }
    }

    if (obj.get("message")) |msg| {
        if (msg == .object) {
            if (msg.object.get("content")) |c| {
                if (c == .string) {
                    allocator.free(run.stdout);
                    return Result{
                        .text = try allocator.dupe(u8, c.string),
                        .model_used = config.model,
                        .ok = true,
                    };
                }
            }
        }
    }

    if (obj.get("response")) |r| {
        if (r == .string) {
            allocator.free(run.stdout);
            return Result{
                .text = try allocator.dupe(u8, r.string),
                .model_used = config.model,
                .ok = true,
            };
        }
    }

    return Result{ .text = run.stdout, .model_used = config.model, .ok = true };
}

fn appendJsonString(allocator: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                    try list.appendSlice(allocator, esc);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
    try list.append(allocator, '"');
}

pub fn isReachable(allocator: std.mem.Allocator, io: std.Io, config: Config) bool {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/tags", .{config.endpoint}) catch return false;
    const run = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-sf", "--connect-timeout", "2", "--max-time", "5", url },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    return switch (run.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "json escape basic" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendJsonString(std.testing.allocator, &list, "a\"b\n");
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\\\"") != null);
}
