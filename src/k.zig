const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const yaml = @import("zig-libyaml/src/libyaml.zig");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

const Allocator = mem.Allocator;

pub const Target = union(enum) { Namespace: []const u8, Context: []const u8 };

pub const KubeContext = struct {
    allocator: Allocator,
    shell: []const u8,
    kubeconfig: []const u8,
    namespace: ?[]const u8,
    context: ?[]const u8,

    pub fn init(allocator: Allocator, kubeconfig: ?[]const u8) !KubeContext {
        const shell = std.os.getenv("SHELL") orelse {
            return error.NoShell;
        };

        const real_kubeconfig = blk: {
            if (kubeconfig) |k|
                break :blk k;
            if (std.os.getenv("KUBECONFIG")) |k|
                break :blk k;
            if (std.os.getenv("HOME")) |k| {
                const possible_kubeconfig = try fs.path.join(allocator, &[_][]const u8{ k, ".kube", "config" });
                break :blk possible_kubeconfig;
            }
            break :blk "";
        };

        if (mem.eql(u8, real_kubeconfig, ""))
            return error.NoKubeconfig;

        return KubeContext{
            .allocator = allocator,
            .shell = shell,
            .kubeconfig = real_kubeconfig,
            .namespace = null,
            .context = null,
        };
    }

    pub fn switchTo(self: *KubeContext, target: Target) void {
        switch (target) {
            .Namespace => self.namespace = target.Namespace,
            .Context => self.context = target.Context,
        }
    }

    pub fn run(self: KubeContext) !void {
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const kubeconfig_real_path = try std.os.realpath(self.kubeconfig, &buf);
        const new_kubeconfig: [:0]const u8 = try fs.path.joinZ(self.allocator, &[_][]const u8{ tempDir(), &randomString() });

        const file = try std.fs.openFileAbsolute(kubeconfig_real_path, .{});
        defer file.close();

        var buf_stream = std.io.bufferedReader(file.reader());
        var reader = buf_stream.reader();

        var parser: yaml.Parser = undefined;
        try parser.initStream(self.allocator, &reader);
        defer parser.deinit();

        var tree = try parser.tree();

        if (self.context) |target_context| {
            switch (tree.root) {
                .Object => |*root| {
                    const context_array = root.get("contexts") orelse return error.InvalidConfig;
                    if (@as(yaml.Value, context_array) != yaml.Value.Array)
                        return error.InvalidConfig;

                    var context_not_found = true;
                    for (context_array.Array.items) |context_item| {
                        if (@as(yaml.Value, context_item) != yaml.Value.Object)
                            return error.InvalidConfig;

                        const context_name = context_item.Object.get("name") orelse return error.InvalidConfig;
                        if (@as(yaml.Value, context_name) != yaml.Value.String)
                            return error.InvalidConfig;

                        if (std.mem.eql(u8, context_name.String.value, target_context)) {
                            try root.put("current-context", context_name);
                            context_not_found = false;
                            break;
                        }
                    }

                    if (context_not_found)
                        return error.ContextNotFound;
                },
                else => return error.InvalidConfig,
            }
        }

        if (self.namespace) |target_namespace| {
            switch (tree.root) {
                .Object => |*root| {
                    const current_context = root.get("current-context") orelse return error.NoContextSet;
                    if (@as(yaml.Value, current_context) != yaml.Value.String)
                        return error.InvalidConfig;

                    const context_array = root.get("contexts") orelse return error.InvalidConfig;
                    if (@as(yaml.Value, context_array) != yaml.Value.Array)
                        return error.InvalidConfig;

                    var context_not_found = true;
                    for (context_array.Array.items) |context_item| {
                        if (@as(yaml.Value, context_item) != yaml.Value.Object)
                            return error.InvalidConfig;

                        const context_name = context_item.Object.get("name") orelse return error.InvalidConfig;
                        if (@as(yaml.Value, context_name) != yaml.Value.String)
                            return error.InvalidConfig;

                        if (std.mem.eql(u8, context_name.String.value, current_context.String.value)) {
                            var context = context_item.Object.get("context") orelse return error.InvalidConfig;
                            if (@as(yaml.Value, context) != yaml.Value.Object)
                                return error.InvalidConfig;
                            try context.Object.put("namespace", yaml.Value{ .String = .{ .value = target_namespace } });
                            context_not_found = false;
                            break;
                        }
                    }
                    if (context_not_found)
                        return error.ContextNotFound;
                },
                else => return error.InvalidConfig,
            }
        }

        {
            var f = try std.fs.createFileAbsolute(new_kubeconfig, .{});

            defer f.close();

            var bs = std.io.bufferedWriter(f.writer());
            var st = bs.writer();
            try tree.write(&st, .{});
            try bs.flush();
        }

        _ = c.setenv("KUBECONFIG", new_kubeconfig.ptr, 1);

        var child = std.ChildProcess.init(&[_][]const u8{self.shell}, self.allocator);
        _ = try std.ChildProcess.spawnAndWait(&child);
        std.os.kill(c.getppid(), std.os.SIG.HUP) catch {};
    }
};

fn randomString() [10]u8 {
    const chars: []const u8 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-";
    var seed: [std.rand.DefaultCsprng.secret_seed_length]u8 = undefined;
    std.crypto.random.bytes(&seed);
    var rng = std.rand.DefaultCsprng.init(seed);
    var str: [10]u8 = undefined;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var res: u8 = rng.random().uintLessThanBiased(u8, chars.len);
        str[i] = chars[res];
    }
    return str;
}

fn tempDir() []const u8 {
    switch (@import("builtin").os.tag) {
        .linux, .macos => {
            const env_vars = [_][]const u8{ "TMPDIR", "TMP", "TEMP", "TEMPDIR" };
            for (env_vars) |env_var| {
                if (std.os.getenv(env_var)) |tmp|
                    return tmp;
            }
            return "/tmp";
        },
        else => @compileError("unsupported OS"),
    }
}
