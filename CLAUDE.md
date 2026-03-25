# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
zig build            # Build (outputs to zig-out/)
zig build run        # Build and run the CLI
zig build test       # Run all tests (module + executable tests in parallel)
zig build run -- arg1 arg2  # Run with arguments
```

Minimum Zig version: **0.15.2**

## Architecture

`zcpbuf` is a Zig clipboard buffer utility structured as two modules:

- **`src/root.zig`** — the library module (`zcpbuf`). Public API exposed to consumers and to the CLI. This is the right place for clipboard buffer logic.
- **`src/main.zig`** — the CLI entry point. Imports the `zcpbuf` module and wires it to a user-facing interface. Intentionally thin.

The build (`build.zig`) exposes `src/root.zig` as a named module (`zcpbuf`) that is both published for external consumers and imported by the executable. Tests run separately for the library module and the executable module.

### Clipboard backend detection (Unix/Linux)

`detectTool` selects a backend at runtime in this priority order:

| Condition | Backend |
|---|---|
| `WAYLAND_DISPLAY` set + `wl-copy`/`wl-paste` found | `wl_clipboard` |
| `DISPLAY` set + `xclip` found | `xclip` |
| `DISPLAY` set + `xsel` found | `xsel` |
| Termux binaries found | `termux` |
| Fallback (SSH / headless) | `osc52` |

**OSC 52** (`src/root.zig` → `osc52` namespace) is write-only. It sends the terminal escape sequence `ESC ] 52 ; c ; <base64> BEL` to the terminal device, which is resolved in order: `/dev/tty` → stdout (if tty) → stderr (if tty). Inside tmux the sequence is wrapped in a DCS passthrough. `readAll` returns `error.OscReadNotSupported` when OSC 52 is the only available backend.

## Reference Implementation

`references/clipboard/` contains a Go clipboard library used as a design reference. Consult it when implementing platform-specific clipboard access (Darwin, Unix via xsel/xclip, Windows, Plan 9).
