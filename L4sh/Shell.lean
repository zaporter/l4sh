import Lean
import Lean.Data.Json

open Lean Json

-- State file for persistent state (path comes from LEAN_SHELL_STATE env var)
def getStateFile : IO System.FilePath := do
  match ← IO.getEnv "LEAN_SHELL_STATE" with
  | some path => pure path
  | none => pure "/tmp/lean_shell_state.json"

-- Git info structure
structure GitInfo where
  branch : String
  dirty : Bool
  deriving ToJson, FromJson

-- Full state structure
structure ShellState where
  version : Nat := 1
  cwd : String
  files : List String
  git : Option GitInfo
  deriving ToJson, FromJson

-- Get git branch and dirty status
def getGitInfo (dir : System.FilePath) : IO (Option GitInfo) := do
  let branchResult ← IO.Process.output {
    cmd := "git"
    args := #["-C", dir.toString, "branch", "--show-current"]
  }
  if branchResult.exitCode != 0 then return none
  let branch := branchResult.stdout.trimAscii.toString
  if branch.isEmpty then return none

  let statusResult ← IO.Process.output {
    cmd := "git"
    args := #["-C", dir.toString, "status", "--porcelain"]
  }
  let dirty := !statusResult.stdout.isEmpty
  return some { branch, dirty }

-- Get files in directory
def getFiles (dir : System.FilePath) : IO (List String) := do
  let entries ← dir.readDir
  let names := entries.map (·.fileName) |>.toList
  return names.mergeSort (· < ·)

-- Save full state as JSON
def saveState : IO Unit := do
  let stateFile ← getStateFile
  let cwd ← IO.Process.getCurrentDir
  let files ← getFiles cwd
  let git ← getGitInfo cwd
  let state : ShellState := { cwd := cwd.toString, files, git }
  IO.FS.writeFile stateFile (toJson state).pretty

-- Restore cwd from state file
def restoreCwd : IO Unit := do
  let stateFile ← getStateFile
  if ← stateFile.pathExists then
    let contents ← IO.FS.readFile stateFile
    match Json.parse contents with
    | .error _ => pure ()
    | .ok json =>
      match fromJson? json with
      | .error _ => pure ()
      | .ok (state : ShellState) =>
        if state.cwd.length > 0 then
          IO.Process.setCurrentDir state.cwd

-- cd changes directory and saves state
def cd (dir: System.FilePath) : IO Unit := do
  IO.Process.setCurrentDir dir
  saveState


-- Get streaming output file path from session directory
def getStreamFile : IO (Option System.FilePath) := do
  match ← IO.getEnv "L4SH_SESSION_DIR" with
  | some dir => pure (some (dir ++ "/stream.txt"))
  | none => pure none

partial def sh (cmd: String): IO Unit := do
  -- Merge stderr into stdout with 2>&1 to preserve output order
  let child ← IO.Process.spawn {
    cmd := "/bin/sh"
    args := #["-c", cmd ++ " 2>&1"]
    stdout := .piped
    stderr := .null
  }

  let out ← IO.getStdout
  let streamFile ← getStreamFile

  -- Clear stream file at start
  if let some path := streamFile then
    IO.FS.writeFile path ""

  -- Stream output line by line
  let rec readLoop : IO Unit := do
    let line ← child.stdout.getLine
    if line.isEmpty then return
    -- Write to stream file for live updates (bypasses REPL capture)
    if let some path := streamFile then
      let h ← IO.FS.Handle.mk path .append
      h.putStr line
      h.flush
    -- Also write to stdout for final REPL response
    out.putStr line
    out.flush
    readLoop
  readLoop

  let exitCode ← child.wait
  if exitCode != 0 then
    throw <| IO.userError s!"Command failed with exit code {exitCode}"

def touchfile (filename: String): IO Unit := do
  let output ← IO.Process.run {cmd := "/bin/sh", args := ["-c", s!"date > {filename}"].toArray :IO.Process.SpawnArgs}
  (← IO.getStdout).putStrLn output
  saveState  -- Update state after file operation

def shsimple (cmd: String): IO Unit := do
  let output ← IO.Process.run {cmd := "/bin/sh", args := ["-c", cmd].toArray :IO.Process.SpawnArgs}
  (← IO.getStdout).putStrLn output
  saveState  -- Update state after file operation

def pwd : IO Unit := do
  let pwd ← IO.Process.getCurrentDir
  (← IO.getStdout).putStrLn pwd.toString

-- Ask Neovim to run the command in its own PTY, so terminal dimensions,
-- resize signals, input, and exit status reach the command directly.
def shi (cmd: String): IO Unit := do
  let cwd ← IO.Process.getCurrentDir
  let request := Json.mkObj [("__l4sh_terminal__", Json.mkObj [
    ("cmd", toJson cmd), ("cwd", toJson cwd.toString)])]
  (← IO.getStdout).putStrLn request.compress

open Lean Elab Command Term Meta

-- Target line for $: execution (set by REPL before sending code)
initialize evalLine : IO.Ref (Option Nat) ← IO.mkRef none

-- Command to set which line to execute
elab "#eval_line" n:num : command => do
  evalLine.set (some n.getNat)

-- Shell command elaborator
-- Executes only if evalLine matches this block's line range
elab stx:"$:" t:term : command => do
  -- Always elaborate the term first (required for type-checking)
  let e ← liftTermElabM do
    let expectedType ← elabTerm (← `(IO Unit)) none
    let e ← elabTerm t (some expectedType)
    synthesizeSyntheticMVarsNoPostponing
    instantiateMVars e

  -- Check if we should execute
  let target? ← evalLine.get
  match target? with
  | some target =>
    -- Get line range of this $: block
    let fileMap ← getFileMap
    let startLine := match stx.getPos? with
      | some p => (fileMap.toPosition p).line
      | none => 0
    let endLine := match t.raw.getTailPos? with
      | some p => (fileMap.toPosition p).line
      | none => startLine

    if startLine <= target && target <= endLine then
      -- Restore cwd from previous session before executing
      restoreCwd
      let action ← liftTermElabM do
        let expectedType ← elabTerm (← `(IO Unit)) none
        unsafe Meta.evalExpr (IO Unit) expectedType e
      action
      -- Save state after execution
      saveState
      -- Clear evalLine after execution
      evalLine.set none
  | none =>
    pure ()
