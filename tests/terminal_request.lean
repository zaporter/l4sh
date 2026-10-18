import L4sh.Shell

def main (args : List String) : IO Unit := do
  match args with
  | [cwd, cmd] =>
    IO.Process.setCurrentDir cwd
    shi cmd
  | _ => throw <| IO.userError "expected working directory and command"
