## The path rules of `platform/paths` for every OS, run on any host through
## `PathContext`: portable mode, per-user directories, fallbacks, search lists.

import std/[os, strutils, tables]
import viewSEG/platform/paths

proc context(os: OsFamily; appDir: string; vars: openArray[(string, string)];
    dirs: openArray[string] = []; writable: openArray[string] = []): PathContext =
  ## A context whose environment is `vars`, whose existing directories are
  ## `dirs` plus `writable`, and whose writable ones are `writable`.
  let
    env = vars.toTable
    existing = @dirs & @writable
    canWrite = @writable
  PathContext(os: os, appDir: appDir,
    env: proc (name: string): string = env.getOrDefault(name),
    isDir: proc (path: string): bool = path in existing,
    isWritableDir: proc (path: string): bool = path in canWrite)

block linuxXdg:
  let c = context(ofLinux, "/opt/viewSEG/bin", {"HOME": "/home/u",
    "XDG_CONFIG_HOME": "/cfg", "XDG_STATE_HOME": "/state", "XDG_CACHE_HOME": "/cache"})
  doAssert not c.isPortable
  doAssert c.configDir == "/cfg/viewSEG", c.configDir
  doAssert c.logDir == "/state/viewSEG/logs", c.logDir
  doAssert c.cacheDir == "/cache/viewSEG", c.cacheDir

block linuxDefaultsAndRelativeXdg:
  # Unset or relative XDG variables are ignored (XDG base directory spec).
  let c = context(ofLinux, "/opt/viewSEG/bin", {"HOME": "/home/u/", "XDG_CONFIG_HOME": "rel"})
  doAssert c.configDir == "/home/u/.config/viewSEG", c.configDir
  doAssert c.logDir == "/home/u/.local/state/viewSEG/logs", c.logDir
  doAssert c.cacheDir == "/home/u/.cache/viewSEG", c.cacheDir

block linuxNoHome:
  let c = context(ofLinux, "/opt/v", {"XDG_CACHE_HOME": "/c"})
  doAssert c.configDir == "/opt/v/config", c.configDir
  doAssert c.logDir == "/opt/v/logs"
  doAssert c.cacheDir == "/c/viewSEG"

block windows:
  let c = context(ofWindows, r"C:\Program Files\viewSEG", {"USERPROFILE": r"C:\Users\u",
    "APPDATA": r"C:\Users\u\AppData\Roaming", "LOCALAPPDATA": r"D:\Local"})
  doAssert c.configDir == r"C:\Users\u\AppData\Roaming\viewSEG", c.configDir
  doAssert c.logDir == r"D:\Local\viewSEG\logs", c.logDir
  doAssert c.cacheDir == r"D:\Local\viewSEG\cache", c.cacheDir

block windowsWithoutKnownFolderVars:
  let c = context(ofWindows, r"C:\viewSEG", {"USERPROFILE": r"C:\Users\u"})
  doAssert c.configDir == r"C:\Users\u\AppData\Roaming\viewSEG", c.configDir
  doAssert c.cacheDir == r"C:\Users\u\AppData\Local\viewSEG\cache", c.cacheDir

block macos:
  let c = context(ofMacos, "/Applications/viewSEG.app/Contents/MacOS", {"HOME": "/Users/u",
    "XDG_CONFIG_HOME": "/ignored"})
  doAssert c.configDir == "/Users/u/Library/Application Support/viewSEG", c.configDir
  doAssert c.logDir == "/Users/u/Library/Logs/viewSEG", c.logDir
  doAssert c.cacheDir == "/Users/u/Library/Caches/viewSEG", c.cacheDir

block portable:
  for (os, app, cfg) in [(ofLinux, "/r/viewSEG", "/r/viewSEG/config"),
      (ofWindows, r"E:\viewSEG", r"E:\viewSEG\config"),
      (ofMacos, "/r/viewSEG", "/r/viewSEG/config")]:
    let c = context(os, app, {"HOME": "/h", "USERPROFILE": r"C:\h", "APPDATA": r"C:\a"},
      writable = [cfg])
    doAssert c.isPortable, $os
    doAssert c.configDir == cfg, c.configDir
    doAssert c.logDir.endsWith("logs") and c.logDir.startsWith(app), c.logDir
    doAssert c.cacheDir.endsWith("cache") and c.cacheDir.startsWith(app), c.cacheDir

block portableNeedsWritableConfig:
  # A read-only config/ next to the executable (e.g. under Program Files) is
  # not portable mode.
  let c = context(ofLinux, "/r", {"HOME": "/h"}, dirs = ["/r/config"])
  doAssert not c.isPortable
  doAssert c.configDir == "/h/.config/viewSEG"

block assetDirsInOrder:
  let none = context(ofLinux, "/usr/bin", {"HOME": "/h"})
  doAssert none.assetDirs.len == 0
  let c = context(ofLinux, "/usr/bin", {"HOME": "/h"},
    dirs = ["/usr/share/viewSEG/assets", "/usr/bin/assets"])
  doAssert c.assetDirs == @["/usr/bin/assets", "/usr/share/viewSEG/assets"], $c.assetDirs
  let w = context(ofWindows, r"C:\v\bin", {"USERPROFILE": r"C:\u"},
    dirs = [r"C:\v\share\viewSEG\assets"])
  doAssert w.assetDirs == @[r"C:\v\share\viewSEG\assets"], $w.assetDirs

block vendorMapDirsInOrder:
  let c = context(ofLinux, "/r", {"HOME": "/h",
    "PARSESEG_VENDOR_PATH": "/x/maps::/missing:/r/vendormaps"},
    dirs = ["/r/vendormaps", "/x/maps", "/h/.config/viewSEG/vendormaps"])
  # user's own, shipped, then the variable; missing and repeated ones dropped
  doAssert c.vendorMapDirs == @["/h/.config/viewSEG/vendormaps", "/r/vendormaps", "/x/maps"],
    $c.vendorMapDirs
  let p = context(ofWindows, r"E:\v", {"PARSESEG_VENDOR_PATH": r"F:\maps;G:\none"},
    dirs = [r"E:\v\vendormaps", r"F:\maps"], writable = [r"E:\v\config",
    r"E:\v\config\vendormaps"])
  doAssert p.vendorMapDirs == @[r"E:\v\config\vendormaps", r"E:\v\vendormaps", r"F:\maps"],
    $p.vendorMapDirs

block realEnvironment:
  # The host's own context: directories are created on demand under a
  # temporary XDG / known-folder root, never in the user's real ones.
  let root = getTempDir() / ("viewseg_tpaths_" & $getCurrentProcessId())
  for v in ["XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "APPDATA",
      "LOCALAPPDATA", "HOME"]:
    putEnv(v, root / v)
  try:
    doAssert appDir() == getAppDir()
    let dirs = [configDir(), logDir(), cacheDir()]
    for d in dirs:
      doAssert d.startsWith(root) and dirExists(d), d
    doAssert dirs[0].endsWith("viewSEG"), dirs[0]
    doAssert assetDirs().len == 0 or assetDirs()[0].startsWith(appDir())
    createDir(dirs[0] / "vendormaps")
    doAssert vendorMapDirs()[0] == dirs[0] / "vendormaps", $vendorMapDirs()
  finally:
    removeDir(root)
