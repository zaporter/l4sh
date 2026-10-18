# l4sh: Lean 4 Shell System

A custom shell command system for Lean 4 that allows executing IO actions from within Lean files, with persistent state, session management, and rich Neovim integration.

## Overview

The system consists of:
1. **Shell.lean** - Lean library with shell commands and the `$:` / `$!` elaborators
2. **REPL** - leanprover-community/repl for persistent evaluation
3. **.nvim.lua** - Neovim integration for executing commands and UI
4. **state.lua** - Status bar and nvim-tree synchronization
5. **./l4sh** - Launcher script that sets up sessions

## Architecture

```
┌─────────────────┐     JSON/stdin      ┌──────────────────┐
│  Neovim         │ ◄─────────────────► │  lake exe repl   │
│  .nvim.lua      │                     │  (persistent)    │
└─────────────────┘                     └──────────────────┘
        │                                       │
        │ extracts $: block                     │ evaluates $! command
        │ converts to $!                        │ using preloaded env
        ▼                                       ▼
┌─────────────────┐                     ┌──────────────────┐
│  Session File   │                     │  Shell.lean      │
│  ~/.l4sh/...    │                     │  cd, pwd, etc.   │
│  scratch.lean   │                     │  $: and $! elab  │
└─────────────────┘                     └──────────────────┘
```

## Session Management

### Launcher Script (./l4sh)

The `./l4sh` script creates a session with:
- Session directory: `~/.l4sh/sessions/YYYY-MM-DD/`
- Scratch file: `~/.l4sh/sessions/YYYY-MM-DD/scratch.lean`
- State file: `~/.l4sh/sessions/YYYY-MM-DD/state.json`
- Eval counter: `~/.l4sh/sessions/YYYY-MM-DD/eval_counter`
- Output directory: `~/.l4sh/sessions/YYYY-MM-DD/output/`

Environment variables passed to Neovim:
- `L4SH_SESSION_DIR` - Path to session directory
- `L4SH_PROJECT_ROOT` - Path to the Lean project
- `LEAN_SHELL_STATE` - Path to state.json

### Eval Markers

Each executed command gets a marker on the line above:

```lean
/- ⨕ #1 · 14:32:15 ✓ -/
$: pwd

/- ⨕ #2 · 14:32:20 ✗ -/
$: cd "/nonexistent"
```

Marker format: `/- ⨕ #N · HH:MM:SS [✓/✗] -/`
- `⨕` - Integral around point symbol (distinguishes from regular comments)
- `#N` - Incrementing eval ID
- `HH:MM:SS` - Timestamp of execution
- `✓` - Success
- `✗` - Error

### Eval Counter

The eval counter is stored in a dedicated file (`session_dir/eval_counter`) to avoid conflicts with the state.json file which is written by Lean commands.

### Output Storage

Command output is saved to `session_dir/output/{eval_id}.txt`. This allows:
- Persistent output that survives Neovim restarts
- Cursor-based output display (show output for the command under cursor)
- Re-execution replaces old output

## Shell Commands (Shell.lean)

### Built-in Commands

| Command | Description |
|---------|-------------|
| `cd dir` | Change directory (persists across invocations) |
| `pwd` | Print working directory |
| `touchfile path` | Create/update file with current date |

### Custom Elaborators

**`$:` - LSP-safe shell command**
- Type-checks the IO action but does NOT execute
- Safe to have in files without triggering side effects
- Executes only when `LEAN_EVAL_IO` env var is set to the line number

**`$!` - Always-execute shell command**
- Used by the REPL to execute commands
- Restores persistent cwd before execution

### Persistent State

The current working directory persists between command invocations:
- State file: `$LEAN_SHELL_STATE` (set by l4sh launcher)
- `cd` saves to state file after changing directory
- Commands restore cwd from state file before executing

## REPL Integration

