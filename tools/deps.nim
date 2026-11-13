## Dependency tool for viewSEG: the stand-in for Atlas inside the devcontainer.
##
## `atlas.lock` is the source of truth. This tool reads it and keeps `deps/`
## and `nim.cfg` in line with it. It only changes the lock when you run `add`
## or `regen`. It never runs Atlas, and it **never touches a bind-mounted
## dependency**: in the devcontainer, `deps/parseSEG`, `deps/processSEG` and
## `deps/processSEG/deps/parseSEG` are the real repositories, possibly with
## another session's uncommitted work in them.
##
## Usage, from the repository root (or with `--root:DIR` for another Atlas
## project, such as `deps/processSEG`):
##
##   nim r tools/deps.nim status   # each lock entry: locked vs checked-out commit, mounts, dirt
##   nim r tools/deps.nim sync     # clone or check out each unmounted entry at its locked commit
##   nim r tools/deps.nim check    # nim.cfg matches the lock, paths exist, nimble copy current
##   nim r tools/deps.nim regen    # rewrite nim.cfg's Atlas section and the lock's nimble copy
##   nim r tools/deps.nim add <git-url> [--ref:TAG|COMMIT] [--dir:NAME] [--path:SUBDIR] [--dry]
##
## `add` clones the package into `deps/`, pins its commit in the lock, adds its
## module path to the lock and `nim.cfg`, and lists the package's own `requires`
## that the lock does not have yet. Add those the same way (Atlas would have
## resolved them for you; here you choose each version).

import std/[algorithm, json, os, osproc, parseopt, sequtils, strutils]

const
  lockName = "atlas.lock"
  cfgName = "nim.cfg"
  beginMark = "############# begin Atlas config section ##########"
  endMark = "############# end Atlas config section   ##########"

type Ctx = object
  root: string        ## absolute project root
  lock: JsonNode
  mounts: seq[string] ## absolute mount points of this process

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine "deps: ", msg
  quit 1

proc git(args: varargs[string]): tuple[output: string, code: int] =
  ## Runs git with `args`; returns its trimmed output (stdout and stderr) and exit code.
  let cmd = "git " & args.toSeq.mapIt(quoteShell(it)).join(" ")
  let (output, code) = execCmdEx(cmd)
  (output.strip, code)

proc gitOrFail(args: varargs[string]): string =
  let (output, code) = git(args)
  if code != 0:
    fail "git " & args.toSeq.join(" ") & " failed:\n" & output
  output

proc readMounts(): seq[string] =
  ## Mount points from /proc/self/mountinfo (Linux); empty elsewhere.
  if fileExists("/proc/self/mountinfo"):
    for line in lines("/proc/self/mountinfo"):
      let fields = line.split(' ')
      if fields.len > 4:
        result.add fields[4].replace("\\040", " ")

proc isMounted(c: Ctx, dir: string): bool =
  (c.root / dir).normalizedPath in c.mounts

proc dirOf(item: JsonNode): string =
  ## The entry's checkout directory, relative to the project root.
  item["dir"].getStr.replace("$deps", "deps")

proc loadLock(root: string): JsonNode =
  let path = root / lockName
  if not fileExists(path):
    fail "no " & path
  result = parseFile(path)
  if not result.hasKey("items"):
    result["items"] = newJObject()
  if not result.hasKey("nimcfg"):
    result["nimcfg"] = %*[beginMark, "--noNimblePath", endMark, ""]

proc saveLock(c: Ctx) =
  writeFile(c.root / lockName, c.lock.pretty(2))

proc cfgLines(c: Ctx): seq[string] =
  ## The lock's copy of the Atlas section of nim.cfg.
  c.lock["nimcfg"].getElems.mapIt(it.getStr)

proc pathLines(c: Ctx): seq[string] =
  c.cfgLines.filterIt(it.startsWith("--path:"))

proc setPathLines(c: var Ctx, paths: seq[string]) =
  ## Rebuilds the lock's nimcfg from `paths` (sorted, as Atlas writes them).
  var lines = @[beginMark, "--noNimblePath"]
  lines.add paths.deduplicate.sorted
  lines.add [endMark, ""]
  c.lock["nimcfg"] = %lines

proc cfgSection(c: Ctx): seq[string] =
  ## The Atlas section currently in nim.cfg, markers included.
  let path = c.root / cfgName
  if not fileExists(path):
    return
  var inside = false
  for line in lines(path):
    if line == beginMark:
      inside = true
    if inside:
      result.add line
    if line == endMark:
      break
  result.add ""

proc writeCfg(c: Ctx) =
  ## Replaces nim.cfg's Atlas section with the lock's; keeps everything else.
  let path = c.root / cfgName
  let section = c.cfgLines.join("\n")
  var before, after: seq[string]
  var state = 0 # 0 before the section, 1 inside, 2 after
  if fileExists(path):
    for line in lines(path):
      case state
      of 0:
        if line == beginMark: state = 1 else: before.add line
      of 1:
        if line == endMark: state = 2
      else:
        after.add line
  var text = ""
  if before.len > 0: text.add before.join("\n") & "\n"
  text.add section
  if after.len > 0: text.add after.join("\n") & "\n"
  writeFile(path, text)

