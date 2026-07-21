// Legacy path — full C ABI is src/bridge_lib.zig (Zig 0.16 package root).
// Link zig-out/lib/libaxinc.so for host (llama.cpp) integration.
pub const bridge = @import("../bridge_lib.zig");
pub const axinc_init = bridge.axinc_init;
pub const axinc_ffn_tap = bridge.axinc_ffn_tap;
pub const axinc_get_stats_json = bridge.axinc_get_stats_json;
pub const axinc_load_program = bridge.axinc_load_program;
pub const axinc_load_axiasm = bridge.axinc_load_axiasm;
pub const axinc_model_register = bridge.axinc_model_register;
pub const axinc_model_infer = bridge.axinc_model_infer;
pub const axinc_shutdown = bridge.axinc_shutdown;
