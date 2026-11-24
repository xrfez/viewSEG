## The command that writes a loaded shot log as an SPS file: it refuses an
## unknown log, no file name and a name in use (the file keeps its bytes), and
## with a good name starts a job that writes the file the core writer makes for
## the same rows, with the edits made in the log, logs the sentences and keeps
## the outcome line and the file's path. A row the columns cannot hold is
## counted and named, not written.
##
## Seen to fail: with the command doing nothing, "the export wrote no file". With
## the name in use not refused, "the name in use was not refused". With the rows
## taken from the file instead of the edited log, "the edit is not in the file".
## With the left-out rows left out of the outcome, "the outcome does not say a
## row was left out".

import std/[os, strutils]
import parseSEG
import viewSEG/core/[shotlog, shotlogsps]
import viewSEG/core/state {.all.}
import utils/waiting

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true
  false

proc start(): AppState =
  result = initAppState()
  var settings = result.settings
  settings.files.prepareNext = false
  result.apply Command(kind: ckSettings, settings: settings)

proc main*() =
  let dir = getTempDir() / ("viewseg-spscmd-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  let logPath = dir / "shots.csv"
  # The third row has no easting: SPS cannot hold it, so it is left out.
  writeFile(logPath, "point,line,x,y\n1000,10,500.5,2000.5\n1001,10,501.5,2001.5\n" &
    "1002,10,,2002.5\n")
  var map = initShotLogMap()
  map.hasHeader = true
  map.roles = @[crShotPoint, crSourceLine, crX, crY]
  var opts = initShotSpsOptions()
  opts.pointCode = "V1"

  block export_writes_the_file:
    var st = start()
    st.apply Command(kind: ckImportShotLog, logPath: logPath, logMap: map, logMapped: true)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not read"
    let dest = dir / "out" / "shots.sps"
    st.apply Command(kind: ckExportShotSps, spsLog: 5, spsOptions: opts, spsDest: dest)
    doAssert not st.spsRunning and st.said("no such shot log")
    st.apply Command(kind: ckExportShotSps, spsLog: 0, spsOptions: opts, spsDest: "")
    doAssert not st.spsRunning and st.said("no file name")
    # Edit row 0's shot point; the file must carry the edit.
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "1500")
    doAssert st.settle(st.jobs.active.len == 0 and not st.shotLogBusy(0)),
      "the edit did not finish"
    doAssert st.shotView(0).rows[0].shotPoint == 1500.0, "the edit was not made"
    st.apply Command(kind: ckExportShotSps, spsLog: 0, spsOptions: opts, spsDest: dest)
    doAssert st.spsRunning, "the export did not start"
    doAssert st.settle(not st.spsRunning and st.spsOutcome.len > 0),
      "the export did not finish"
    doAssert fileExists(dest), "the export wrote no file: " & st.spsOutcome
    doAssert st.spsWritten == dest.canonical, st.spsWritten
    let want = toSps(st.shotView(0), opts)
    doAssert readFile(dest) == want.text, "the file is not what the core writes"
    let back = readSps(dest, SpsOptions(revision: sps21))
    doAssert back.points.len == 2 and back.points[0].point == 1500.0,
      "the edit is not in the file"
    doAssert "Wrote 2 rows to shots.sps" in st.spsOutcome, st.spsOutcome
    doAssert "1 row was left out" in st.spsOutcome and "row 3 easting is missing" in st.spsOutcome,
      "the outcome does not say a row was left out: " & st.spsOutcome
    doAssert st.said("Wrote 2 rows"), "the sentences are not in the log"
    # A second export to the same name is refused and the file is kept.
    let before = readFile(dest)
    st.apply Command(kind: ckExportShotSps, spsLog: 0, spsOptions: initShotSpsOptions(),
      spsDest: dest)
    doAssert not st.spsRunning and st.said("already exists"), "the name in use was not refused"
    doAssert readFile(dest) == before, "an existing file was replaced"
    discard st.shutdown()

  block nothing_to_write:
    var st = start()
    let only = dir / "blank.csv"
    writeFile(only, "point,x,y\n,1,2\n")
    var m = initShotLogMap()
    m.hasHeader = true
    m.roles = @[crShotPoint, crX, crY]
    st.apply Command(kind: ckImportShotLog, logPath: only, logMap: m, logMapped: true)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    let dest = dir / "blank.sps"
    st.apply Command(kind: ckExportShotSps, spsLog: 0, spsOptions: opts, spsDest: dest)
    doAssert st.settle(not st.spsRunning and st.spsOutcome.len > 0)
    doAssert st.spsOutcome.startsWith("The SPS export failed"), st.spsOutcome
    doAssert not fileExists(dest) and st.spsWritten.len == 0
    discard st.shutdown()

when isMainModule:
  main()
