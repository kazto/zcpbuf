const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    NoClipboardTool,
    OscReadNotSupported,
};

// ── Linux / Unix ──────────────────────────────────────────────────────────────

const unix = struct {
    // osc52 is write-only; it has no read counterpart.
    const Tool = enum { wl_clipboard, xclip, xsel, termux, osc52 };

    fn lookPath(allocator: std.mem.Allocator, name: []const u8) bool {
        const path_env = std.posix.getenv("PATH") orelse return false;
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            const full = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
            defer allocator.free(full);
            std.fs.accessAbsolute(full, .{}) catch continue;
            return true;
        }
        return false;
    }

    fn detectTool(allocator: std.mem.Allocator) Tool {
        // Wayland: only try when WAYLAND_DISPLAY is actually set.
        if (std.posix.getenv("WAYLAND_DISPLAY") != null) {
            if (lookPath(allocator, "wl-copy") and lookPath(allocator, "wl-paste"))
                return .wl_clipboard;
        }
        // X11: only try when DISPLAY is set.
        if (std.posix.getenv("DISPLAY") != null) {
            if (lookPath(allocator, "xclip")) return .xclip;
            if (lookPath(allocator, "xsel")) return .xsel;
        }
        // Termux (Android) — no display needed.
        if (lookPath(allocator, "termux-clipboard-get") and
            lookPath(allocator, "termux-clipboard-set")) return .termux;
        // SSH / headless fallback: use OSC 52 terminal escape.
        return .osc52;
    }

    fn readAll(allocator: std.mem.Allocator) ![]u8 {
        const tool = detectTool(allocator);
        if (tool == .osc52) return Error.OscReadNotSupported;
        const argv: []const []const u8 = switch (tool) {
            .wl_clipboard => &.{ "wl-paste", "--no-newline" },
            .xclip => &.{ "xclip", "-out", "-selection", "clipboard" },
            .xsel => &.{ "xsel", "--output", "--clipboard" },
            .termux => &.{"termux-clipboard-get"},
            .osc52 => unreachable,
        };
        return spawnAndRead(allocator, argv);
    }

    fn writeAll(allocator: std.mem.Allocator, text: []const u8) !void {
        const tool = detectTool(allocator);
        if (tool == .osc52) return osc52.writeAll(allocator, text);
        const argv: []const []const u8 = switch (tool) {
            .wl_clipboard => &.{"wl-copy"},
            .xclip => &.{ "xclip", "-in", "-selection", "clipboard" },
            .xsel => &.{ "xsel", "--input", "--clipboard" },
            .termux => &.{"termux-clipboard-set"},
            .osc52 => unreachable,
        };
        return spawnAndWrite(allocator, argv, text);
    }
};

// ── OSC 52 ────────────────────────────────────────────────────────────────────
//
// Sends a terminal escape sequence that instructs the terminal emulator to
// set the clipboard.  Works over SSH as long as the local terminal supports
// OSC 52 (kitty, WezTerm, iTerm2, Alacritty, …).
//
// Sequence:  ESC ] 52 ; c ; <base64-data> BEL
// tmux wrap: ESC P tmux; ESC ESC ] 52 ; c ; <base64-data> BEL ESC \
//
// Data is written to /dev/tty so it reaches the terminal even when stdout
// is redirected (e.g. piped into zcpbuf copy).

const osc52 = struct {
    /// Resolve the file descriptor to write OSC sequences to.
    /// Priority: /dev/tty > stdout (if tty) > stderr (if tty).
    fn openTty() !struct { file: std.fs.File, owned: bool } {
        if (std.fs.openFileAbsolute("/dev/tty", .{ .mode = .write_only })) |f| {
            return .{ .file = f, .owned = true };
        } else |_| {}
        const out = std.fs.File.stdout();
        if (std.posix.isatty(out.handle)) return .{ .file = out, .owned = false };
        const err = std.fs.File.stderr();
        if (std.posix.isatty(err.handle)) return .{ .file = err, .owned = false };
        return error.NoTerminalForOsc52;
    }

    fn writeAll(allocator: std.mem.Allocator, text: []const u8) !void {
        const enc = std.base64.standard.Encoder;
        const encoded_len = enc.calcSize(text.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        defer allocator.free(encoded);
        _ = enc.encode(encoded, text);

        const tty_handle = try openTty();
        defer if (tty_handle.owned) tty_handle.file.close();
        const tty = tty_handle.file;

        if (std.posix.getenv("TMUX") != null) {
            // tmux DCS passthrough: each ESC inside must be doubled.
            try tty.writeAll("\x1bPtmux;\x1b\x1b]52;c;");
            try tty.writeAll(encoded);
            try tty.writeAll("\x07\x1b\\");
        } else {
            try tty.writeAll("\x1b]52;c;");
            try tty.writeAll(encoded);
            try tty.writeAll("\x07");
        }
    }
};

// ── macOS ─────────────────────────────────────────────────────────────────────

const darwin = struct {
    fn readAll(allocator: std.mem.Allocator) ![]u8 {
        return spawnAndRead(allocator, &.{"pbpaste"});
    }

    fn writeAll(allocator: std.mem.Allocator, text: []const u8) !void {
        return spawnAndWrite(allocator, &.{"pbcopy"}, text);
    }
};

// ── Subprocess helpers ────────────────────────────────────────────────────────

fn spawnAndRead(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    try child.spawn();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try output.appendSlice(allocator, buf[0..n]);
    }

    _ = try child.wait();
    return output.toOwnedSlice(allocator);
}

fn spawnAndWrite(allocator: std.mem.Allocator, argv: []const []const u8, text: []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stderr_behavior = .Close;
    try child.spawn();

    try child.stdin.?.writeAll(text);
    child.stdin.?.close();
    child.stdin = null;

    _ = try child.wait();
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Read text from the system clipboard. Caller owns the returned slice.
/// Returns error.OscReadNotSupported when the only available method is OSC 52
/// (e.g. a headless SSH session with no X11/Wayland).
pub fn readAll(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => unix.readAll(allocator),
        .macos => darwin.readAll(allocator),
        else => @compileError("unsupported platform"),
    };
}

/// Write text to the system clipboard.
/// In headless / SSH environments with no X11 or Wayland, falls back to the
/// OSC 52 terminal escape sequence (requires a supporting terminal emulator).
pub fn writeAll(allocator: std.mem.Allocator, text: []const u8) !void {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => unix.writeAll(allocator, text),
        .macos => darwin.writeAll(allocator, text),
        else => @compileError("unsupported platform"),
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "osc52 base64 encoding" {
    const allocator = std.testing.allocator;
    // Verify the base64 payload is correct without needing a real terminal.
    const text = "hello";
    const enc = std.base64.standard.Encoder;
    const buf = try allocator.alloc(u8, enc.calcSize(text.len));
    defer allocator.free(buf);
    const encoded = enc.encode(buf, text);
    try std.testing.expectEqualStrings("aGVsbG8=", encoded);
}

test "copy and paste round-trip" {
    const allocator = std.testing.allocator;
    const expected = "zcpbuf test: 日本語 🦎";

    try writeAll(allocator, expected);
    const actual = try readAll(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}
