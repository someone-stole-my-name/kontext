const std = @import("std");
const k = @import("k.zig");

const mem = std.mem;

const usage =
    \\Usage: kontext [OPTIONS] [CONTEXT]
    \\
    \\Options:
    \\  -n, --namespace NAME   Namespace to use.
    \\  --kubeconfig FILE      Path to a kubeconfig file.
    \\  -h, --help             Display this help and exit.
    \\
    \\Subcommands:
    \\  completion             Generate completion scripts.
;

const completion = std.ComptimeStringMap([]const u8, .{
    .{ "zsh", @embedFile("completion/zsh") },
});

const completion_usage =
    \\Usage: kontext completion SHELL
    \\
    \\Available shells:
    \\  zsh
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    var cmd_arg_context: ?[]const u8 = null;
    var cmd_arg_kubeconfig: ?[]const u8 = null;
    var cmd_arg_namespace: ?[]const u8 = null;

    var args = try std.process.argsAlloc(allocator);
    const cmd_args = args[1..];

    if (args.len <= 1)
        die("{s}\n", .{usage});

    if (mem.eql(u8, cmd_args[0], "completion")) {
        if (cmd_args.len >= 2 and completion.has(cmd_args[1])) {
            try stdout.print("{s}\n", .{completion.get(cmd_args[1]).?});
            std.process.exit(1);
        }
        die("{s}\n", .{completion_usage});
    }

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        if (mem.eql(u8, cmd_args[i], "-h") or
            mem.eql(u8, cmd_args[i], "--help"))
        {
            die("{s}\n", .{usage});
        }

        if (mem.eql(u8, cmd_args[i], "--kubeconfig")) {
            if (cmd_arg_kubeconfig != null)
                die("{s}\n", .{usage});

            i += 1;
            if (i >= cmd_args.len)
                die("--kubeconfig requires a value.\n{s}\n", .{usage});

            cmd_arg_kubeconfig = cmd_args[i];
            continue;
        }

        if (mem.eql(u8, cmd_args[i], "--namespace") or
            mem.eql(u8, cmd_args[i], "-n"))
        {
            if (cmd_arg_namespace != null)
                die("{s}\n", .{usage});

            i += 1;
            if (i >= cmd_args.len)
                die("--namespace requires a value.\n{s}\n", .{usage});

            cmd_arg_namespace = cmd_args[i];
            continue;
        }

        if (mem.startsWith(u8, cmd_args[i], "-"))
            die("unkown option '{s}'\n{s}\n", .{ cmd_args[i], usage });

        if (cmd_arg_context == null) {
            cmd_arg_context = cmd_args[i];
        } else {
            die("only a single context is allowed\n{s}\n", .{usage});
        }
    }

    var f = try k.KubeContext.init(allocator, cmd_arg_kubeconfig);
    if (cmd_arg_context) |context|
        f.switchTo(k.Target{ .Context = context });

    if (cmd_arg_namespace) |namespace|
        f.switchTo(k.Target{ .Namespace = namespace });

    return f.run();
}

fn die(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
