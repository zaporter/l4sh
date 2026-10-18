# l4sh - Lean 4 Shell

l4sh is an interactive shell environment that uses Lean 4 for command execution, with a custom neovim integration for editing and output display.

## Architecture

### Components

1. **Shell.lean** (`L4sh/Shell.lean`) - Core Lean commands:
   - `sh "cmd"` - Execute shell command with streaming output
   - `shi "cmd"` - Interactive shell with PTY (for vim, htop, etc.)
   - `cd path` - Change directory (persisted to state)
   - `pwd` - Print working directory
   - `$:` - Shell command elaborator that executes IO actions

2. **REPL Worker Pool** (`L4sh/repl.lua`) - Manages multiple `lake exe repl` processes for parallel command execution. Dynamically scales 1-32 workers. Workers receive session-specific env vars (`LEAN_SHELL_STATE`, `L4SH_SESSION_DIR`) so state is saved to the correct session.

3. **Session Management** (`L4sh/session.lua`) - Handles session browsing, creation, and switching via Telescope picker.

4. **Output Panel** (`L4sh/output.lua`) - Right-side panel showing command output, supports streaming and interactive terminals.

5. **State Management** (`L4sh/state.lua`) - Tracks cwd, git info, syncs with nvim-tree.

6. **Tab Management** (`L4sh/tabs.lua`) - Separates l4sh shell view from file editing via vim tabs.

### Session Storage

Sessions are stored in `~/.l4sh/sessions/`:
```
~/.l4sh/sessions/
  2024-03-22_14-30-00/     # Timestamp-named session
    Shell.lean             # Commands and history
    state.json             # cwd, git info
    output/                # Saved command outputs
      1.txt, 2.txt, ...
  my-project/              # Named session
    ...
```

## Usage

### Starting l4sh

```bash
./l4sh              # Open session picker
./l4sh --new        # Create new unnamed session
./l4sh --named foo  # Create named session "foo"
./l4sh --help       # Show help
```

### Session Picker Controls

- `Enter` - Open selected session
- `Ctrl-n` - Create new unnamed session
- `Ctrl-a` - Create new named session
- `Ctrl-d` - Delete session (requires typing "yes")

### Neovim Commands

- `:L4shSessions` - Open session picker / switch sessions
- `:L4shNew` - Create new unnamed session
- `:L4shNewNamed` - Create new named session
- `:LeanShell` - Execute `$:` block under cursor
- `:LeanReload` - Rebuild and reload current file
- `:LeanReplStatus` - Show REPL worker pool status

### Keymaps

**Sessions:**
- `<leader>ls` - Open session picker / switch sessions

**Shell Commands:**
- `Enter` (in Shell.lean) - Execute `$:` block, auto-add new prompt
- `<leader>le` - Execute `$:` under cursor
- `<leader>lr` - Reload definitions

**Tab Navigation:**
- `<leader>ll` - Jump back to l4sh tab (from edit tab)
- `gt` / `gT` - Standard vim tab navigation

**File Finding (opens in edit tab):**
- `<leader>ff` - Find files
- `<leader>fg` - Live grep
- `<leader>fo` - Recent files

**Output & Terminal:**
- `<leader>lo` - Toggle output panel
- `<leader>lt` - Focus terminal (for interactive commands)
- `<Esc><Esc>` (in terminal) - Exit terminal to editor

## Layout

l4sh uses vim tabs to separate the shell view from file editing:

**Tab 1 - l4sh Shell View:**
```
┌──────────┬─────────────────────────────┬──────────────┐
│ nvim-tree│  Shell.lean (60 chars)      │ [l4sh output]│
│          │                             │              │
│ (files)  │  /- ⨕ #1 · 14:32:15 ✓ -/   │ (remaining   │
│          │  $: pwd                     │  space)      │
│          │                             │              │
│          │  $: shi "htop"              │              │
└──────────┴─────────────────────────────┴──────────────┘
│  ~/projects/ZandC  │  main *                          │
└────────────────────────────────────────────────────────┘
```

**Tab 2 - File Editing View:**
```
┌──────────┬─────────────────────────────────────────────┐
│ nvim-tree│  [file buffer]                              │
│          │                                             │
│ (files)  │  (full remaining space for editing)        │
│          │                                             │
└──────────┴─────────────────────────────────────────────┘
```

- Opening files from nvim-tree or telescope creates/switches to the edit tab
- Use `<leader>ll` to jump back to the l4sh tab
- Shell.lean window: Fixed 60 characters wide
- Output panel: Takes remaining space on the right
- Lean infoview: Opens in default position (vertical split)
- Status bar: Shows current directory and git branch

