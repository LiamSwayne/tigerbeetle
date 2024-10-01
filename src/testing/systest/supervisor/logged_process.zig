//! Runs a subprocess and logs its stderr output. The processes can terminate by its own or be
//! actively terminated with a SIGKILL, and later be restarted again.
//!
//! We use this to run a cluster of replicas (and the workload), and terminate and restart replicas
//! to test fault tolerance.
//!
//! NOTE: some duplication exists between this and `tmp_tigerbeetle.zig` that could perhaps be
//! unified.
const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.logged_process);

const assert = std.debug.assert;

const Self = @This();
pub const State = enum(u8) { initial, running, terminated, completed };
const AtomicState = std.atomic.Value(State);
const Options = struct { env: ?*const std.process.EnvMap = null };

// Passed in to init
allocator: std.mem.Allocator,
name: []const u8,
argv: []const []const u8,
options: Options,

// Allocated by init
cwd: []const u8,

// Lifecycle state
child: ?std.process.Child = null,
stdin_thread: ?std.Thread = null,
stderr_thread: ?std.Thread = null,
current_state: AtomicState,

pub fn create(
    allocator: std.mem.Allocator,
    name: []const u8,
    argv: []const []const u8,
    options: Options,
) !*Self {
    const cwd = try std.process.getCwdAlloc(allocator);
    errdefer allocator.free(cwd);

    const process = try allocator.create(Self);
    errdefer allocator.destroy(process);

    process.* = .{
        .allocator = allocator,
        .name = name,
        .cwd = cwd,
        .argv = argv,
        .options = options,
        .current_state = AtomicState.init(.initial),
    };
    return process;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    allocator.free(self.cwd);
    allocator.destroy(self);
}

pub fn state(self: *Self) State {
    return self.current_state.load(.seq_cst);
}

pub fn start(
    self: *Self,
) !void {
    self.expect_state_in(.{ .initial, .terminated, .completed });
    defer self.expect_state_in(.{.running});

    assert(self.child == null);

    var child = std.process.Child.init(self.argv, self.allocator);

    child.cwd = self.cwd;
    child.env_map = self.options.env;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    errdefer {
        _ = child.kill() catch {};
    }

    // Zig doesn't have non-blocking version of child.wait, so we use `BrokenPipe`
    // on writing to child's stdin to detect if a child is dead in a non-blocking
    // manner. Checks once a second second in a separate thread.
    _ = try std.posix.fcntl(
        child.stdin.?.handle,
        std.posix.F.SETFL,
        @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })),
    );
    self.stdin_thread = try std.Thread.spawn(
        .{},
        struct {
            fn poll_broken_pipe(stdin: std.fs.File, process: *Self) void {
                while (process.state() == .initial or process.state() == .running) {
                    std.time.sleep(1 * std.time.ns_per_s);
                    _ = stdin.write(&.{1}) catch |err| {
                        switch (err) {
                            error.WouldBlock => {}, // still running
                            error.BrokenPipe,
                            error.NotOpenForWriting,
                            => {
                                process.current_state.store(.completed, .seq_cst);
                                break;
                            },
                            else => @panic(@errorName(err)),
                        }
                    };
                }
            }
        }.poll_broken_pipe,
        .{ child.stdin.?, self },
    );

    // The child process' stderr is echoed to stderr with a name prefix
    self.stderr_thread = try std.Thread.spawn(
        .{},
        struct {
            fn log_stderr(stderr: std.fs.File, process: *Self) void {
                while (process.state() == .initial or process.state() == .running) {
                    var buf: [1024 * 8]u8 = undefined;
                    const line_opt = stderr.reader().readUntilDelimiterOrEof(
                        &buf,
                        '\n',
                    ) catch |err| {
                        log.warn("{s}: failed reading stderr: {any}", .{ process.name, err });
                        continue;
                    };
                    if (line_opt) |line| {
                        log.info("{s}: {s}", .{ process.name, line });
                    } else {
                        break;
                    }
                }
            }
        }.log_stderr,
        .{ child.stderr.?, self },
    );

    self.child = child;
    self.current_state.store(.running, .seq_cst);
}