Uses [leanprover-community/repl](https://github.com/leanprover-community/repl) for fast evaluation.

### Why REPL?

| Approach | Startup Time | Per-command Time |
|----------|--------------|------------------|
| `lean --stdin` (cold) | 0ms | ~350ms |
| `lake env lean` | ~500ms | ~350ms |
| Persistent REPL | ~2s (once) | **2-8ms** |

### JSON Protocol

```json
// First command: import modules (slow, done once at startup)
{"cmd": "import L4sh.Shell"}

// Response
{"env": 0}

// Subsequent commands reference the environment
{"cmd": "$! pwd", "env": 0}

// Response with output
{"messages": [{"severity": "info", "data": "/home/user"}], "env": 1}
```

## Neovim Integration (.nvim.lua)

### Startup Behavior

1. Starts `lake exe repl` as background job
2. Sends `import L4sh.Shell` to warm up
3. Shows status bar at bottom with cwd + git info
4. Opens nvim-tree on the left (in l4sh sessions)
5. Initializes last synced cwd for nvim-tree

### UI Layout

```
┌──────────┬─────────────────────────────┬──────────────┐
│ nvim-tree│  scratch.lean               │ [l4sh output]│
│          │                             │              │
│ (files)  │  /- ⨕ #1 · 14:32:15 ✓ -/   │ -- 3ms --    │
│          │  $: pwd                     │ /home/user   │
│          │                             │              │
│          │  /- ⨕ #2 · 14:32:20 ✗ -/   │              │
│          │  $: cd "/nonexistent"       │              │
│          │                             │              │
└──────────┴─────────────────────────────┴──────────────┘
│  ~/projects/ZandC  │  main *                          │
└────────────────────────────────────────────────────────┘
```

### Commands

| Command | Keymap | Description |
|---------|--------|-------------|
| `:LeanShell` | `<leader>le` | Execute `$:` block under cursor |
| `:LeanReload` | `<leader>lr` | Reload definitions |
| `:LeanOutputToggle` | `<leader>lo` | Toggle output panel |
| `:LeanReplRestart` | - | Restart the REPL |
| `:LeanReplStop` | - | Stop the REPL |

### Output Panel Behavior

- Opens on right side when command executes
- Shows output for the `$:` block under cursor
- Moving cursor to different `$:` block switches output
- Moving cursor away from any `$:` block hides panel
- Output persists in files, survives restarts

### nvim-tree Integration

The file tree automatically syncs to the shell's current working directory:
- Only syncs when cwd actually changes (tracked via `last_synced_cwd`)
- Preserves tree width when syncing
- Uses close/reopen approach (more reliable than `change_root`)

### Sign Column

Status dots appear in the gutter next to `$:` lines:
- `●` green - Success
- `●` red - Error
- `○` grey - Pending

## Status Bar (state.lua)

A floating window at the bottom showing:
- Current working directory (from state.json)
- Git branch name
- Dirty indicator (`*`) if uncommitted changes

The status bar:
- Polls state.json every 2 seconds
- Updates immediately after command execution
- Uses extmarks for colored segments

## File Locations

```
L4sh/
├── Shell.lean    -- Shell commands and elaborators
├── repl.lua      -- REPL process management
├── eval.lua      -- Eval markers, block detection, ID counter
├── output.lua    -- Output panel and file storage
├── ui.lua        -- Highlights, signs, extmarks
├── state.lua     -- Status bar and nvim-tree sync
└── STATE_SPEC.md -- State file specification

.nvim.lua         -- Entry point: orchestration, autocmds, keymaps

~/.l4sh/sessions/YYYY-MM-DD/
├── scratch.lean  -- Session scratch file
├── state.json    -- State file (written by Lean)
├── eval_counter  -- Incrementing eval ID counter
└── output/       -- Command output files
    ├── 1.txt
    ├── 2.txt
    └── ...

lakefile.toml     -- Includes repl dependency
l4sh              -- Launcher script
```

## Module Overview

| Module | Purpose |
|--------|---------|
| `repl.lua` | REPL process lifecycle, JSON communication |
| `eval.lua` | Eval markers, block detection, ID counter |
| `output.lua` | Output file storage, right-side panel |
| `ui.lua` | Highlights, signs, extmarks |
| `state.lua` | Status bar, polling, nvim-tree sync |
| `.nvim.lua` | Entry point, ties modules together |

## Dependencies

In `lakefile.toml`:

```toml
[[require]]
name = "repl"
git = "https://github.com/leanprover-community/repl"
rev = "v4.26.0"  # Match your lean-toolchain version
```

## Usage Example

1. Launch with `./l4sh` from project root
2. A session scratch file opens with nvim-tree on left
3. Write shell commands:

```lean
import L4sh.Shell

$: pwd
$: cd "/home/user/projects"
$: do
  pwd
  touchfile "test.txt"
  pwd
```

4. Move cursor to a `$:` line and press `<leader>le`
5. See output in right panel, status in gutter
6. Status bar shows current directory

## References

- [leanprover-community/repl](https://github.com/leanprover-community/repl) - The REPL used for fast evaluation
- [Metaprogramming in Lean 4](https://leanprover-community.github.io/lean4-metaprogramming-book/main/07_elaboration.html) - Elaboration documentation
