const std = @import("std");
const fs = std.fs;
const mem = std.mem;
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

    fn argv(self: KubeContext) ![]const []const u8 {
        var argv_buffer = std.ArrayList([]const u8).init(self.allocator);
        var r = std.ArrayList([]const u8).init(self.allocator);
        defer argv_buffer.deinit();

        if (self.context) |context| {
            if (self.namespace) |namespace| {
                try argv_buffer.append(try std.fmt.allocPrint(self.allocator, "kubectl config set-context \"{s}\" --namespace=\"{s}\"", .{ context, namespace }));
            } else {
                try argv_buffer.append(try std.fmt.allocPrint(self.allocator, "kubectl config use-context \"{s}\"", .{context}));
            }
        } else if (self.namespace) |namespace| {
            try argv_buffer.append(try std.fmt.allocPrint(self.allocator, "kubectl config set-context \"$(kubectl config current-context)\" --namespace=\"{s}\"", .{namespace}));
        } else {
            return error.NoCommand;
        }
        try argv_buffer.appendSlice(&[_][]const u8{self.shell});
        const argv1 = try std.mem.join(self.allocator, " && ", argv_buffer.items);
        try r.appendSlice(&[_][]const u8{ self.shell, "-c", argv1 });
        return r.toOwnedSlice();
    }

    pub fn run(self: KubeContext) !void {
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const kubeconfig_real_path = try std.os.realpath(self.kubeconfig, &buf);
        const new_kubeconfig = try fs.path.joinZ(self.allocator, &[_][]const u8{ tempDir(), &randomString() });
        try fs.copyFileAbsolute(kubeconfig_real_path, new_kubeconfig, .{ .override_mode = 0o600 });
        _ = c.setenv("KUBECONFIG", new_kubeconfig, 1);
        const _argv = try self.argv();
        var child = std.ChildProcess.init(_argv, self.allocator);
        const term = try std.ChildProcess.spawnAndWait(&child);
        switch (term.Exited) {
            0 => try std.os.kill(c.getppid(), std.os.SIG.HUP),
            1 => return,
            else => unreachable,
        }
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
