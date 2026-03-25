# zcpbuf

A clipboard read/write utility written in Zig, designed to work across platforms and environments — including headless SSH sessions via OSC 52.

## Usage

```sh
# Copy stdin to clipboard
echo "hello" | zcpbuf copy
cat file.txt | zcpbuf copy

# Paste clipboard to stdout
zcpbuf paste
zcpbuf paste > file.txt
```

Commands can be abbreviated: `c` for `copy`, `p` for `paste`.

## Installation

Requires Zig **0.15.2** or later.

```sh
git clone https://github.com/kazto/zcpbuf.git
cd zcpbuf
zig build
# binary is at zig-out/bin/zcpbuf
```

## Platform support

| Platform | Backend |
|---|---|
| Linux / BSD (Wayland) | `wl-copy` / `wl-paste` |
| Linux / BSD (X11) | `xclip` or `xsel` |
| Android (Termux) | `termux-clipboard-get` / `termux-clipboard-set` |
| SSH / headless | OSC 52 terminal escape sequence |
| macOS | `pbcopy` / `pbpaste` |
| Windows | Win32 clipboard API (CF_UNICODETEXT) |

### Backend detection (Linux/BSD)

The backend is selected at runtime in this priority order:

1. `WAYLAND_DISPLAY` set (non-empty) + `wl-copy`/`wl-paste` found → **wl-clipboard**
2. `DISPLAY` set (non-empty) + `xclip` found → **xclip**
3. `DISPLAY` set (non-empty) + `xsel` found → **xsel**
4. Termux binaries found → **termux**
5. Fallback → **OSC 52**

## OSC 52 (SSH / headless)

When no graphical clipboard tool is available, zcpbuf falls back to the [OSC 52](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands) terminal escape sequence, which instructs the terminal emulator to set the system clipboard.

**Supported terminals:** WezTerm, kitty, iTerm2, Alacritty, and others.

> **Note:** OSC 52 is write-only. `zcpbuf paste` is not supported in headless/SSH environments.

### tmux and GNU screen

zcpbuf automatically detects the outer multiplexer and wraps the OSC 52 sequence in the appropriate DCS passthrough:

| Detected by | Multiplexer | Passthrough format |
|---|---|---|
| `$TMUX` set, or `$TERM=tmux-*` | tmux | `ESC P tmux ; ESC ESC ] 52 ; c ; <base64> BEL ESC \` |
| `$STY` set, or `$TERM=screen-*` | GNU screen | `ESC P ESC ESC ] 52 ; c ; <base64> BEL ESC \` |

**For SSH sessions:** even when tmux runs on the *local* machine (not the remote), zcpbuf detects it via the `$TERM` variable (`tmux-256color` or `screen-256color`) that SSH inherits from the outer session.

#### Required tmux configuration

Add to `~/.tmux.conf`:

```
set -g allow-passthrough on
```

## Library usage

`src/root.zig` is exposed as the `zcpbuf` module and can be imported in other Zig projects:

```zig
const zcpbuf = @import("zcpbuf");

// Write to clipboard
try zcpbuf.writeAll(allocator, "hello");

// Read from clipboard (returns error.OscReadNotSupported in headless environments)
const text = try zcpbuf.readAll(allocator);
defer allocator.free(text);
```

## Building and testing

```sh
zig build            # build (output: zig-out/bin/zcpbuf)
zig build run        # build and run
zig build test       # run all tests
zig build run -- copy  # pass arguments via build system
```

## License

MIT
