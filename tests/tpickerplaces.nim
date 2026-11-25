## Where each file or folder picker opens: the folder it was last used in, kept per
## picker by a stable name in the settings. A picker starts at a place the caller
## means when that exists, else at its remembered folder (a parent when the folder
## is gone), else where the caller proposed; a save picker keeps the proposed file
## name. The table survives the settings file; a name no version here uses is kept
## and never asked for; a file from before the table loads with it empty.
##
## Seen to fail: with `remember` replacing the whole table by one entry, `perPicker`
## found the first picker's folder gone; with `nearestFolder` returning the folder
## whether or not it exists, `goneFolder` started in a folder that is not there;
## with the table left out of the settings writer, `roundTrip` read it back empty.

import std/[os, strutils]
import viewSEG/core/[pickerplaces, settings, settingsnif]

proc main*() =
  let tmp = getTempDir() / ("viewseg_tpickerplaces_" & $getCurrentProcessId())
  removeDir(tmp)
  createDir(tmp / "a" / "b")
  createDir(tmp / "c")

  block perPicker:
    var t: seq[PickerPlace]
    t.remember("openFolder", tmp / "a")
    t.remember("importLayout", tmp / "c")
    doAssert t.folderOf("openFolder") == tmp / "a"
    doAssert t.folderOf("importLayout") == tmp / "c"
    t.remember("openFolder", tmp / "a" / "b")
    doAssert t.len == 2 and t.folderOf("openFolder") == tmp / "a" / "b"
    doAssert t.folderOf("shotLog") == ""
    t.remember("", tmp)
    t.remember("shotLog", "")
    doAssert t.len == 2, "an empty name or folder remembers nothing"
    doAssert t.startAt("openFolder", "", false, false) == tmp / "a" / "b" & DirSep
    doAssert t.startAt("shotLog", "/proposed/", false, false) == "/proposed/"

  block goneFolder:
    var t: seq[PickerPlace]
    t.remember("openFolder", tmp / "a" / "b" / "gone" / "deeper")
    doAssert t.startAt("openFolder", "", false, false) == tmp / "a" / "b" & DirSep
    t.remember("openFolder", tmp / "removed")
    doAssert t.startAt("openFolder", "", false, false) == tmp & DirSep

  block explicitAndSave:
    var t: seq[PickerPlace]
    t.remember("exportMissing", tmp / "c")
    # a place the caller means wins while it exists; else the remembered one
    doAssert t.startAt("exportMissing", tmp / "a" & DirSep, true, false) == tmp / "a" & DirSep
    doAssert t.startAt("exportMissing", tmp / "nope" / "x", true, false) == tmp / "c" & DirSep
    # a save picker keeps the proposed name in the remembered folder
    doAssert t.startAt("exportMissing", tmp / "a" / "missing.csv", false, true) ==
      tmp / "c" / "missing.csv"
    # never used: today's proposal
    doAssert t.startAt("exportQuality", tmp / "a" / "q.csv", false, true) == tmp / "a" / "q.csv"

  block roundTrip:
    var s = Settings()
    s.pickerPlaces.remember("openFolder", "/data/line 7")
    s.pickerPlaces.remember("importSettings", r"D:\jobs\settings")
    var problems: seq[string]
    let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert back.pickerPlaces == s.pickerPlaces, $back.pickerPlaces

  block unknownNameIgnored:
    var s = Settings()
    s.pickerPlaces.remember("fromANewerVersion", "/x")
    s.pickerPlaces.remember("openFolder", "/data")
    var problems: seq[string]
    let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert back.pickerPlaces.folderOf("openFolder") == "/data"
    # never asked for: no known picker starts there
    doAssert back.pickerPlaces.startAt("shotLog", "", false, false) == ""

  block oldFileLoads:
    let text = settingsDocument(Settings())
    doAssert "pickerPlaces" notin text
    var problems: seq[string]
    let back = readSettings(text, "settings.nif", Settings(), problems)
    doAssert problems.len == 0 and back.pickerPlaces.len == 0, $problems

  block badEntries:
    var s = Settings()
    s.pickerPlaces.remember("openFolder", "/data")
    let text = settingsDocument(s).replace("(place \"openFolder\" \"/data\")",
      "(place \"openFolder\" \"/data\") (place 5) (place \"x\")")
    var problems: seq[string]
    let back = readSettings(text, "settings.nif", Settings(), problems)
    doAssert problems.len == 2, $problems
    doAssert back.pickerPlaces.len == 1

  removeDir(tmp)
  echo "tpickerplaces: ok"

when isMainModule:
  main()
