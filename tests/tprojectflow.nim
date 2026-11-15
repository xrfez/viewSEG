## A project in `core`, without a window (docs/project.md), on synthetic
## SEG-D records and an SPS survey (S, R, X):
##
## - New project with its data folder: a kill made, the survey imported into
##   it (its files copied in, `survey.bin` written), the plot's filters and a
##   display preset kept in it, the run ended;
## - opened again in a new run: the survey is on the map and the file opened
##   is matched to it **without the import and without a survey file opened**
##   (the file system's calls counted), its kill back, its filters and
##   preset back; the data folder's names and times unchanged;
## - a second program opening it meanwhile has it read-only and writes
##   nothing into it;
## - an original that changed (an S file that grew) is said and offered, not
##   taken; "Update from the original" copies it again and the map has the
##   new source; an original gone is no problem: the copy stands for it;
## - Close project: the user's presets and filters are back, and what is
##   remembered without a project is the program's own again;
## - a folder that holds a project.nif, listed as a folder (the Files
##   window, a drop, the command line), opens the project; a data folder
##   never does.
##
## Seen to fail: with `followProject` not called after the drained inbox,
## "the file was not matched to the project's survey"; with the restore
## reading the copies instead of `survey.bin` (`keepSurvey` on open), "a
## survey file was opened: 3"; with `sayOriginals` taking the changed file
## unasked, "the change was taken without asking".