proc nimbleFile(root: string): string =
  for kind, f in walkDir(root):
    if kind in {pcFile, pcLinkToFile} and f.endsWith(".nimble"):
      return f

proc requiresOf(nimble: string): seq[string] =
  ## The quoted strings of every `requires` statement (multi-line ones too).
  if nimble.len == 0: return
  var inRequires = false
  for raw in lines(nimble):
    let line = raw.strip
    if line.startsWith("requires"):
      inRequires = true
    if inRequires:
      var rest = line
      while true:
        let a = rest.find('"')
        if a < 0: break
        let b = rest.find('"', a + 1)
        if b < 0: break
        result.add rest[a + 1 ..< b]
        rest = rest[b + 1 .. ^1]
      inRequires = line.endsWith(",") or line.endsWith("(")

proc packageOf(req: string): string =
  ## "https://github.com/a/foo >= 1.0" → "foo"; "bar#head" → "bar".
  var name = req.strip
  for sep in [" ", ">", "<", "=", "#", "@", "^", "~"]:
    let i = name.find(sep)
    if i > 0: name = name[0 ..< i]
  name = name.strip(chars = {'/'})
  if name.endsWith(".git"): name.setLen(name.len - 4)
  name.rsplit('/', maxsplit = 1)[^1]

func normName(s: string): string =
  ## Atlas-style directory name: lowercase, without a nim- prefix or -nim suffix.
  result = s.toLowerAscii
  for p in ["nim-", "nim_"]:
    if result.startsWith(p) and result.len > p.len: result = result[p.len .. ^1]
  for p in ["-nim", "_nim", ".nim"]:
    if result.endsWith(p) and result.len > p.len: result.setLen(result.len - p.len)

proc isLocked(c: Ctx, pkg: string): bool =
  let want = pkg.normName
  for key, item in c.lock["items"]:
    if key.normName == want or packageOf(item["url"].getStr).normName == want or
        item.dirOf.lastPathPart.normName == want:
      return true

# ------------------------------------------------------------------ commands --

proc status(c: Ctx) =
  for key, item in c.lock["items"]:
    let dir = item.dirOf
    let locked = item["commit"].getStr
    var line = key.alignLeft(16) & " " & dir.alignLeft(24) & " lock " & locked[0 ..< min(10, locked.len)]
    if not dirExists(c.root / dir / ".git") and not fileExists(c.root / dir / ".git"):
      line.add "  MISSING (run sync)"
    else:
      let head = gitOrFail("-C", c.root / dir, "rev-parse", "HEAD")
      line.add " head " & head[0 ..< 10]
      if c.isMounted(dir):
        let branch = git("-C", c.root / dir, "branch", "--show-current").output
        line.add "  [MOUNTED live repo" & (if branch.len > 0: ", branch " & branch else: "") & "]"
      elif head != locked:
        line.add "  MISMATCH (run sync)"
      if git("-C", c.root / dir, "status", "--porcelain").output.len > 0:
        line.add "  [dirty]"
    echo line

proc sync(c: Ctx) =
  ## Puts every unmounted entry at its locked commit. Never discards local changes.
  for key, item in c.lock["items"]:
    let dir = item.dirOf
    let abs = c.root / dir
    let commit = item["commit"].getStr
    if c.isMounted(dir):
      echo "skip  ", key, ": ", dir, " is a bind mount (the real repository)"
      continue
    if not dirExists(abs / ".git") and not fileExists(abs / ".git"):
      if dirExists(abs) and toSeq(walkDir(abs)).len > 0:
        fail dir & " exists, is not empty and is not a git checkout; move it away first"
      echo "clone ", key, " -> ", dir
      discard gitOrFail("clone", "-q", item["url"].getStr, abs)
    if git("-C", abs, "cat-file", "-e", commit & "^{commit}").code != 0:
      discard gitOrFail("-C", abs, "fetch", "-q", "--tags", "origin")
    let head = gitOrFail("-C", abs, "rev-parse", "HEAD")
    if head == commit:
      echo "ok    ", key
      continue
    if git("-C", abs, "status", "--porcelain").output.len > 0:
      fail dir & " has local changes and is not at the locked commit; commit or move them first"
    discard gitOrFail("-C", abs, "checkout", "-q", "--detach", commit)
    echo "moved ", key, " ", head[0 ..< 10], " -> ", commit[0 ..< 10]

proc nimbleCopyCurrent(c: Ctx): bool =
  let f = nimbleFile(c.root)
  if f.len == 0 or not c.lock.hasKey("nimbleFile"): return true
  let copy = c.lock["nimbleFile"]["content"].getElems.mapIt(it.getStr)
  readFile(f).split('\n') == copy

