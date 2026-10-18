# L4sh State Specification

This document describes the state files and communication mechanisms used by l4sh.

## Session Directory Structure

Each l4sh session creates a directory at `~/.l4sh/sessions/YYYY-MM-DD/`:

```
~/.l4sh/sessions/2024-03-21/
├── scratch.lean      # Session scratch file (opened in Neovim)
├── state.json        # State file (written by Lean, read by Neovim)
├── eval_counter      # Incrementing eval ID (written by Neovim)
└── output/           # Command output files
    ├── 1.txt         # Output from eval #1
    ├── 2.txt         # Output from eval #2
    └── ...
```

## State File (state.json)

Written by Lean shell commands, read by Neovim for status bar and nvim-tree sync.

### Structure

```json
{
  "version": 1,
  "cwd": "/home/user/project",
  "files": ["foo.txt", "bar.lean"],
  "git": {
    "branch": "main",
    "dirty": true
  },
  "output": {
    "stdout": "command output here",
    "stderr": "",
    "exit_code": 0
  },
  "history": [
    {
      "cmd": "pwd",
      "cwd": "/home/user",
      "timestamp": 1710000000,
      "exit_code": 0
    }
  ],
  "env": {
    "FOO": "bar"
  }
}
```

### Fields

#### Core State
- `version` (int): Schema version for forward compatibility
- `cwd` (string): Current working directory

#### Git State (optional)
- `git.branch` (string | null): Current branch name, null if not in repo
- `git.dirty` (bool): True if there are uncommitted changes

#### Command Output (optional)
- `output.stdout` (string): Last command's stdout
- `output.stderr` (string): Last command's stderr
- `output.exit_code` (int): Last command's exit code

#### History (optional)
- `history` (array): Recent commands for context

#### Environment (optional)
- `env` (object): Custom environment variables to persist

### Lifecycle

1. **Lean command starts**: Read state, restore cwd
2. **During execution**: Update output fields
3. **Lean command ends**: Write final state (cwd, git info)
4. **Neovim reads**: Poll every 2s + refresh after command execution

## Eval Counter File (eval_counter)

A simple text file containing a single integer - the last used eval ID.

### Why a Separate File?

The state.json is written by Lean commands and would overwrite any eval ID stored there. The eval counter is written only by Neovim, avoiding conflicts.

### Format

Plain text containing a single integer:
```
42
```

### Usage

1. Neovim reads current value (or 0 if file doesn't exist)
2. Increments by 1
3. Writes new value back
4. Uses the new value as the eval ID for the command

## Output Files (output/{id}.txt)

Each command execution saves its output to a numbered file.

### Format

Plain text with the command output:
```
-- 3ms --
/home/user/project
```

The first line is always a timing comment (`-- Nms --`).

### Lifecycle

1. Command executes, Neovim receives response from REPL
2. Output saved to `output/{eval_id}.txt`
3. When cursor moves to a `$:` line, Neovim reads the corresponding output file
4. Re-executing a command deletes old output file before saving new one

## Eval Markers (in .lean files)

Markers are inserted directly into the Lean source file, on the line above the `$:` command.

### Format

```
/- ⨕ #N · HH:MM:SS [✓/✗] -/
```

- `/- ... -/` - Lean block comment (doesn't comment out the command below)
- `⨕` - Integral around point symbol (Unicode U+2A15, distinguishes from regular comments)
- `#N` - Eval ID (incrementing integer)
- `HH:MM:SS` - Timestamp of execution
- `✓` - Success indicator (present only if command succeeded)
- `✗` - Error indicator (present only if command failed)

### Examples

```lean
/- ⨕ #1 · 14:32:15 ✓ -/
$: pwd

/- ⨕ #2 · 14:32:20 ✗ -/
$: cd "/nonexistent"

/- ⨕ #3 · 14:32:25 -/
$: do
  pwd
  cd "/tmp"
```

### Marker States

1. **Pending** (no status char): Command is executing
2. **Success** (`✓`): Command completed without errors
3. **Error** (`✗`): Command had errors (severity: error in REPL response)

## Neovim State

Neovim state is distributed across modules:

### repl.lua
- `job` - REPL job handle
- `env` - Current REPL environment index
- `pending_callback` - Callback for current request

### eval.lua
- `session_dir` - Path to session directory
- `MARKER` - The ⨕ symbol constant

### output.lua
- `dir` - Output directory path
- `win`, `buf` - Output panel window/buffer
- `current_id` - Currently displayed eval ID

### state.lua
- `status_win`, `status_buf` - Status bar floating window
- `last_synced_cwd` - Prevents unnecessary nvim-tree resyncs
- `poll_timer` - Timer for status bar updates

## Environment Variables

Set by the `./l4sh` launcher script:

| Variable | Description |
|----------|-------------|
| `L4SH_SESSION_DIR` | Path to session directory |
| `L4SH_PROJECT_ROOT` | Path to the Lean project |
| `LEAN_SHELL_STATE` | Path to state.json |

Neovim reads these via:
```lua
vim.g.l4sh_session_dir  -- Set by launcher before starting nvim
vim.g.l4sh_project_root
```

## Communication Flow

```
┌───────────────────────────────────────────────────────────────────────┐
│                              Neovim                                   │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────────┐  │
│  │ .nvim.lua  │  │ repl.lua   │  │ eval.lua   │  │ output.lua     │  │
│  │ (orchestr) │  │ (REPL I/O) │  │ (markers)  │  │ (panel/files)  │  │
│  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘  └───────┬────────┘  │
│        │               │               │                 │           │
│        │               │               │    eval_counter │           │
│        │               │               │    (read/write) │           │
│  ┌─────┴──────┐  ┌─────┴──────┐                    ┌─────┴────────┐  │
│  │ state.lua  │  │ ui.lua     │                    │ output/*.txt │  │
│  │ (status)   │  │ (signs)    │                    │ (read/write) │  │
│  └─────┬──────┘  └────────────┘                    └──────────────┘  │
│        │                                                             │
└────────┼─────────────────────────────────────────────────────────────┘
         │
         │ Read (poll)
         ▼
┌─────────────────┐         ┌─────────────────┐
│ state.json      │◄────────│ lake exe repl   │
│ (cwd, git)      │  write  │ Shell.lean      │
└─────────────────┘         └─────────────────┘
```

## Future Extensions

- `jobs`: Background job tracking
- `aliases`: User-defined command aliases
- `prompt`: Custom prompt configuration
- `completions`: Dynamic completion hints
- `bookmarks`: Saved directory bookmarks
