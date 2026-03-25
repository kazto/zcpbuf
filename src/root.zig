const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    NoClipboardTool,
    OscReadNotSupported,
    ClipboardToolFailed,
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
        // Wayland: only try when WAYLAND_DISPLAY is actually set (non-empty).
        if (std.posix.getenv("WAYLAND_DISPLAY")) |wd| if (wd.len > 0) {
            if (lookPath(allocator, "wl-copy") and lookPath(allocator, "wl-paste"))
                return .wl_clipboard;
        };
        // X11: only try when DISPLAY is set (non-empty).
        if (std.posix.getenv("DISPLAY")) |d| if (d.len > 0) {
            if (lookPath(allocator, "xclip")) return .xclip;
            if (lookPath(allocator, "xsel")) return .xsel;
        };
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

        // Detect the outer multiplexer so we can wrap OSC 52 in the correct
        // DCS passthrough sequence.  Check env vars first (most reliable), then
        // fall back to $TERM which is inherited via SSH from the outer session.
        //   tmux:   $TMUX set, or $TERM starts with "tmux"
        //   screen: $STY  set, or $TERM starts with "screen" (and not tmux)
        const Mux = enum { tmux, screen, none };
        const mux: Mux = blk: {
            if (std.posix.getenv("TMUX")) |v| if (v.len > 0) break :blk .tmux;
            if (std.posix.getenv("STY"))  |v| if (v.len > 0) break :blk .screen;
            if (std.posix.getenv("TERM")) |term| {
                if (std.mem.startsWith(u8, term, "tmux"))   break :blk .tmux;
                if (std.mem.startsWith(u8, term, "screen")) break :blk .screen;
            }
            break :blk .none;
        };
        switch (mux) {
            .tmux => {
                // tmux DCS passthrough: each ESC inside must be doubled.
                // Sequence: ESC P tmux ; ESC ESC ] 52 ; c ; <base64> BEL ESC \
                try tty.writeAll("\x1bPtmux;\x1b\x1b]52;c;");
                try tty.writeAll(encoded);
                try tty.writeAll("\x07\x1b\\");
            },
            .screen => {
                // GNU screen DCS passthrough: same doubling rule, no "tmux;" prefix.
                // Sequence: ESC P ESC ESC ] 52 ; c ; <base64> BEL ESC \
                try tty.writeAll("\x1bP\x1b\x1b]52;c;");
                try tty.writeAll(encoded);
                try tty.writeAll("\x07\x1b\\");
            },
            .none => {
                try tty.writeAll("\x1b]52;c;");
                try tty.writeAll(encoded);
                try tty.writeAll("\x07");
            },
        }
    }
};

// ── Windows ───────────────────────────────────────────────────────────────────
//
// Uses Win32 clipboard API via user32.dll and kernel32.dll.
// Text is exchanged as null-terminated UTF-16LE (CF_UNICODETEXT).
// Follows the same open/lock/unlock/close pattern as the Go reference impl.

const winclip = struct {
    const HANDLE = std.os.windows.HANDLE;
    const BOOL = std.os.windows.BOOL;
    const UINT = std.os.windows.UINT;
    const SIZE_T = std.os.windows.SIZE_T;

    const CF_UNICODETEXT: UINT = 13;
    const GMEM_MOVEABLE: UINT = 0x0002;

    extern "user32" fn IsClipboardFormatAvailable(uFormat: UINT) callconv(.winapi) BOOL;
    extern "user32" fn OpenClipboard(hWndNewOwner: ?*anyopaque) callconv(.winapi) BOOL;
    extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
    extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
    extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?HANDLE;
    extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) callconv(.winapi) ?HANDLE;

    extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: SIZE_T) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;

    /// Try to open the clipboard for up to 1 second (matches Go reference impl).
    fn waitOpenClipboard() !void {
        var i: u32 = 0;
        while (i < 1000) : (i += 1) {
            if (OpenClipboard(null) != 0) return;
            std.Thread.sleep(std.time.ns_per_ms);
        }
        return error.OpenClipboardFailed;
    }

    fn readAll(allocator: std.mem.Allocator) ![]u8 {
        if (IsClipboardFormatAvailable(CF_UNICODETEXT) == 0)
            return error.ClipboardFormatUnavailable;

        try waitOpenClipboard();
        defer _ = CloseClipboard();

        const h = GetClipboardData(CF_UNICODETEXT) orelse
            return error.GetClipboardDataFailed;

        const ptr = GlobalLock(h) orelse return error.GlobalLockFailed;
        defer _ = GlobalUnlock(h);

        const wide: [*:0]const u16 = @ptrCast(@alignCast(ptr));
        const wide_len = std.mem.len(wide);
        return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..wide_len]);
    }

    fn writeAll(allocator: std.mem.Allocator, text: []const u8) !void {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
        defer allocator.free(wide);

        // Allocate global memory: (len + null terminator) × 2 bytes
        const byte_count: SIZE_T = (wide.len + 1) * @sizeOf(u16);

        try waitOpenClipboard();
        defer _ = CloseClipboard();

        if (EmptyClipboard() == 0) return error.EmptyClipboardFailed;

        const h = GlobalAlloc(GMEM_MOVEABLE, byte_count) orelse
            return error.GlobalAllocFailed;
        errdefer _ = GlobalFree(h); // freed only on error; SetClipboardData takes ownership on success

        const ptr = GlobalLock(h) orelse return error.GlobalLockFailed;
        const dst: [*]u16 = @ptrCast(@alignCast(ptr));
        @memcpy(dst[0 .. wide.len + 1], wide.ptr[0 .. wide.len + 1]);
        _ = GlobalUnlock(h);

        if (SetClipboardData(CF_UNICODETEXT, h) == null)
            return error.SetClipboardDataFailed;
        // ownership transferred to the system — suppress errdefer via normal return
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

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ClipboardToolFailed,
        else => return error.ClipboardToolFailed,
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Read text from the system clipboard. Caller owns the returned slice.
/// Returns error.OscReadNotSupported when the only available method is OSC 52
/// (e.g. a headless SSH session with no X11/Wayland).
pub fn readAll(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => unix.readAll(allocator),
        .macos => darwin.readAll(allocator),
        .windows => winclip.readAll(allocator),
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
        .windows => winclip.writeAll(allocator, text),
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
