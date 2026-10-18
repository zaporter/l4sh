# l4sh
A Lean 4 shell

Enable project environments by adding `direnv on` below the import in your
session's `Shell.lean`:

```lean
import L4sh.Shell
direnv on

$: cd "/path/to/project"
$: direnvAllow -- Run once when you want to approve this project's .envrc
$: sh "echo $DATABASE_URL"
$: shi "docker compose up"
```

Execute each `$:` block with Enter. If the session is already loaded, press
`<leader>lr` after adding or changing the header. Subsequent shell commands load
the environment for the current directory, including after `cd` to another
project or back out. See [direnv usage and behavior](knowledge/l4sh.md#direnv).
