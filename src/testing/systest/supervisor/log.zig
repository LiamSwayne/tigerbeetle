const std = @import("std");

fn log_with_level(
    comptime message_level: std.log.Level,
    scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        _ = writer.write(scope) catch return;
        writer.print(
            ": " ++ level_txt ++ ": " ++ format ++ "\n",
            args,
        ) catch return;
        bw.flush() catch return;
    }
}

pub fn info(
    scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    log_with_level(.info, scope, format, args);
}

pub fn warn(
    scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    log_with_level(.info, scope, format, args);
}

pub fn err(
    scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    log_with_level(.info, scope, format, args);
}
