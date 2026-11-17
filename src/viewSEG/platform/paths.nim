## Where viewSEG keeps its files: settings, logs, the index cache, assets and
## vendor header maps. Standard library only.
##
## **Portable first.** A release is a self-contained folder: when `config/`
## next to the executable exists and is writable, the program runs in portable
## mode and keeps everything it writes there (`config/`, `logs/`, `cache/`).
## Otherwise it uses the per-user directories of the OS:
##
## - Linux (XDG): `$XDG_CONFIG_HOME/viewSEG`, `$XDG_STATE_HOME/viewSEG/logs`,
##   `$XDG_CACHE_HOME/viewSEG`;
## - Windows: `%APPDATA%\viewSEG`, `%LOCALAPPDATA%\viewSEG\logs`,
##   `%LOCALAPPDATA%\viewSEG\cache`;
## - macOS: `~/Library/Application Support/viewSEG`, `~/Library/Logs/viewSEG`,
##   `~/Library/Caches/viewSEG`.
##
## Unset or relative XDG variables fall back to `~/.config`, `~/.local/state` and
## `~/.cache`, as the XDG spec says. With no home directory at all, the folders
## next to the executable are used.
##
## Every rule is a proc over a `PathContext` (the OS, the environment, the
## executable's directory and two file-system predicates), so each OS branch is
## tested on any host. The procs without a context use the real environment;
## `configDir()`, `logDir()` and `cacheDir()` also create their directory.

import std/[os, strutils]

const
  AppName* = "viewSEG"
  AgentSocketName* = "viewSEG.sock" ## agent control's socket, unless a path is given
  VendorPathVar* = "PARSESEG_VENDOR_PATH"
    ## Extra directories of parseSEG vendor header maps, separated like `PATH`.

type
  OsFamily* = enum
    ofLinux, ofWindows, ofMacos ## any other Unix uses the Linux (XDG) rules

  PathContext* = object
    ## Everything the path rules read, so tests can supply their own.
    os*: OsFamily
    appDir*: string                           ## the executable's directory
    env*: proc (name: string): string         ## an environment variable, "" if unset
    isDir*: proc (path: string): bool         ## an existing directory
    isWritableDir*: proc (path: string): bool ## an existing directory we may write to

func sep(os: OsFamily): char =
  if os == ofWindows: '\\' else: '/'

func join(os: OsFamily; parts: varargs[string]): string =
  ## `parts` joined with the target OS's separator, without doubling it.
  result = ""
  for p in parts:
    if p.len == 0:
      discard
    elif result.len == 0:
      result = p
    else:
      if result[^1] notin {'/', '\\'}:
        result.add sep(os)
      result.add p.strip(leading = true, trailing = false, chars = {'/', '\\'})

func isAbsolute(os: OsFamily; path: string): bool =
  if os == ofWindows:
    (path.len >= 3 and path[0] in Letters and path[1] == ':' and path[2] in {'\\', '/'}) or
      path.startsWith("\\\\") or path.startsWith("//")
  else:
    path.startsWith("/")

func parentOf(os: OsFamily; path: string): string =
  ## `path` without its last component (trailing separators ignored).
  let trimmed = path.strip(leading = false, chars = {'/', '\\'})
  let cut = if os == ofWindows: max(trimmed.rfind('/'), trimmed.rfind('\\'))
            else: trimmed.rfind('/')
  if cut <= 0: path else: trimmed[0 ..< cut]

proc home(c: PathContext): string =
  result = c.env(if c.os == ofWindows: "USERPROFILE" else: "HOME")

proc xdg(c: PathContext; name, fallback: string): string =
  ## An XDG base directory: the variable when it is an absolute path, else
  ## `fallback` under the home directory, else "" (no home).
  let v = c.env(name)
  if isAbsolute(c.os, v):
    result = v
  elif c.home.len > 0:
    result = join(c.os, c.home, fallback)
  else:
    result = ""

proc winDir(c: PathContext; name, fallback: string): string =
  ## A Windows known folder from its variable, else under %USERPROFILE%.
  result = c.env(name)
  if result.len == 0 and c.home.len > 0:
    result = join(c.os, c.home, fallback)