## Eval Markers

Commands are tracked with eval markers:
```lean
/- ⨕ #1 · 14:32:15 ✓ (3ms) -/
$: pwd
```

- `⨕` - Eval marker symbol
- `#1` - Eval ID (links to output file)
- `14:32:15` - Timestamp
- `✓` / `✗` - Success/failure
- `(3ms)` - Duration

## Interactive Commands

Use `shi` for interactive commands that need a PTY:
```lean
$: shi "htop"
$: shi "vim file.txt"
$: shi "python"
```

The terminal opens in the output panel. Use `<Esc><Esc>` to exit back to the editor.
Commands run through `/bin/sh -c` in the Lean session's working directory, using
a Neovim-managed PTY. The command receives the panel's dimensions and resize signals.
Output passes through a compatibility filter that translates ANSI cursor
save/restore sequences into the DEC equivalents supported by Neovim's renderer.
This keeps `docker compose up` menu redraws from clearing the logs. Use
`<leader>lt` to return to the running terminal; `Ctrl-C` is passed to the command.

## Auto-save

Shell.lean automatically saves:
1. Before executing a command
2. After command completion (when marker is updated)

## Working Directory

When you use `cd` in l4sh:
1. The Lean process changes directory (affects `sh`, `pwd`, etc.)
2. State is saved to `state.json`
3. nvim-tree syncs to the new directory
4. Neovim's cwd changes (so telescope, live grep, etc. work in the new directory)

Each session maintains its own working directory, persisted across restarts.

## Direnv

Add the following header after the import in `Shell.lean`:

```lean
import L4sh.Shell
direnv on

$: cd "/path/to/project"
$: direnvAllow
$: sh "echo $DATABASE_URL"
$: shi "docker compose up"

$: do
  cd "../another-project"
  sh "echo $DATABASE_URL"
```

`direnv on` configures the file; it does not execute anything while the editor
type-checks or loads it. Execute the `$:` blocks as usual. When adding or changing
the header in an already loaded session, use `<leader>lr` (`:LeanReload`). Use
`direnv off`, or remove the header and reload, to return to normal execution.

`sh`, `shsimple`, `touchfile`, and `shi` load the environment using
[`direnv exec`](https://direnv.net/man/direnv.1.html) before each command. Direnv
finds the `.envrc` in the current directory or its parents. Commands after l4sh's
`cd` use the new directory, including inside the same `do` block. Leaving a
project restores the inherited environment; switching projects does not carry
the previous project's variables over. Changes to `.envrc` are picked up on the
next command, subject to direnv approval.

An unapproved `.envrc` blocks the shell command and displays direnv's error.
Execute `$: direnvAllow` to explicitly approve the current project's `.envrc`,
or run `direnv allow /path/to/project` in another terminal. l4sh never approves
an environment just by opening a file or changing directory.

Project variables apply to child shell commands. They do not modify Neovim,
the Lean worker, `IO.getEnv`, or arbitrary `IO.Process` calls. Each command gets
its environment independently, so concurrent commands and fresh workers do not
share mutable project environments. `cd` inside a shell string stays local to
that child; use l4sh's `cd` between commands to switch projects. A long-running
`shi` command keeps the environment it started with.

Direnv is included in the Nix package and development shell; other installations
need `direnv` on `PATH`. No bash/zsh prompt hook is required.

Regression tests (isolated temporary environments and approval records):

```sh
lake build L4sh.Shell repl
nvim --headless -u NONE -i NONE -n -c 'luafile tests/direnv.lua'
nvim --headless -u NONE -i NONE -n -c 'luafile tests/terminal.lua'
```

## Lean LSP Integration

Shell.lean files are stored in `~/.l4sh/sessions/` but import from the l4sh project (`import L4sh.Shell`). To make imports resolve correctly even when neovim's cwd is elsewhere:

- `.nvim.lua` overrides `vim.lsp.config('leanls')` with a custom `root_dir` function
- Files in `~/.l4sh/sessions/` use the l4sh project as the LSP root
- Other Lean files use the default behavior (find lakefile)

This allows `cd`-ing to any project while Shell.lean still has working imports and autocomplete.

## Configuration

The layout and behavior are configured in:
- `.nvim.lua` - Project-local neovim config (keymaps, autocmds, LSP root override)
- `L4sh/init.lua` - l4sh plugin setup
- `L4sh/session.lua` - Session management and UI layout
- `L4sh/tabs.lua` - Tab management (l4sh tab vs edit tab)
