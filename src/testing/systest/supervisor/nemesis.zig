//! The nemesis injects faults into a running cluster, to test for fault tolerance. It's inspired
//! by Jepsen, but is not so advanced.
const std = @import("std");
const Shell = @import("../../../shell.zig");
const LoggedProcess = @import("./logged_process.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.nemesis);

const Self = @This();
const replicas_count_max = 16;

shell: *Shell,
allocator: std.mem.Allocator,
random: std.rand.Random,
replicas: []*LoggedProcess,
netem_rules: netem.Rules,

pub fn init(
    shell: *Shell,
    allocator: std.mem.Allocator,
    random: std.rand.Random,
    replicas: []*LoggedProcess,
) !*Self {
    assert(replicas.len <= replicas_count_max);

    const nemesis = try allocator.create(Self);

    nemesis.* = .{
        .shell = shell,
        .allocator = allocator,
        .random = random,
        .replicas = replicas,
        .netem_rules = netem.Rules{ .delay = null, .loss = null },
    };

    return nemesis;
}

pub fn deinit(self: *Self) void {
    self.network_netem_delete_all() catch {};
    const allocator = self.allocator;
    allocator.destroy(self);
}

const Havoc = enum {
    terminate_replica,
    restart_replica,
    network_delay_add,
    network_delay_remove,
    network_loss_add,
    network_loss_remove,
    sleep,
};

pub fn wreak_havoc(self: *Self) !bool {
    const havoc = weighted(self.random, Havoc, .{
        .sleep = 50,
        .terminate_replica = 1,
        .restart_replica = 10,
        .network_delay_add = 1,
        .network_delay_remove = 10,
        .network_loss_add = 1,
        .network_loss_remove = 10,
    });
    switch (havoc) {
        .terminate_replica => return try self.terminate_replica(),
        .restart_replica => return try self.restart_replica(),
        .network_delay_add => {
            if (self.netem_rules.delay != null) {
                return false;
            }
            const delay_ms = self.random.intRangeAtMost(u16, 10, 200);
            self.netem_rules.delay = .{
                .time_ms = delay_ms,
                .jitter_ms = @divFloor(delay_ms, 10),
                .correlation_pct = 75,
            };
            try self.netem_sync();
            return true;
        },
        .network_delay_remove => {
            if (self.netem_rules.delay == null) {
                return false;
            }
            self.netem_rules.delay = null;
            try self.netem_sync();
            return true;
        },
        .network_loss_add => {
            if (self.netem_rules.loss != null) {
                return false;
            }
            const loss_pct = self.random.intRangeAtMost(u8, 5, 100);
            self.netem_rules.loss = .{
                .loss_pct = loss_pct,
                .correlation_pct = 75,
            };
            try self.netem_sync();
            return true;
        },
        .network_loss_remove => {
            if (self.netem_rules.loss == null) {
                return false;
            }
            self.netem_rules.loss = null;
            try self.netem_sync();
            return true;
        },
        .sleep => {
            std.time.sleep(3 * std.time.ns_per_s);
            return true;
        },
    }
}

fn random_replica_in_state(self: *Self, state: LoggedProcess.State) ?*LoggedProcess {
    var matching: [replicas_count_max]*LoggedProcess = undefined;
    var pos: u8 = 0;

    for (self.replicas) |replica| {
        if (replica.state() == state) {
            matching[pos] = replica;
            pos += 1;
        }
    }
    if (pos == 0) {
        return null;
    }
    std.rand.shuffle(self.random, *LoggedProcess, matching[0..pos]);
    return matching[0];
}

fn terminate_replica(self: *Self) !bool {
    if (self.random_replica_in_state(.running)) |replica| {
        log.info("stopping {s}", .{replica.name});
        _ = try replica.terminate();
        log.info("{s} stopped", .{replica.name});
        return true;
    } else return false;
}

fn restart_replica(self: *Self) !bool {
    if (self.random_replica_in_state(.terminated)) |replica| {
        log.info("restarting {s}", .{replica.name});
        try replica.start();
        log.info("{s} back up again", .{replica.name});
        return true;
    } else return false;
}

const netem = struct {
    // See: https://man7.org/linux/man-pages/man8/tc-netem.8.html
    const Rules = struct {
        delay: ?struct {
            time_ms: u32,
            jitter_ms: u32,
            correlation_pct: u8,
        },
        loss: ?struct {
            loss_pct: u8,
            correlation_pct: u8,
        },
        // Others not implemented: limit, corrupt, duplication, reordering, rate, slot, seed
    };
};

fn netem_sync(self: *Self) !void {
    const args_max = (std.meta.fields(netem.Rules).len + 1) * 8;
    var rules_buf = std.mem.zeroes([args_max][]const u8);
    var rules = std.ArrayListUnmanaged([]const u8).initBuffer(rules_buf[0..]);

    rules.appendSliceAssumeCapacity(&.{ "tc", "qdisc", "replace", "dev", "lo", "root", "netem" });

    var args_delay_time = std.mem.zeroes([4]u8);
    var args_delay_jitter = std.mem.zeroes([4]u8);
    var args_delay_correlation = std.mem.zeroes([4]u8);
    var args_loss_pct = std.mem.zeroes([4]u8);
    var args_loss_correlation = std.mem.zeroes([4]u8);

    if (self.netem_rules.delay) |delay| {
        rules.appendAssumeCapacity("delay");
        rules.appendAssumeCapacity(try std.fmt.bufPrint(
            args_delay_time[0..],
            "{d}ms",
            .{delay.time_ms},
        ));
        rules.appendAssumeCapacity(try std.fmt.bufPrint(
            args_delay_jitter[0..],
            "{d}ms",
            .{delay.jitter_ms},
        ));
        rules.appendAssumeCapacity(try std.fmt.bufPrint(
            args_delay_correlation[0..],
            "{d}%",
            .{delay.correlation_pct},
        ));
        rules.appendAssumeCapacity("distribution");
        rules.appendAssumeCapacity("normal");
    }

    if (self.netem_rules.loss) |loss| {
        rules.appendAssumeCapacity("loss");
        rules.appendAssumeCapacity(try std.fmt.bufPrint(
            args_loss_pct[0..],
            "{d}%",
            .{loss.loss_pct},
        ));
        rules.appendAssumeCapacity(try std.fmt.bufPrint(
            args_loss_correlation[0..],
            "{d}%",
            .{loss.correlation_pct},
        ));
    }

    // Everything stack-allocated and simple up to here. Now this feels like a shame just for
    // logging:
    const rules_formatted = try std.mem.join(self.allocator, " ", rules.items);
    defer self.allocator.free(rules_formatted);
    log.info("syncing netem: {s}", .{rules_formatted});

    try self.shell.exec("{args}", .{ .args = rules.items });
}

fn network_netem_delete_all(self: *Self) !void {
    try self.shell.exec("tc qdisc del dev lo root", .{});
}

/// Draw an enum value from `E` based on the relative `weights`. Fields in the weights struct must
/// match the enum.
///
/// The `E` type parameter should be inferred, but seemingly to due to
/// https://github.com/ziglang/zig/issues/19985, it can't be.
fn weighted(
    random: std.rand.Random,
    comptime E: type,
    comptime weights: std.enums.EnumFieldStruct(E, u32, null),
) E {
    const s = @typeInfo(@TypeOf(weights)).Struct;
    comptime var total: u64 = 0;
    comptime var enum_weights: [s.fields.len]std.meta.Tuple(&.{ E, comptime_int }) = undefined;

    comptime {
        for (s.fields, 0..) |field, i| {
            const weight: comptime_int = @field(weights, field.name);
            assert(weight > 0);
            total += weight;
            const value = std.meta.stringToEnum(E, field.name).?;
            enum_weights[i] = .{ value, weight };
        }
    }

    const pick = random.uintLessThan(u64, total) + 1;
    var current: u64 = 0;
    inline for (enum_weights) |w| {
        current += w[1];
        if (pick <= current) {
            return w[0];
        }
    }
    unreachable;
}

fn join_args(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    assert(args.len > 0);

    var out = std.ArrayList(u8).init(allocator);
    const writer = out.writer();

    try writer.writeAll(args[0]);
    for (args[1..]) |arg| {
        try writer.writeByte(' ');
        try writer.writeAll(arg);
    }

    return out.toOwnedSlice();
}