proc isPortable*(c: PathContext): bool =
  ## True when `<appDir>/config` exists and is writable: everything the program
  ## writes then stays next to the executable.
  c.isWritableDir(join(c.os, c.appDir, "config"))

proc userDir(c: PathContext; kind: string): string =
  ## The per-user directory for `kind` ("config", "logs" or "cache"), or "" when
  ## the environment names no home.
  case c.os
  of ofLinux:
    let base = case kind
      of "config": c.xdg("XDG_CONFIG_HOME", ".config")
      of "logs": c.xdg("XDG_STATE_HOME", ".local/state")
      else: c.xdg("XDG_CACHE_HOME", ".cache")
    result = if base.len == 0: ""
             elif kind == "logs": join(c.os, base, AppName, "logs")
             else: join(c.os, base, AppName)
  of ofWindows:
    let base = if kind == "config": c.winDir("APPDATA", "AppData\\Roaming")
               else: c.winDir("LOCALAPPDATA", "AppData\\Local")
    result = if base.len == 0: ""
             elif kind == "config": join(c.os, base, AppName)
             else: join(c.os, base, AppName, kind)
  of ofMacos:
    let lib = if c.home.len == 0: "" else: join(c.os, c.home, "Library")
    result = if lib.len == 0: ""
             else:
               case kind
               of "config": join(c.os, lib, "Application Support", AppName)
               of "logs": join(c.os, lib, "Logs", AppName)
               else: join(c.os, lib, "Caches", AppName)

proc dirFor(c: PathContext; kind: string): string =
  ## Portable mode, then the per-user directory, then next to the executable.
  if c.isPortable:
    result = join(c.os, c.appDir, kind)
  else:
    result = c.userDir(kind)
    if result.len == 0:
      result = join(c.os, c.appDir, kind)

proc configDir*(c: PathContext): string =
  ## Settings and recent files.
  c.dirFor("config")

proc logDir*(c: PathContext): string =
  ## Log files.
  c.dirFor("logs")

proc cacheDir*(c: PathContext): string =
  ## parseSEG's index cache and other data that can be rebuilt.
  c.dirFor("cache")

proc existing(c: PathContext; candidates: openArray[string]): seq[string] =
  ## The candidates that are directories, in order, each once.
  result = @[]
  for d in candidates:
    if d.len > 0 and d notin result and c.isDir(d):
      result.add d

proc assetDirs*(c: PathContext): seq[string] =
  ## Read-only asset directories to search, in order: `<appDir>/assets`, then
  ## `<appDir>/../share/viewSEG/assets` (an installed Linux layout), then
  ## `<appDir>/../assets` (development: the binaries are in `bin/`, the assets
  ## in the repository root). Only the ones that exist.
  let parent = parentOf(c.os, c.appDir)
  c.existing([join(c.os, c.appDir, "assets"), join(c.os, parent, "share", AppName, "assets"),
    join(c.os, parent, "assets")])

type VendorSource* = enum
  ## Where a vendor map folder comes from, in the order they are preferred.
  vsUser = "your settings folder"        ## `<configDir>/vendormaps`
  vsProgram = "beside the program"       ## `<appDir>/vendormaps`, and `<appDir>/../vendormaps`
  vsEnvironment = "PARSESEG_VENDOR_PATH" ## the variable's folders

const VendorFolderName = "vendormaps"
  ## the folder of vendor header maps, beside the program and in every project

proc vendorMapCandidates*(c: PathContext): seq[(string, VendorSource, bool)] =
  ## The directories to search for parseSEG vendor header maps (`*.nif`), in
  ## order of preference, each with where it comes from and whether it exists:
  ## the user's own (`<configDir>/vendormaps`), the ones beside the program
  ## (`<appDir>/vendormaps`, then `<appDir>/../vendormaps`: development, as in
  ## `assetDirs`), then each directory in `PARSESEG_VENDOR_PATH`. Each once.
  var candidates: seq[(string, VendorSource)] = @[
    (join(c.os, c.configDir, VendorFolderName), vsUser),
    (join(c.os, c.appDir, VendorFolderName), vsProgram),
    (join(c.os, parentOf(c.os, c.appDir), VendorFolderName), vsProgram)]
  for d in c.env(VendorPathVar).split(if c.os == ofWindows: ';' else: ':'):
    candidates.add (d.strip, vsEnvironment)
  var seen: seq[string] = @[]
  for (d, source) in candidates:
    if d.len > 0 and d notin seen:
      seen.add d
      result.add (d, source, c.isDir(d))