pub fn terminate(
    self: *Self,
) !std.process.Child.Term {
    self.expect_state_in(.{.running});
    defer self.expect_state_in(.{.terminated});

    var child = self.child.?;
    const stdin_thread = self.stdin_thread.?;
    const stderr_thread = self.stderr_thread.?;

    // Terminate the process
    //
    // Uses the same method as `src/testing/tmp_tigerbeetle.zig`.
    // See: https://github.com/ziglang/zig/issues/16820
    _ = kill: {
        if (builtin.os.tag == .windows) {
            const exit_code = 1;
            break :kill std.os.windows.TerminateProcess(child.id, exit_code);
        } else {
            break :kill std.posix.kill(child.id, std.posix.SIG.KILL);
        }
    } catch |err| {
        std.debug.print(
            "{s}: failed to kill process: {any}\n",
            .{ self.name, err },
        );
    };

    // Await threads
    stdin_thread.join();
    stderr_thread.join();

    // Await the terminated process
    const term = child.wait() catch unreachable;

    self.child = null;
    self.stderr_thread = null;
    self.current_state.store(.terminated, .seq_cst);

    return term;
}

pub fn wait(
    self: *Self,
) !std.process.Child.Term {
    self.expect_state_in(.{ .running, .completed });
    defer self.expect_state_in(.{.completed});

    var child = self.child.?;
    const stdin_thread = self.stdin_thread.?;
    const stderr_thread = self.stderr_thread.?;

    // Wait until the process runs to completion
    const term = child.wait();

    // Await threads
    stdin_thread.join();
    stderr_thread.join();

    self.child = null;
    self.stderr_thread = null;
    self.current_state.store(.completed, .seq_cst);

    return term;
}

fn expect_state_in(self: *Self, comptime valid_states: anytype) void {
    const actual_state = self.state();

    inline for (valid_states) |valid| {
        if (actual_state == valid) return;
    }

    log.err("{s}: expected state in {any} but actual state is {s}", .{
        self.name,
        valid_states,
        @tagName(actual_state),
    });
    unreachable;
}

fn format_argv(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    assert(argv.len > 0);

    var out = std.ArrayList(u8).init(allocator);
    const writer = out.writer();

    try writer.writeAll("$");
    for (argv) |arg| {
        try writer.writeByte(' ');
        try writer.writeAll(arg);
    }

    return try out.toOwnedSlice();
}

// The test for LoggedProcess needs an executable that runs forever which is solved (without
// depending on system executables) by using the Zig compiler to build this very file as an
// executable in a temporary directory.
pub usingnamespace if (@import("root") != @This()) struct {
    // For production builds, don't include the main function.
    // This is `if __name__ == "__main__":` at comptime!
} else struct {
    pub fn main() !void {
        while (true) {
            _ = try std.io.getStdErr().write("yep\n");
        }
    }
};

test "LoggedProcess: starts and stops" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer assert(gpa.deinit() == .ok);

    const zig_exe = try std.process.getEnvVarOwned(allocator, "ZIG_EXE"); // Set by build.zig
    defer allocator.free(zig_exe);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_dir_path = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp_dir.sub_path,
    });
    defer allocator.free(tmp_dir_path);

    const test_exe_buf = try allocator.create([std.fs.max_path_bytes]u8);
    defer allocator.destroy(test_exe_buf);

    { // Compile this file as an executable!
        const this_file = try std.fs.cwd().realpath(@src().file, test_exe_buf);
        const argv = [_][]const u8{ zig_exe, "build-exe", this_file };
        const exec_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &argv,
            .cwd = tmp_dir_path,
        });
        defer allocator.free(exec_result.stdout);
        defer allocator.free(exec_result.stderr);

        if (exec_result.term.Exited != 0) {
            std.debug.print("{s}{s}", .{ exec_result.stdout, exec_result.stderr });
            return error.FailedToCompile;
        }
    }

    const test_exe = try tmp_dir.dir.realpath(
        "logged_process" ++ comptime builtin.target.exeFileExt(),
        test_exe_buf,
    );

    const argv: []const []const u8 = &.{test_exe};

    const name = "test program";
    var replica = try Self.create(allocator, name, argv, .{});
    defer replica.destroy();

    // start & stop
    try replica.start();
    std.time.sleep(10 * std.time.ns_per_ms);
    _ = try replica.terminate();

    std.time.sleep(10 * std.time.ns_per_ms);

    // restart & stop
    try replica.start();
    std.time.sleep(10 * std.time.ns_per_ms);
    _ = try replica.terminate();
}

test format_argv {
    const formatted = try format_argv(std.testing.allocator, &.{ "foo", "bar", "baz" });
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("$ foo bar baz", formatted);
}
