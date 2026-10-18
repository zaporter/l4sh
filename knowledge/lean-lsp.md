# Lean LSP Knowledge

## lean.nvim Source Location

On NixOS with home-manager, the plugin is at:
```
/nix/store/gxm7dbc5rwxwvjqjwf3ry3l49n9mihfr-vim-pack-dir/pack/myNeovimPackages/start/lean.nvim/
```

To find it programmatically from within Neovim:
```lua
nvim --headless -c "lua print(vim.inspect(vim.api.nvim_list_runtime_paths()))" -c "q" 2>&1 | tr ',' '\n' | grep -i lean
```

## Key lean.nvim Files

| File | Purpose |
|------|---------|
| `lua/lean/init.lua` | Main setup, commands, keymaps |
| `lua/lean/lsp.lua` | LSP client interaction, `restart_file()` |
| `lua/lean/infoview/` | Infoview panel implementation |
| `lua/lean/commands.lua` | User commands (goal, diagnostics) |
| `lua/std/lsp.lua` | LSP utilities (position conversion, text helpers) |

## How Lean LSP Evaluation Works

1. Neovim sends `textDocument/didChange` on every buffer edit
2. Lean LSP re-processes the entire file, including all `#eval` blocks
3. `#eval` blocks with IO actions execute as side effects during processing

The `restart_file()` function in `lua/lean/lsp.lua` shows how to manually trigger a full re-sync:
```lua
client:notify(ms.textDocument_didClose, { textDocument = { uri = uri } })
client:notify(ms.textDocument_didOpen, {
  textDocument = {
    version = 0,
    uri = uri,
    languageId = 'lean',
    text = full_buffer_text,
  },
})
```

## Direct Lean Evaluation (Bypassing LSP)

Lean 4.27.0 supports `--stdin` for direct evaluation:
```bash
echo '#eval IO.println "hello"' | lake env lean --stdin
```

This can include definitions:
```bash
cat << 'EOF' | lake env lean --stdin
def foo := 42
#eval IO.println s!"foo is {foo}"
EOF
```

Note: `--repl` flag does NOT exist in Lean 4.27.0.

## Controlling LSP Sync in Neovim

Detach LSP from buffer (stops auto-sync):
```lua
vim.lsp.buf_detach_client(bufnr, client.id)
```

Re-attach:
```lua
vim.lsp.buf_attach_client(bufnr, client.id)
```

Get Lean LSP client:
```lua
vim.lsp.get_clients({ name = 'leanls', bufnr = bufnr })
```

## References

- lean.nvim repo: https://github.com/Julian/lean.nvim
- Lean 4 server README: https://github.com/leanprover/lean4/blob/master/src/Lean/Server/README.md