proc vendorMapSources*(c: PathContext): seq[(string, VendorSource)] =
  ## `vendorMapCandidates` that exist.
  for (d, source, there) in c.vendorMapCandidates:
    if there: result.add (d, source)

proc vendorMapDirs*(c: PathContext): seq[string] =
  ## `vendorMapSources` without the sources.
  for (d, _) in c.vendorMapSources: result.add d

proc agentSocket*(c: PathContext): string =
  ## Where agent control's socket goes unless a path is given: next to the
  ## executable when that folder is writable (a build in a repository, a
  ## portable folder: whoever shares the folder, a container too, finds it
  ## there); else in the user's runtime folder (`$XDG_RUNTIME_DIR/viewSEG`,
  ## Linux and macOS); else in the cache folder.
  let runtime = c.env("XDG_RUNTIME_DIR")
  if c.isWritableDir(c.appDir): join(c.os, c.appDir, AgentSocketName)
  elif c.os != ofWindows and isAbsolute(c.os, runtime): join(c.os, runtime, AppName,
    AgentSocketName)
  else: join(c.os, c.cacheDir, AgentSocketName)

# ------------------------------------------------------------ real environment

proc appDir*(): string =
  ## The directory of the running executable.
  getAppDir()

proc writableDir(path: string): bool =
  ## `path` is a directory in which a file can be created (checked by creating
  ## one, which also honours Windows ACLs and read-only mounts).
  result = false
  if dirExists(path):
    let probe = path / (".viewSEG-write-test-" & $getCurrentProcessId())
    try:
      writeFile(probe, "")
      removeFile(probe)
      result = true
    except IOError, OSError:
      result = false

proc getEnvVar(name: string): string = getEnv(name)
proc isDirectory(path: string): bool = dirExists(path)

proc currentContext*(): PathContext =
  ## The context of this process: its OS, environment and executable directory.
  PathContext(
    os: when defined(windows): ofWindows elif defined(macosx): ofMacos else: ofLinux,
    appDir: appDir(), env: getEnvVar, isDir: isDirectory, isWritableDir: writableDir)

proc created(dir: string): string =
  createDir(dir)
  dir

proc configDir*(): string =
  ## The configuration directory of this process, created if missing. Raises
  ## `OSError` when it cannot be created.
  created(currentContext().configDir)

proc logDir*(): string =
  ## The log directory of this process, created if missing.
  created(currentContext().logDir)

proc cacheDir*(): string =
  ## The cache directory of this process, created if missing.
  created(currentContext().cacheDir)

proc assetDirs*(): seq[string] =
  ## The asset search list of this process.
  currentContext().assetDirs

proc vendorMapDirs*(): seq[string] =
  ## The vendor header map search list of this process.
  currentContext().vendorMapDirs

proc vendorMapSources*(): seq[(string, VendorSource)] =
  ## The vendor header map search list of this process, with each folder's source.
  currentContext().vendorMapSources

proc prepareVendorDir*(dir: string; notes: openArray[(string, string)]): bool =
  ## Makes the vendor map folder `dir` if it is not there, and each of `notes`
  ## (file name, text) in it that is not there; never replaces a file. Never
  ## fails: false when the folder is not there at the end (a folder that cannot
  ## be written to is left alone, and the program says nothing of it).
  try:
    createDir(dir)
    for (name, text) in notes:
      # one note, not two: a README.md already there is the note
      if name == "README.txt" and fileExists(dir / "README.md"): continue
      if not fileExists(dir / name): writeFile(dir / name, text)
  except IOError, OSError:
    discard
  result = dirExists(dir)

proc agentSocket*(): string =
  ## Agent control's default socket for this process (`agentSocket(c)`);
  ## nothing is created.
  currentContext().agentSocket