proc check(c: Ctx): bool =
  ## True when the lock, nim.cfg and deps/ agree; prints every problem.
  result = true
  if c.cfgSection != c.cfgLines:
    echo "nim.cfg's Atlas section differs from the lock's nimcfg (fix: deps regen)"
    result = false
  for p in c.pathLines:
    let dir = p["--path:".len .. ^1].strip(chars = {'"'})
    if not dirExists(c.root / dir):
      echo "missing path ", dir, " (fix: deps sync)"
      result = false
  for key, item in c.lock["items"]:
    let dir = item.dirOf
    if not c.pathLines.anyIt(dir in it):
      echo "entry ", key, " (", dir, ") has no --path line"
      result = false
  if not c.nimbleCopyCurrent:
    echo "the lock's nimbleFile.content is stale (fix: deps regen)"
    result = false
  if result:
    echo "deps: lock, nim.cfg and deps/ agree"

proc regen(c: var Ctx) =
  c.writeCfg
  let f = nimbleFile(c.root)
  if f.len > 0:
    c.lock["nimbleFile"] = %*{"filename": f.lastPathPart,
                              "content": readFile(f).split('\n')}
  c.saveLock
  echo "deps: rewrote nim.cfg's Atlas section and the lock's nimble copy"

proc add(c: var Ctx, url, gitRef, dirArg, pathArg: string, dry: bool) =
  let key = packageOf(url)
  if c.lock["items"].hasKey(key):
    fail key & " is already in the lock; edit its commit by hand, then deps sync"
  let dir = "deps" / (if dirArg.len > 0: dirArg else: key.normName)
  let abs = c.root / dir
  if c.isMounted(dir):
    fail dir & " is a bind mount"
  if dirExists(abs) and toSeq(walkDir(abs)).len > 0:
    fail dir & " already exists"
  discard gitOrFail("clone", "-q", url, abs)
  if gitRef.len > 0:
    discard gitOrFail("-C", abs, "checkout", "-q", "--detach", gitRef)
  let commit = gitOrFail("-C", abs, "rev-parse", "HEAD")
  let tag = git("-C", abs, "describe", "--tags", "--exact-match").output
  # Module root: --path, else the nimble srcDir, else src/ if it has modules, else the root.
  var sub = pathArg
  let nimble = nimbleFile(abs)
  if sub.len == 0 and nimble.len > 0:
    for line in lines(nimble):
      let s = line.strip
      if s.startsWith("srcDir") and '=' in s:
        sub = s.split('=', 1)[1].strip.strip(chars = {'"'})
  if sub.len == 0 and toSeq(walkFiles(abs / "src" / "*.nim")).len > 0:
    sub = "src"
  let modPath = if sub.len > 0 and sub != ".": dir / sub else: dir
  echo "add   ", key, " @ ", commit[0 ..< 10], (if tag.len > 0 and not tag.startsWith(
      "fatal"): " (" & tag & ")" else: ""),
    " -> ", dir, ", --path:\"", modPath, "\""
  var missing: seq[string]
  for req in requiresOf(nimble):
    let pkg = packageOf(req)
    if pkg.toLowerAscii == "nim": continue
    if c.isLocked(pkg) or pkg.normName == key.normName:
      echo "      requires ", req, "  (in the lock)"
    else:
      echo "      requires ", req, "  NOT IN THE LOCK"
      missing.add pkg
  if dry:
    removeDir(abs)
    echo "deps: dry run, nothing written (clone removed)"
    return
  c.lock["items"][key] = %*{"dir": "$deps/" & dir.lastPathPart, "url": url,
                            "commit": commit, "version": ""}
  c.setPathLines(c.pathLines & ("--path:\"" & modPath & "\""))
  c.saveLock
  c.writeCfg
  if missing.len > 0:
    echo "deps: next, add each missing requirement with its git URL (a bare name is in ",
      "https://github.com/nim-lang/packages packages.json): ", missing.join(", ")

proc main() =
  var
    args: seq[string]
    root = currentSourcePath().parentDir.parentDir
    gitRef, dirArg, pathArg: string
    dry = false
  for kind, k, v in getopt():
    case kind
    of cmdArgument: args.add k
    of cmdLongOption, cmdShortOption:
      case k
      of "root": root = v
      of "ref": gitRef = v
      of "dir": dirArg = v
      of "path": pathArg = v
      of "dry": dry = true
      else: fail "unknown option --" & k
    of cmdEnd: discard
  if args.len == 0:
    fail "usage: deps status|sync|check|regen|add <git-url> [--ref:R] [--dir:D] [--path:P] [--dry] [--root:DIR]"
  var c = Ctx(root: absolutePath(root).normalizedPath, mounts: readMounts())
  c.lock = loadLock(c.root)
  case args[0]
  of "status": c.status
  of "sync": c.sync
  of "check":
    if not c.check: quit 1
  of "regen": c.regen
  of "add":
    if args.len < 2: fail "add needs a git URL"
    c.add(args[1], gitRef, dirArg, pathArg, dry)
  else: fail "unknown command " & args[0]

main()
