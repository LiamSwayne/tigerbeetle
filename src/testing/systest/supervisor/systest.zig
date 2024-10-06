//! The systest supervisor is a script that runs:
//!
//! * a set of TigerBeetle replicas, forming a cluster
//! * a workload that runs commands and queries against the cluster, verifying its correctness
//!   (whatever that means is up to the workload)
//! * a nemesis, which injects various kinds of _faults_.
//!
//! Right now the replicas and workload run as child processes, while the nemesis wreaks havoc
//! in the main loop. After some (configurable) amount of time, the supervisor terminates the
//! workload and replicas, unless the workload exits on its own.
//!
//! If the workload exits successfully, or is actively terminated, the whole systest exits
//! successfully.
//!
//! To launch a 1-minute smoke test, run this command from the repository root:
//!
//!     $ zig build test:integration -- "systest smoke"
//!
//! If you need more control, you can run this script directly:
//!
//!     $ unshare -nfr zig build scripts -- systest --tigerbeetle-executable=./tigerbeetle
//!
//! NOTE: This requires that the Java client and Java workload are built first.
//!
//! Run a longer test:
//!
//!     $ unshare -nfr zig build scripts -- systest --tigerbeetle-executable=./tigerbeetle \
//!         --test-duration-minutes=10
//!
//! To capture its logs, for instance to run grep afterwards, redirect stderr to a file.
//!
//!     $ unshare -nfr zig build scripts -- systest --tigerbeetle-executable=./tigerbeetle \
//!         2> /tmp/systest.log
//!
//! If you have permissions troubles with Ubuntu, see:
//! https://github.com/YoYoGames/GameMaker-Bugs/issues/6015#issuecomment-2135552784
//!
//! TODO:
//!
//! * full partitioning
//! * better workload(s)
//! * filesystem fault injection?
//! * cluster membership changes?
//! * upgrades?

const std = @import("std");
const builtin = @import("builtin");
const Shell = @import("../../../shell.zig");
const LoggedProcess = @import("./logged_process.zig");
const Replica = @import("./replica.zig");
const Nemesis = @import("./nemesis.zig");
const log = std.log.scoped(.systest);

const assert = std.debug.assert;

const replica_count = 3;
const replica_ports = [replica_count]u16{ 3000, 3001, 3002 };

pub const CLIArgs = struct {
    tigerbeetle_executable: []const u8,
    test_duration_minutes: u16 = 10,
};

pub fn main(shell: *Shell, allocator: std.mem.Allocator, args: CLIArgs) !void {
    if (builtin.os.tag == .windows) {
        log.err("systest is not supported for Windows", .{});
        return error.NotSupported;
    }

    const tmp_dir = try shell.create_tmp_dir();
    defer shell.cwd.deleteDir(tmp_dir) catch {};

    // Check that we are running as root.
    if (!std.mem.eql(u8, try shell.exec_stdout("id -u", .{}), "0")) {
        log.err(
            "this script needs to be run in a separate namespace using 'unshare -nfr'",
            .{},
        );
        std.process.exit(1);
    }

    // Ensure loopback can be used for network fault injection by the nemesis.
    try shell.exec("ip link set up dev lo", .{});

    log.info(
        "starting test with target runtime of {d}m",
        .{args.test_duration_minutes},
    );
    const test_duration_ns = @as(u64, @intCast(args.test_duration_minutes)) * std.time.ns_per_min;
    const test_deadline = std.time.nanoTimestamp() + test_duration_ns;

    var replicas: [replica_count]*Replica = undefined;
    for (0..replica_count) |i| {
        const datafile = try shell.fmt("{s}/1_{d}.tigerbeetle", .{ tmp_dir, i });

        // Format each replica's datafile.
        try shell.exec(
            \\{tigerbeetle} format 
            \\  --cluster=1
            \\  --replica={index}
            \\  --replica-count={replica_count} 
            \\  {datafile}
        , .{
            .tigerbeetle = args.tigerbeetle_executable,
            .index = i,
            .replica_count = replica_count,
            .datafile = datafile,
        });

        // Start replica.
        var replica = try Replica.create(
            allocator,
            @intCast(i),
            args.tigerbeetle_executable,
            &replica_ports,
            datafile,
        );
        errdefer replica.destroy();

        try replica.start();

        replicas[i] = replica;
    }

    // Start workload.
    const workload = try start_workload(shell, allocator);
    errdefer workload.destroy();

    // Set up nemesis (fault injector).
    var prng = std.rand.DefaultPrng.init(0);
    const nemesis = try Nemesis.init(allocator, prng.random(), &replicas);
    defer nemesis.deinit();

    // Let the workload finish by itself, or kill it after we've run for the required duration.
    // Note that the nemesis is blocking in this loop.
    const workload_result =
        while (std.time.nanoTimestamp() < test_deadline)
    {
        // Try to do something funky in the nemesis. If the picked action is
        // not enabled (false is returned), wait for a while before trying again.
        if (!try nemesis.wreak_havoc()) {
            std.time.sleep(100 * std.time.ns_per_ms);
        }
        if (workload.state() == .completed) {
            log.info("workload completed by itself", .{});
            break try workload.wait();
        }
    } else blk: {
        log.info("terminating workload due to max duration", .{});
        break :blk try workload.terminate();
    };

    workload.destroy();

    for (replicas) |replica| {
        // The nemesis might have terminated the replica and never restarted it,
        // so we need to check its state.
        if (replica.state() == .running) {
            _ = try replica.terminate();
        }
        replica.destroy();
    }

    switch (workload_result) {
        .Exited => |code| {
            if (code == 128 + std.posix.SIG.KILL) {
                log.info("workload terminated (SIGKILL) as requested", .{});
            } else if (code == 0) {
                log.info("workload exited successfully", .{});
            } else {
                log.info("workload exited unexpectedly with code {d}", .{code});
                std.process.exit(1);
            }
        },
        .Signal => |signal| {
            switch (signal) {
                std.posix.SIG.KILL => log.info(
                    "workload terminated (SIGKILL) as requested",
                    .{},
                ),
                else => {
                    log.info(
                        "workload exited unexpectedly with on signal {d}",
                        .{signal},
                    );
                    std.process.exit(1);
                },
            }
        },
        else => {
            log.info("unexpected workload result: {any}", .{workload_result});
            return error.TestFailed;
        },
    }
}

fn start_workload(shell: *Shell, allocator: std.mem.Allocator) !*LoggedProcess {
    const name = "workload";
    const client_jar = "src/clients/java/target/tigerbeetle-java-0.0.1-SNAPSHOT.jar";
    const workload_jar = "src/testing/systest/workload/target/workload-0.0.1-SNAPSHOT.jar";

    const class_path = try shell.fmt("{s}:{s}", .{ client_jar, workload_jar });
    const argv = try shell.arena.allocator().dupe([]const u8, &.{
        "java",
        "-ea",
        "-cp",
        class_path,
        "Main",
    });

    var env = try std.process.getEnvMap(shell.arena.allocator());
    try env.put("REPLICAS", try LoggedProcess.comma_separate_ports(
        shell.arena.allocator(),
        &replica_ports,
    ));

    return try LoggedProcess.spawn(allocator, name, argv, .{ .env = &env });
}
