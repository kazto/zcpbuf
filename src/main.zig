const std = @import("std");
const zcpbuf = @import("zcpbuf");

const usage =
    \\Usage: zcpbuf <command>
    \\
    \\Commands:
    \\  copy   Read from stdin and write to clipboard
    \\  paste  Read from clipboard and write to stdout
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(1);
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "copy") or std.mem.eql(u8, cmd, "c")) {
        try cmdCopy(allocator);
    } else if (std.mem.eql(u8, cmd, "paste") or std.mem.eql(u8, cmd, "p")) {
        try cmdPaste(allocator);
    } else {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(1);
    }
}

fn cmdCopy(allocator: std.mem.Allocator) !void {
    const text = try std.fs.File.stdin().readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(text);
    try zcpbuf.writeAll(allocator, text);
}

fn cmdPaste(allocator: std.mem.Allocator) !void {
    const text = zcpbuf.readAll(allocator) catch |err| {
        if (err == error.OscReadNotSupported) {
            try std.fs.File.stderr().writeAll(
                "paste: clipboard read is not supported in this environment " ++
                    "(no X11/Wayland display; OSC 52 is write-only)\n",
            );
            std.process.exit(1);
        }
        return err;
    };
    defer allocator.free(text);
    try std.fs.File.stdout().writeAll(text);
}