import std/[atomics, os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[filesystem, state]
import utils/[fixtures, waiting]

var surveyOpens: Atomic[int]
var watched: string ## the survey files' names opened are counted

proc countOpens(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    if op == foOpen and watched.len > 0 and path.extractFilename in watched.split(';'):
      surveyOpens.atomicInc

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path == path and
    st.panel(MainPanel).laidOut), "not shown: " & path

proc surveyLayers(st: AppState): int =
  for l in st.survey.layers:
    if l.origin == loSurveyFile: inc result

proc listing(dir: string): seq[(string, Time)] =
  for kind, p in walkDir(dir): result.add (p, getLastModificationTime(p))

withFixtures fx:
  let field = fx.dir / "field"
  createDir(field)
  let record = field / "stations-only.sgd"
  moveFile(fx.stationsSegd(), record)
  let survey = fx.surveySps()
  let job = fx.dir / "Job 7"
  let config = fx.dir / "config"
  let before = listing(field)
  var joined: TraceKeys
  block made:
    var st = start(config)
    st.showFile(record)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field],
      takePresets: true)
    doAssert st.settle(st.inProject and st.projectOpening.len == 0), "the project was not made"
    doAssert fileExists(job / "project.nif") and st.project.doc.data.len == 1
    doAssert st.project.doc.data[0].path == "../field", $st.project.doc.data
    doAssert not st.project.readOnly, st.project.whyReadOnly
    doAssert st.sessions.len == 1, "New project keeps the files open"
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[st.sessions[0].base + 3], on: true)
    let before = st.joinReport.serial
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
      JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
      JoinFile(path: survey.x, kind: jkSps)])
    doAssert st.settle(st.joinReport.serial > before and not st.importing)
    doAssert st.joinReport.outcome == joJoined, $st.joinReport.words
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore),
      "the survey was not kept: " & $st.project.survey & " " & st.project.surveyNote
    for p in [survey.s, survey.r, survey.x]:
      doAssert fileExists(job / "survey" / "files" / p.extractFilename), p
    doAssert st.project.doc.survey[0].original.absolute == survey.s
    joined = st.sessions[0].file.index.keys[5]
    # the project's filters and a preset of its own
    var pr = st.panel(MainPanel).layers[0].processing
    pr.band = pbBandPass
    pr.f3 = 44
    st.apply Command(kind: ckProcessing, panel: MainPanel, processing: pr)
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paSave,
      presetName: "Job look")
    doAssert st.keptSettings.displayPresets.allIt(it.name != "Job look"),
      "the project's preset went into the user's settings"
    doAssert st.keptSettings.plot.processing.f3 != 44, "the project's filters went into the user's"
    st.flushFiles()
    st.shutdown()
  let text = readFile(job / "project.nif")
  doAssert "(f3 44.0)" in text and "\"Job look\"" in text and "survey.s" in text, text

  block reopened:
    watched = "survey.s;survey.r;survey.x"
    surveyOpens.store(0)
    setFsHook(countOpens)
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job / "project.nif")
    doAssert st.settle(st.inProject and st.project.survey == srLoaded), "the project's survey " &
      "did not come: " & $st.project.survey & " " & st.project.surveyNote
    doAssert st.surveyLayers == 3, "the survey is not on the map: " & $st.surveyLayers
    doAssert st.settings.plot.processing.f3 == 44, "the project's filters are not back"
    doAssert st.settings.displayPresets.anyIt(it.name == "Job look"), "its preset is not back"
    st.showFile(record)
    doAssert st.settle(st.joinedOf(st.sessions[0].id) >= 0 and not st.importing),
      "the file was not matched to the project's survey"
    let k = st.sessions[0].file.index.keys[5]
    doAssert k.rcvX == joined.rcvX and k.srcX == joined.srcX and
      k.rcvX != 0, "the keys are not joined as before: " & $k.rcvX
    doAssert st.settle(st.editsOf(0).has(teKilled, 3)), "the kill is not back"
    doAssert surveyOpens.load == 0, "a survey file was opened: " & $surveyOpens.load
    echo "tprojectflow: restored in ", st.project.restoreMs, " ms; ", st.joinReport.words[0]
    # a second program meanwhile: read-only
    var other = start(config)
    other.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert other.settle(other.inProject), "the second program did not open it"
    doAssert other.project.readOnly and "has it open" in other.project.whyReadOnly,
      other.project.whyReadOnly
    let doc = readFile(job / "project.nif")
    other.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paDelete,
      presetName: "Job look")
    other.flushFiles()
    doAssert readFile(job / "project.nif") == doc, "the read-only program wrote the project"
    other.shutdown()
    setFsHook(nil)
    st.shutdown()
  doAssert listing(field) == before, "the data folder changed"

  block changedOriginal:
    var sf = readSps(survey.s)
    var p = sf.points[^1]
    p.point += 1
    p.pointName = ""
    p.easting += 50
    sf.points.add p
    sf.order.setLen 0
    sleep 20 # a later modification time
    doAssert writeSps(sf, survey.s).len == 0
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.project.survey == srLoaded)
    doAssert st.project.originals[0].state == osChanged and st.project.offer,
      $st.project.originals
    let sources = st.project.doc.store.sources
    doAssert sources == Shots, "the change was taken without asking"
    st.apply Command(kind: ckUpdateSurvey)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.store.sources == Shots + 1),
      "the update did not come: " & $st.project.doc.store.sources
    doAssert st.settle(st.project.originals[0].state == osAsCopied and not st.project.offer)
    # an original gone: the copy stands for it, nothing to update
    removeFile(survey.r)
    st.shutdown()
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.project.survey == srLoaded)
    doAssert again.project.originals[1].state == osNotFound and not again.project.offer
    doAssert again.surveyLayers == 3
    # Close project: back to the user's own
    again.apply Command(kind: ckCloseProject)
    doAssert not again.inProject and again.store.home == config / StoreFolder
    doAssert again.settings.displayPresets.allIt(it.name != "Job look")
    doAssert again.settings.plot.processing.f3 != 44 and again.sessions.len == 0
    again.shutdown()

  block listedAsFolder:
    var st = start(config)
    st.apply Command(kind: ckBrowse, paths: @[job])
    doAssert st.settle(st.inProject), "the project's folder listed did not open the project"
    st.shutdown()
    var data = start(config)
    data.apply Command(kind: ckBrowse, paths: @[field])
    doAssert data.settle(not data.fileList.scanning and data.fileList.entries.len == 1)
    doAssert not data.inProject and data.projectOpening.len == 0, "a data folder opened a project"
    data.shutdown()
echo "tprojectflow: done"
