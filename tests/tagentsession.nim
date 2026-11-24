## What an agent changes is for the session only, without a window: the
## commands go through the `command` tool (`runCommand`), as agent control
## gives them, and the settings are saved in a folder of their own.
##
## - every setting decided: the settings the settings file holds (every
##   field of `Settings`, a new plot's display field by field) are those
##   listed in `Reached`, each with the command an agent gives that changes
##   it for the session, or none; a setting added later fails here until
##   someone decides;
## - every kind of command an agent may give (`Offered`, all of them) given
##   in turn, with values that change all they can: each setting listed
##   with a command is changed for the session (the plot shows what the
##   agent asked for) and none of those kept; the settings file is as it
##   was, byte for byte, and a restart reads the settings from before; the
##   settings listed with none are not changed even for the session; the
##   agent's trace edits (kill, reverse all, undo, redo) leave nothing in
##   what is remembered about files; the log still says what the agent's
##   commands did;
## - the same changes made through a window are kept, saved and read again
##   at the next start;
## - a window's change after an agent's is kept with the user's value only:
##   a new display mode keeps the user's gain, not the agent's; a change of
##   the status bar's fields does not carry the agent's sort; Clear recent
##   clears what the user had; an agent's arrangement of the windows is not
##   saved, the user's is;
## - `carried`: field by field in a new plot's display, a list whole, a
##   value that is not a number equal to itself.
##
## Seen to fail: with `keeps` true for agents, "the agent's \"open\" reached
## recentFiles, which is saved"; with `keeps` false for windows, "what the
## user did by hand was not saved"; with the command tool not marking its
## commands as an agent's, the same as the first; with the open's origin not
## carried to its end (`adopt` taking every open as a window's), and with
## the listing's not carried (the file it shows first), "... reached
## recentFiles" (and with a prepared file's show not carrying it, the same,
## for third.sgy); with `ckDisplay` keeping the whole display (`s.plot.display
## = remembered(d)`), "the user's new mode kept the agent's gain: normalized";
## with `ckSettings` keeping what the window sent whole, "the user's status
## bar fields kept the agent's sort"; with `settleGain` keeping the data's
## Fixed amplitude whatever the kept gain, "the agent's \"display\" reached
## plot.display.fixedClip"; with a field `gadget` added to `Settings`, "a
## setting nobody has decided on: gadget"; with `editTraces` keeping an
## agent's edits (`keep = true`), "the agent's edits are remembered"; without `treated` in the
## file list's entries, the agent's kind could not be read back (a key error).

import std/[json, math, options, os, sequtils, strutils, tables]
import parseSEG
import viewSEG/core/[analysis, breakmodel, colourmaps, geometry, nif, outputtext, phasepicture,
  plotoptions, project, recordingkind, state, treatas]
import viewSEG/remote/[schema, tools]
import utils/[fixtures, waiting]

# Every setting the settings file holds, with the command an agent may give
# that changes it for the session, or "" when none does (not even for the
# session). A setting added to `Settings` fails until it is put here: by the
# command that reaches it (and this test then shows it is not saved), or ""
# (and this test shows no command reaches it). A new plot's display is
# always shown (`remembered`); its Fixed amplitude an agent's display command
# also changes through the data it shows (`settleGain`). An agent's join
# gives its own options: the join's settings are the window's. So are the
# Headers window's (its tabs, toggles and columns): an agent's `headers
# shown` says what its reader reads, which is no setting. The project open
# at the quit (`lastProject`) is the agent's for the session, and its
# `close project` takes it back.
const Reached = {
  "theme": "theme", "units": "", "noise.choice": "", "noise.edgeMs": "", "noise.radius": "",
  "noise.steps": "", "noise.allLines": "", "noise.templateOnly": "", "window.x": "", "window.y": "",
  "window.width": "",
  "window.height": "",
  "window.maximized": "", "recentFiles": "open", "recentFolders": "browse",
  "recentProjects": "new project", "lastProject": "", "reopenProject": "",
  "plot.display.visible": "", "plot.display.orientation": "display",
  "plot.display.mode": "display", "plot.display.fills": "display",
  "plot.display.colours": "display", "plot.display.custom.background": "display",
  "plot.display.custom.line": "display", "plot.display.custom.positive": "display",
  "plot.display.custom.negative": "display", "plot.display.custom.hover": "display",
  "plot.display.custom.selected": "display", "plot.display.colourMap": "display",
  "plot.display.gain": "display",
  "plot.display.gainDb": "display", "plot.display.agcWindowMs": "display",
  "plot.display.fixedClip": "display",
  "plot.display.normScope": "display", "plot.display.normStat": "display",
  "plot.display.timeGain": "display", "plot.display.dbPerS": "display",
  "plot.display.power": "display", "plot.display.untilMs": "display",
  "plot.display.clipPercentile": "display", "plot.display.overlap": "display",
  "plot.display.firstBreaks": "display", "plot.display.breakModel.source": "display",
  "plot.display.breakModel.v1": "display", "plot.display.breakModel.interceptMs": "display",
  "plot.display.breakModel.v2": "display", "plot.display.breakModel.crossover": "display",
  "plot.display.breakPickColour": "display", "plot.display.breakModelColour": "display",
  "plot.display.breakSize": "display", "plot.display.breakShowPicks": "display",
  "plot.display.breakShowModel": "display", "plot.display.breakShowWeak": "display",
  "plot.display.breakPickOn": "display",
  "plot.order": "sort", "plot.seismic": "trace filter", "plot.auxiliary": "trace filter",
  "plot.templateOnly": "trace filter",
  "plot.header.auto": "display header",
  "plot.header.fields": "display header", "plot.processing.raw": "",
  "plot.processing.aux": "processing", "plot.processing.dc": "processing",
  "plot.processing.band": "processing", "plot.processing.f1": "processing",
  "plot.processing.f2": "processing", "plot.processing.f3": "processing",
  "plot.processing.f4": "processing", "plot.processing.notches": "processing", "scale.length": "",
  "scale.speed": "",
  "calibrations": "", "readout": "", "sortPresets": "", "customOrder": "sort",
  "messages.autoScroll": "", "messages.hidden": "", "cursorLine": "",
  "files.followLatest": "", "files.subfolders": "subfolders", "files.prepareNext": "",
  "files.listSignatureFiles": "",
  "map.info": "", "map.lengths": "",
  "map.hiddenGroups": "", "map.templateBox": "", "map.spreadTemplate.shape": "",
  "map.spreadTemplate.lines": "", "map.spreadTemplate.channels": "",
  "map.spreadTemplate.inlineHalf": "", "map.spreadTemplate.crosslineHalf": "",
  "map.folderShots": "", "map.filters": "",
  "join.trailingDigits": "", "join.multiComponent": "", "join.lineNames": "",
  "join.coordinates": "", "join.recordMatch": "", "join.traceMatch": "",
  "headers.tab": "", "headers.traceTab": "", "headers.followPointer": "",
  "headers.asDisplayed": "", "headers.columns": "", "headers.tableFields": "",
  "headers.tableScope": "", "shotLog.followPlot": "", "cutGather.recordMs": "",
  "output.segyRevision": "", "output.segdRevision": "", "hideKilled": "",
  "tray.icon": "", "tray.minimize": "",
  # the Seismic gear's Look tab only: no command sets the four component colours
  "componentColours": "",
  "spectrum.window.scale": "open spectrum", "spectrum.window.logFrequency": "open spectrum",
  "spectrum.window.time": "open spectrum", "spectrum.window.raw": "open spectrum",
  "spectrum.window.processed": "open spectrum", "spectrum.window.phase": "open spectrum",
  "spectrum.window.response": "open spectrum",
  "spectrum.window.phasePicture": "open spectrum",
  "spectrum.live.response": "spectrum display",
  "spectrum.live.phasePicture": "spectrum display",
  "spectrum.live.phase": "spectrum display", "spectrum.live.scale": "spectrum display",
  "spectrum.live.logFrequency": "spectrum display", "spectrum.live.time": "spectrum display",
  "spectrum.live.raw": "spectrum display", "spectrum.live.processed": "spectrum display",
  "displayPresets": "display preset",
  "referenceId": "select reference", "vibRoles": "plot display",
  # a signature file's force scale: set in the Vibrator window's Setup, no agent command
  "forceScale.datCountsPerLbf": "", "forceScale.vibAccMvPerCount": ""}.toTable
  # `plotOptions.<kind>.<field>`, each New plot kind's remembered options: all
  # reached by "plot display" (`reachedBy`), and all saved when a window sets them

func reachedBy(path: string): string =
  ## The command an agent gives that changes `path` for the session, "" for none.
  if path.startsWith("plotOptions."): "plot display"
  elif path.startsWith("aux.header."): "display header"
  elif path.startsWith("aux.display."):
    # the Aux window's display: wiggles, no first-break overlay, so those are not reached
    if path in ["aux.display.visible", "aux.display.mode", "aux.display.firstBreaks"] or
        path.startsWith("aux.display.break"): ""
    else: "display"
  else: Reached[path]

func decided(path: string): bool =
  path.startsWith("plotOptions.") or path.startsWith("aux.") or path in Reached

proc flatten[T](x: T; at: string; into: var OrderedTable[string, string]) =
  ## Every setting in `x` by its path ("plot.display.mode"), with its value
  ## as text.
  when T is object and T isnot Rgba:
    for name, f in fieldPairs(x): flatten(f, (if at.len > 0: at & "." else: "") & name, into)
  else:
    into[at] = $x

proc flat(s: Settings): OrderedTable[string, string] =
  flatten(s, "", result)

func has(log: MessageLog; part: string): bool =
  for e in log:
    if part in e.text: return true
  false

const Plot = Viewport(traces: Span(lo: -0.5, hi: 23.5), timeMs: Span(lo: 0, hi: 998),
  columns: 640, rows: 1000)
  ## a plot's size and view, as a window reports them: then a panel reads

proc appIn(dir: string): AppState =
  ## A program that keeps its settings in `dir`, as one started again.
  result = initAppState()
  result.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))
  result.rememberFilesIn(dir)

proc remembered(dir: string): seq[string] =
  ## The documents of what is remembered about files.
  if dirExists(dir / StoreFolder):
    for kind, p in walkDir(dir / StoreFolder): result.add p

const Everything = DisplaySettings(orientation: orTimeAcross, mode: dmWiggleDensity,
  fills: {wfNegative}, colours: pcCustom,
  custom: CustomColours(background: Rgba(r: 1, g: 2, b: 3, a: 255),
    line: Rgba(r: 250, g: 128, b: 0, a: 255), positive: Rgba(r: 9, g: 8, b: 7, a: 128),
    negative: Rgba(r: 200, a: 255), hover: Rgba(g: 200, a: 255),
    selected: Rgba(b: 200, a: 255)), colourMap: cmRedBlack,
  gain: dgExponential, gainDb: -7.5, agcWindowMs: 250, fixedClip: 0.125, normScope: perPanel,
  normStat: normRms, timeGain: tgPower, dbPerS: 12, power: 1.5, untilMs: 3500,
  clipPercentile: 98.5, overlap: 2.5, firstBreaks: true,
  breakModel: BreakModel(source: bmGiven, v1: 2400, interceptMs: 5, v2: 3500, crossover: 800),
  breakPickColour: Rgba(r: 10, g: 200, b: 30, a: 255),
  breakModelColour: Rgba(r: 250, g: 128, b: 0, a: 255), breakSize: bzLarge,
  breakShowPicks: false, breakShowModel: false, breakShowWeak: true,
  breakPickOn: pbAsRecorded)
  ## a display with every field away from its default
const Keys = @[SortKey(field: hfOffset, descending: true), SortKey(field: hfChannel)]
  ## a sort that is no preset: the user's own keys (`customOrder`) too
const Header = HeaderChoice(auto: false, fields: @[hfSrcLine, hfChannel])
const
  FftShown = SpectrumDisplay(scale: ssLinear, logFrequency: true, time: stVisible, raw: false,
    processed: false, response: false, phase: true, phasePicture: ppSigned)
    ## an FFT window shown otherwise than by default
  LiveShown = SpectrumDisplay(scale: ssLinear, logFrequency: true, time: stWhole, raw: false,
    processed: false, response: false, phase: true, phasePicture: ppMagnitude)
    ## the live panel shown otherwise than by default (its phase picture is
    ## not the default, unwrapped)

const PlotShown = AnalysisParams(windowMs: 64, overlap: 50, floorDb: -80, colourMap: cmGrey,
  phaseWithinDb: 30, phasePicture: ppSigned, maxLagMs: 100, fkRaw: true, phaseAgainst: paSelf,
  phaseShow: psSigned,
  reactionMassKg: 3500, baseplateMassKg: 1500, harmonics: 8, projectReference: false,
  tops: @[TopFrequency(reference: "a reference", hz: 180), TopFrequency(reference: RecordedKey &
  " 4/21.19.18.20",
  hz: 210)], qcWindowMs: 250,
  qc: QcLimits(avgPhaseDeg: 4, peakPhaseDeg: 9, avgDistortionPct: 25, peakDistortionPct: 55,
  avgForcePct: 85, peakForcePct: 130), forceHundredPct: 4000, forceHundredWeighted: 9000,
  rolesOpen: true, noteOpen: true, details: true, setupOpen: true, setupSet: true, targetPct: 50)
  ## the options of every kind of New plot window away from their defaults

const PlotViews = [avSpectrogram, avEnvelope, avPhase, avCorrelation, avVibrator, avFk]
  ## the kinds of New plot window that have options

const Filters = Processing(raw: true, aux: true, dc: dcTrend, band: pbBandPass, f1: 3, f2: 6,
  f3: 50, f4: 70, notches: @[NotchFilter(hz: 50, widthHz: 3, harmonics: 3)])
  ## filters with every field away from its default (raw is never kept)

proc main*() =

  block carriedFieldByField:
    var kept, before, after = Settings()
    kept.plot.display.gain = dgNone
    kept.recentFiles = @["/mine"]
    before.plot.display.gain = dgNormalized # what an agent made it
    before.recentFiles = @["/agent's", "/mine"]
    after = before
    after.plot.display.mode = dmDensity # the user's change
    let c = carried(kept, before, after)
    doAssert c.plot.display.mode == dmDensity and c.plot.display.gain == dgNone
    doAssert c.recentFiles == @["/mine"], "a list not changed is kept as it was"
    after.recentFiles = @[]
    doAssert carried(kept, before, after).recentFiles.len == 0, "a list changed is taken whole"
    doAssert kept.plot.display.fixedClip.isNaN and
      carried(kept, before, after).plot.display.fixedClip.isNaN
    after.plot.display.fixedClip = 0.5
    doAssert carried(kept, before, after).plot.display.fixedClip == 0.5
    after.aux.display.fixedClip = 0.25
    doAssert carried(kept, before, after).aux.display.fixedClip == 0.25
    doAssert carried(before, before, after) == after, "carried onto the settings before: after"

  block everySettingDecided:
    var missing, gone: seq[string]
    let leaves = flat(Settings())
    for path in leaves.keys:
      if not path.decided: missing.add path
    for path in Reached.keys:
      if path notin leaves: gone.add path
    doAssert missing.len == 0, "a setting nobody has decided on: " & missing.join(", ") &
      ". Put it in `Reached`: the command an agent gives that changes it for the session " &
      "(this test then shows it is not saved), or \"\" if none does"
    doAssert gone.len == 0, "no longer settings: " & gone.join(", ")

  withFixtures fx:
    let mine = fx.surveySegy()
    let agentDir = fx.dir / "the agent's"
    createDir(agentDir)
    let theirs = agentDir / "shot.sgy"
    let other = agentDir / "spread.sgy"
    let third = agentDir / "third.sgy"
    copyFile(mine, theirs)
    copyFile(mine, third)
    copyFile(fx.longSpreadSegy(), other)
    let sps = fx.surveySps()
    let dir = fx.dir / "config"
    let fe = Frontend()
    let fixtures = (readFile(mine), getLastModificationTime(mine))
    var given: set[CommandKind] ## the kinds of command the agent gave

    proc agent(st: var AppState; command: JsonNode) =
      ## `command` given as agent control gives it, and its work waited for.
      var applied = false
      let answer = st.runCommand(fe, $command, applied)
      doAssert applied, $command & ": " & answer
      var kind: CommandKind
      doAssert kindOf(command, kind).len == 0
      given.incl kind
      doAssert st.settle(busy(st, fe).len == 0), $command & ": " & $busy(st, fe)

    proc firstTrace(st: AppState): int =
      st.sessions[st.findSession(st.panel(MainPanel).layers[0].source.file)].base

    block theUsersOwn:
      # the settings the user left: a file opened by hand, in the user's folder
      var st = appIn(dir)
      st.apply Command(kind: ckOpen, paths: @[mine])
      doAssert st.settle(st.sessions.len == 1)
      var d = st.panel(MainPanel).layers[0].display
      d.gain = dgNone
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      st.flushFiles()
      st.shutdown()
    doAssert fileExists(dir / SettingsFileName), "what the user did by hand was not saved"
    let saved = readFile(dir / SettingsFileName)
    # as the settings write it: NIF writes a backslash and a tilde as \HH (a Windows path)
    doAssert nifString(mine) in saved and "(gain none)" in saved, saved

    block anAgentChangesNothingSaved:
      var st = appIn(dir)
      let before = flat(st.keptSettings)
      doAssert before == flat(st.settings)
      st.agent(%*{"kind": "browse", "paths": [agentDir], "showFirst": true})
      st.agent(%*{"kind": "view", "view": toJson(Plot)})
      st.agent(%*{"kind": "open", "paths": [other]})
      st.agent(%*{"kind": "show file", "path": theirs, "listFolder": true})
      st.agent(%*{"kind": "show trace", "path": other, "traceIndex": 2})
      st.agent(%*{"kind": "show file", "path": theirs})
      st.agent(%*{"kind": "go to gather", "gather": 1})
      st.agent(%*{"kind": "view", "view": {"traces": {"lo": 2.5, "hi": 12.5}}})
      st.agent(%*{"kind": "back"})
      st.agent(%*{"kind": "display", "display": toJson(Everything)})
      st.agent(%*{"kind": "display preset", "presetAction": "save", "presetName": "The agent's"})
      st.agent(%*{"kind": "theme", "theme": "tokyo-night"})
      doAssert st.settings.displayPresets.len == 1 and st.keptSettings.displayPresets.len == 0
      st.agent(%*{"kind": "display header", "header": toJson(Header)})
      st.agent(%*{"kind": "sort", "order": toJson(Keys)})
      st.agent(%*{"kind": "trace filter", "filter": {"seismic": true, "auxiliary": true}})
      st.agent(%*{"kind": "reverse all", "reverse": true})
      st.agent(%*{"kind": "processing", "processing": toJson(Filters)})
      doAssert st.panel(MainPanel).layers[0].processing == Filters, "not what the agent asked"
      let t = st.firstTrace + 3
      st.agent(%*{"kind": "hover", "trace": t})
      st.agent(%*{"kind": "list references"})
      st.agent(%*{"kind": "store reference", "refStore": {"name": "agent pilot",
        "trace": st.firstTrace, "fromMs": 0, "toMs": -1}})
      doAssert st.references.entries.len >= 1, "the reference was not stored"
      let rid = st.references.entries[0].id
      st.agent(%*{"kind": "select reference", "refId": rid})
      # The stored sweep is the whole record, so the job cannot finish. The
      # command is still given: that is what this test counts.
      st.agent(%*{"kind": "correlate", "correlate": true})
      st.agent(%*{"kind": "view reference", "refId": rid})
      doAssert st.refViews.len >= 1, "view reference opened no window"
      st.agent(%*{"kind": "close reference view", "refWindow": st.refViews[0].id})
      st.agent(%*{"kind": "set compare", "compareSlot": "A", "compareTrace": st.firstTrace})
      doAssert st.compareA.filled and st.compareA.samples.len > 0, "compare A was not copied"
      st.agent(%*{"kind": "set compare", "compareSlot": "B", "compareRef": rid, "compareTrace": -1})
      doAssert st.compareB.filled and st.compareOpen, "compare B did not open the window"
      st.agent(%*{"kind": "compare display", "compareShow": {"difference": true}})
      doAssert st.compareOptions.difference
      st.agent(%*{"kind": "swap compare"})
      doAssert st.compareA.fileName.len > 0
      let report = st.stateReport(fe, """{"parts": ["compare"]}""")
      doAssert "slotA" in report and "shiftMs" in report, report
      st.agent(%*{"kind": "compare window", "compareOpen": false})
      doAssert not st.compareOpen
      st.agent(%*{"kind": "clear compare", "compareSlot": "both"})
      doAssert not st.compareA.filled and not st.compareB.filled
      st.agent(%*{"kind": "generate reference", "refGenerate": {"name": "agent sweep",
        "law": "linear", "f1Hz": 8, "f2Hz": 40, "durationMs": 1000, "dtMs": 2, "amplitude": 1}})
      st.agent(%*{"kind": "pilot reference", "refPilot": {"name": "agent record pilot",
        "aux": false, "trace": 1, "startMs": 0, "spanMs": 100}})
      st.agent(%*{"kind": "pilot preview", "refPilot": {"aux": true, "trace": 1,
        "startMs": 0, "spanMs": 100}})
      var sweep = ""
      for e in st.references.entries:
        if e.name == "agent sweep": sweep = e.id
      doAssert sweep.len > 0, "the generated reference was not stored"
      st.agent(%*{"kind": "rename reference", "refId": rid, "refNewName": "agent pilot renamed"})
      # Delete a reference that is not the choice: deleting the choice clears
      # it, so this select would no longer be visible at the end.
      st.agent(%*{"kind": "delete reference", "refId": sweep})
      st.agent(%*{"kind": "select", "traces": [t]})
      st.agent(%*{"kind": "headers shown", "inspect": ["trace headers", "trace samples"]})
      doAssert st.inspection.answer.traces.len == 1, "the Headers window's reader read nothing"
      st.agent(%*{"kind": "headers shown", "inspect": []})
      st.agent(%*{"kind": "open spectrum", "spectrumShow": toJson(FftShown)})
      doAssert st.spectra.len == 2 and st.spectra[1].spectrum.averaged == 1,
        "the agent's FFT window: " & $st.spectra.len
      st.agent(%*{"kind": "spectrum panel"})
      doAssert st.spectra[0].shown and st.spectra[0].spectrum.averaged > 0
      st.agent(%*{"kind": "spectrum display", "spectrum": 0, "spectrumShow": toJson(LiveShown),
        "frozen": true})
      doAssert st.spectra[0].frozen
      st.agent(%*{"kind": "spectrum cursor", "spectrum": st.spectra[1].id,
        "cursor": {"held": true, "x": 3, "y": 0}})
      doAssert st.spectra[1].cursor.held and st.spectra[1].cursor.x == 3, "the agent's cursor"
      # past the plot's bins and curves: within them, and the reply says so
      # (seen to fail with the words not logged: the reply said nothing)
      block clamped:
        var applied = false
        let answer = st.runCommand(fe, $(%*{"kind": "spectrum cursor",
          "spectrum": st.spectra[1].id, "cursor": {"held": true, "x": 99999, "y": 99}}), applied)
        template c: untyped = st.spectra[1].cursor
        doAssert applied and c.x == st.spectra[1].spectrum.raw.high and
          c.y == max(st.spectra[1].drawnCurves.high, 0), $c # (it draws none: all hidden)
        let done = parseJson(parseJson(answer)["content"][0]["text"].getStr)
        doAssert not done["ignored"].getBool and "bin 99999 is not on its frequency axis" in
          $done["messages"] and "curve 99 is not there" in $done["messages"], answer
      st.agent(%*{"kind": "step trace", "spectrum": st.spectra[1].id, "stepBy": 1})
      doAssert st.spectra[1].traces.len == 1 and st.spectra[1].traces != @[t] and
        st.spectra[1].traces[0] in st.selection.selected, "the agent's step: " &
        $st.spectra[1].traces
      st.agent(%*{"kind": "close spectrum", "spectrum": st.spectra[1].id})
      doAssert st.spectra.len == 1
      st.agent(%*{"kind": "open plot", "plotView": "spectrogram"})
      doAssert st.plots.len == 1, "the agent's plot window: " & $st.plots.len
      st.agent(%*{"kind": "plot display", "plot": st.plots[0].id, "plotParams": {"windowMs": 64},
        "plotFrozen": true})
      doAssert st.plots[0].frozen and st.plots[0].params.windowMs == 64 and
        st.plots[0].params.overlap == AnalysisParams().overlap, $st.plots[0].params
      # the options of every kind, for the session
      for v in PlotViews:
        if v != avSpectrogram:
          st.agent(%*{"kind": "open plot", "plotView": $v, "plotTraces": [st.firstTrace,
            st.firstTrace + 1, st.firstTrace + 2,
            st.firstTrace + 3]})
        st.agent(%*{"kind": "plot display", "plot": st.plots[^1].id,
          "plotParams": toJson(PlotShown)})
        doAssert st.settings.plotOptions.applied(v, AnalysisParams()) == PlotShown.optionsOf(v)
          .applied(v, AnalysisParams()), "the agent's options of " & $v & " were not taken"
      doAssert st.plots.len == PlotViews.len, $st.plots.len
      # a vibrator signature's roles chosen by an agent: remembered for the session only
      st.agent(%*{"kind": "open plot", "plotView": "vibrator signature",
        "plotTraces": [st.firstTrace, st.firstTrace + 1, st.firstTrace + 2,
        st.firstTrace + 3]})
      st.agent(%*{"kind": "plot display", "plot": st.plots[^1].id,
        "plotParams": {"roles": {"mass": 3, "baseplate": 2}}})
      doAssert st.plots[^1].params.roles.mass == 3 and st.settings.vibRoles.len == 1
      for w in st.plots: st.agent(%*{"kind": "close plot", "plot": w.id})
      st.agent(%*{"kind": "open plot", "plotView": "spectrogram"})
      doAssert st.plots[0].params.windowMs == 64, "a new window opens with the agent's options"
      st.agent(%*{"kind": "plot cursor", "plot": st.plots[0].id, "plotCursor": {"held": true,
        "x": 2, "y": 3}})
      doAssert st.plots[0].cursor == PlotCursor(held: true, x: 2, y: 3)
      st.agent(%*{"kind": "close plot", "plot": st.plots[0].id})
      doAssert st.plots.len == 0
      st.agent(%*{"kind": "edit traces", "edit": "killed"})
      st.agent(%*{"kind": "own filter", "edited": [st.firstTrace], "on": true,
        "filterPlace": "after", "processing": {"band": "band-pass", "f1": 10.0, "f2": 12.0,
        "f3": 55.0, "f4": 60.0}})
      # Seen to fail with the command unchecked (ckOwnFilter a no-op): the
      # trace had no filter and undo did not name it.
      let trace = st.firstTrace - st.sessions[0].base
      let set = st.ownAt(st.sessions[0].path, trace)
      doAssert set.has and set.filter.place == fpAfter and set.filter.spec.f2 == 12.0,
        "the agent's filter was not set"
      doAssert st.editsOf(0).undoText == "trace " & $(trace + 1) & " filtered",
        st.editsOf(0).undoText
      st.agent(%*{"kind": "undo edit"})
      doAssert not st.ownAt(st.sessions[0].path, trace).has, "undo did not take the filter away"
      st.agent(%*{"kind": "redo edit"})
      doAssert st.ownAt(st.sessions[0].path, trace).has, "redo did not put the filter back"
      st.agent(%*{"kind": "time shift", "edited": [st.firstTrace], "ms": 7.0})
      doAssert st.editsOf(0).shiftOf(trace) == 8.0, "7 ms was not snapped to 8"
      var shifted = ""
      for e in st.log:
        if "Shifted" in e.text: shifted = e.text
      doAssert "Shifted 1 trace by 8 ms." in shifted, shifted
      st.agent(%*{"kind": "time shift", "edited": [st.firstTrace]})
      doAssert st.editsOf(0).shiftOf(trace) == 0.0, "an absent shift did not clear"
      st.agent(%*{"kind": "list file memory"})
      st.flushFiles()
      doAssert remembered(dir).len == 0, "the agent's edits are remembered: " & $remembered(dir)
      st.agent(%*{"kind": "clear edits"})
      st.agent(%*{"kind": "clear selection"})
      st.agent(%*{"kind": "join geometry", "joinFiles": [{"path": sps.s, "kind": "SPS"},
        {"path": sps.r, "kind": "SPS"}, {"path": sps.x, "kind": "SPS"}]})
      st.agent(%*{"kind": "select unmatched"})
      st.agent(%*{"kind": "read survey units", "unitsOf": [{"path": sps.s, "kind": "SPS"}]})
      doAssert st.surveyHead(sps.s) >= 0 and st.heads[st.surveyHead(sps.s)].done
      st.agent(%*{"kind": "choose unit", "unitChoice": {"survey": [sps.s, sps.r], "unit": "metres",
        "byHand": true}})
      var chosen = suNotGiven
      doAssert st.unitChoices.chosenFor([sps.r, sps.s], chosen) and chosen == suMetres
      st.agent(%*{"kind": "load survey", "paths": [sps.s, sps.r, sps.x]})
      doAssert st.survey.layers.len >= 3, $st.survey.layers.len
      var layer = NoSurveyLayer
      for l in st.survey.layers:
        if l.origin == loSurveyFile and l.points[prReceiver].len > 0: layer = l.id
      let point = PointRef(layer: layer, role: prReceiver, point: 0)
      st.agent(%*{"kind": "map view", "mapView": {"perPixel": st.map.view.perPixel / 2}})
      st.agent(%*{"kind": "map back"})
      st.agent(%*{"kind": "map layer", "mapLayer": toJson(st.survey.layers[
        st.survey.find(layer)].keyOf(prReceiver)), "shown": false})
      st.agent(%*{"kind": "select points", "points": [toJson(point)]})
      st.agent(%*{"kind": "hover points", "points": [toJson(point)]})
      st.agent(%*{"kind": "show points' record", "points": [toJson(point)]})
      st.agent(%*{"kind": "unload survey", "layer": int(layer)})
      let job = st.jobs.list[^1].id
      st.agent(%*{"kind": "reorder job", "reordered": int(job), "position": 0})
      st.agent(%*{"kind": "cancel job", "job": int(job)})
      st.agent(%*{"kind": "remove job", "job": int(job)})
      st.agent(%*{"kind": "stop reading"})
      st.agent(%*{"kind": "retry"})
      st.agent(%*{"kind": "retry", "panel": 0}) # the folder's listing
      st.agent(%*{"kind": "prepare", "path": third})
      st.agent(%*{"kind": "show file", "path": third})
      doAssert st.sessions.anyIt(it.path == third)
      # the Aux window's own display and header, given to its panel
      st.agent(%*{"kind": "aux window"})
      doAssert st.settle(st.auxIndex >= 0)
      let auxPanel = int(st.panels[st.auxIndex].id)
      var auxDisplay = toJson(Everything)
      for key in ["mode", "firstBreaks", "breakModel", "breakPickColour", "breakModelColour",
          "breakSize", "breakShowPicks", "breakShowModel", "breakShowWeak", "breakPickOn"]:
        auxDisplay.delete(key)
      auxDisplay["gain"] = %"fixed"
      st.agent(%*{"kind": "display", "panel": auxPanel, "display": auxDisplay})
      st.agent(%*{"kind": "display header", "panel": auxPanel, "header": toJson(Header)})
      # Fixed, with no amplitude yet: it takes one from the data shown
      st.agent(%*{"kind": "display", "display": {"gain": "fixed", "fixedClip": nil}})
      let shown = st.panel(MainPanel).layers[0].display
      doAssert shown.gain == dgFixed and shown.fixedClip > 0, "no amplitude from the data"
      doAssert shown.mode == Everything.mode and shown.overlap == Everything.overlap,
        "what is shown is the agent's"
      st.agent(%*{"kind": "reopen", "reopenPath": third, "openChoice": {"verifyAll": true}})
      doAssert st.settle(st.sessions.anyIt(it.path == third and
        it.facts.opened.choice.verifyAll)), "not reopened"
      # seismic stays on above (the spectrum is of a trace shown); off here,
      # while a file is shown, so the choice is seen to change and not be saved
      st.agent(%*{"kind": "trace filter", "filter": {"seismic": false, "auxiliary": true,
        "templateOnly": true}})
      st.agent(%*{"kind": "close", "file": int(st.sessions[0].id)})
      st.agent(%*{"kind": "subfolders", "subfolders": true}) # for the session only
      st.agent(%*{"kind": "treat as", "treatPath": third, "treatKind": "shot"})
      doAssert st.treatOf(third).kind == some(rkShotGather), "the agent's kind was not taken"
      # read back from the state in the command's words, and that it is set
      proc treated(st: AppState): JsonNode =
        result = newJNull()
        let answer = st.stateReport(fe, """{"parts": ["fileList"]}""")
        for e in parseJson(parseJson(answer)["content"][0]["text"].getStr)["fileList"]["entries"]:
          if e["path"].getStr == third: result = e["treated"]
      let back = st.treated
      doAssert back["recording"].getStr == "shot" and back["forced"]["recording"].getBool and
        not back["forced"]["grouping"].getBool and back.hasKey("sort"), $back
      st.agent(%*{"kind": "treat as", "treatPath": third, "treatKind": "automatic"})
      doAssert not st.treatOf(third).isSet
      doAssert not st.treated["forced"]["recording"].getBool, $st.treated
      st.agent(%*{"kind": "clear survey"}) # in memory only (ignored here: none is imported)
      st.agent(%*{"kind": "new project", "projectPath": fx.dir / "the agent's job",
        "dataFolders": [agentDir]})
      doAssert st.inProject and st.settings.lastProject == fx.dir / "the agent's job"
      if st.mainReferences.entries.len > 0:
        st.agent(%*{"kind": "copy reference", "refId": st.mainReferences.entries[0].id})
      else:
        st.agent(%*{"kind": "copy reference", "refId": "none"})
      st.agent(%*{"kind": "close project"})
      st.agent(%*{"kind": "open project", "projectPath": fx.dir / "the agent's job"})
      doAssert st.inProject
      st.agent(%*{"kind": "vendor map", "vendorMap": "none"})
      st.agent(%*{"kind": "vendor map", "vendorMap": "automatic"})
      st.agent(%*{"kind": "name pattern", "patternAction": "choose",
        "namePattern": {"name": ""}}) # (no pattern chosen: files are named as today)
      st.agent(%*{"kind": "output text", "textAction": "save", "textTemplate":
        {"name": "Agent", "encoding": "ascii", "lines": ["C 1 {stem}", "C 2"]}})
      doAssert st.project.doc.outputTexts.len == 1 and
        st.project.doc.outputTexts[0].encoding == teAscii and
        st.project.doc.outputTexts[0].lines == @["C 1 {stem}", "C 2"]
      st.agent(%*{"kind": "output text", "textAction": "choose", "textTemplate": {"name": "agent"}})
      doAssert st.project.doc.outputText == "Agent"
      st.agent(%*{"kind": "output text", "textAction": "save", "textTemplate":
        {"name": "Bad", "lines": ["{nope}"]}}) # refused as the window's command is
      doAssert st.project.doc.outputTexts.len == 1
      st.agent(%*{"kind": "output text", "textAction": "delete", "textTemplate": {"name": "AGENT"}})
      doAssert st.project.doc.outputTexts.len == 0 and st.project.doc.outputText == ""
      st.agent(%*{"kind": "close project"})
      st.agent(%*{"kind": "reload vendor maps"})
      st.agent(%*{"kind": "open pair"}) # (the panel shows no signature file: ignored, in words)
      doAssert given == Offered, "not given: " & $(Offered - given)
      let session = flat(st.settings)
      let kept = flat(st.keptSettings)
      for path, was in before:
        doAssert kept[path] == was, "the agent's \"" & reachedBy(path) & "\" reached " & path &
          ", which is saved: " & was & " -> " & kept[path]
        if reachedBy(path).len == 0:
          doAssert session[path] == was, "an agent changed " & path & " for the session (" &
            was & " -> " & session[path] & "): say so in `Reached`"
        else:
          doAssert session[path] != was, "the agent's \"" & reachedBy(path) & "\" did not " &
            "change " & path & " for the session: this test does not show it is not saved"
      doAssert theirs in st.settings.recentFiles and agentDir in st.settings.recentFolders,
        "the recent lists of the session hold what the agent opened"
      doAssert st.log.has("Opened shot.sgy")
      st.flushFiles()
      doAssert readFile(dir / SettingsFileName) == saved, "the settings file changed"
      st.shutdown()
      doAssert readFile(dir / SettingsFileName) == saved, "the settings file changed at the end"
      doAssert remembered(dir).len == 0, "the agent's edits are remembered after the quit"
      let again = appIn(dir)
      doAssert flat(again.settings) == before, "a restart did not read the settings from before"

    block throughAWindowTheyAreSaved:
      var st = appIn(dir)
      let before = flat(st.keptSettings)
      st.apply Command(kind: ckBrowse, paths: @[agentDir], showFirst: true)
      doAssert st.settle(st.sessions.len == 1 and busy(st, fe).len == 0)
      st.apply Command(kind: ckView, panel: MainPanel, view: Plot)
      st.apply Command(kind: ckOpen, paths: @[other])
      doAssert st.settle(st.sessions.len == 2)
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: Everything)
      st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paSave,
        presetName: "Mine")
      st.apply Command(kind: ckTheme, theme: "nord")
      st.apply Command(kind: ckHeader, panel: MainPanel, header: Header)
      st.apply Command(kind: ckAuxWindow, onScreen: true)
      var auxShown = Everything
      auxShown.gain = dgFixed
      st.apply Command(kind: ckDisplay, panel: st.panels[st.auxIndex].id, display: auxShown)
      st.apply Command(kind: ckHeader, panel: st.panels[st.auxIndex].id, header: Header)
      st.apply Command(kind: ckSort, panel: MainPanel, order: Keys)
      st.apply Command(kind: ckProcessing, panel: MainPanel, processing: Filters)
      st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel,
        spectrumTraces: @[st.firstTrace], spectrumShow: FftShown)
      st.apply Command(kind: ckSpectrumDisplay, spectrum: LiveSpectrum, spectrumShow: LiveShown)
      for v in PlotViews:
        st.apply Command(kind: ckOpenPlot, plotView: v, plotTraces: @[st.firstTrace,
          st.firstTrace + 1, st.firstTrace + 2, st.firstTrace + 3])
        st.apply Command(kind: ckPlotDisplay, plot: st.plots[^1].id, plotParams: PlotShown)
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[st.firstTrace,
        st.firstTrace + 1, st.firstTrace + 2, st.firstTrace + 3])
      var swapped = st.plots[^1].params
      swap(swapped.roles.mass, swapped.roles.baseplate)
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[^1].id, plotParams: swapped)
      st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "window pilot",
        trace: st.firstTrace, fromMs: 0, toMs: -1))
      doAssert st.settle(st.references.entries.len >= 1 and busy(st, fe).len == 0),
        "the window's reference was not stored"
      st.apply Command(kind: ckSelectReference, refId: st.references.entries[0].id)
      st.apply Command(kind: ckSubfolders, subfolders: true)
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "my job", dataFolders: @[agentDir])
      doAssert st.settle(st.inProject and busy(st, fe).len == 0)
      var d = st.panel(MainPanel).layers[0].display
      d.gain = dgFixed
      d.fixedClip = NaN
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.settle(st.panel(MainPanel).layers[0].display.fixedClip > 0)
      st.apply Command(kind: ckFilter, panel: MainPanel,
        filter: TraceFilter(seismic: false, auxiliary: true,
          templateOnly: true))
      let kept = flat(st.keptSettings)
      for path, was in before:
        if reachedBy(path).len > 0:
          doAssert kept[path] != was, "a window's change of " & path & " was not kept"
      doAssert kept == flat(st.settings), "what a window changed is what is kept"
      st.shutdown()
      let again = appIn(dir)
      doAssert flat(again.settings) == kept, "a restart did not read what the window changed"
      doAssert again.settings.recentFiles[0..1] == @[other, theirs]

    block aWindowAfterAnAgent:
      var st = appIn(dir)
      let user = st.keptSettings
      st.apply Command(kind: ckOpen, paths: @[mine])
      doAssert st.settle(st.sessions.len == 1)
      st.apply Command(kind: ckView, panel: MainPanel, view: Plot)
      st.agent(%*{"kind": "display", "display": {"gain": "normalized", "mode": "density"}})
      st.agent(%*{"kind": "sort", "order": [{"field": "FFID"}]})
      st.agent(%*{"kind": "open", "paths": [fx.longSpreadSegy()]})
      doAssert st.settings.plot.display.gain == dgNormalized
      # the user, in the strip: another mode, on the display shown
      var d = st.panel(MainPanel).layers[0].display
      d.mode = dmWiggle
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.keptSettings.plot.display.mode == dmWiggle
      doAssert st.keptSettings.plot.display.gain == user.plot.display.gain,
        "the user's new mode kept the agent's gain: " & $st.keptSettings.plot.display.gain
      doAssert st.settings.plot.display.gain == dgNormalized, "the session keeps the agent's"
      # the status bar's fields, as the bar's menu sends them
      var s = st.settings
      s.readout = @[rfTime, rfAmplitude]
      st.apply Command(kind: ckSettings, settings: s)
      doAssert st.keptSettings.readout == @[rfTime, rfAmplitude]
      doAssert st.keptSettings.plot.order == user.plot.order,
        "the user's status bar fields kept the agent's sort: " & $st.keptSettings.plot.order
      doAssert fx.longSpreadSegy() notin st.keptSettings.recentFiles
      # File > Open recent > Clear
      s = st.settings
      s.recentFiles.setLen 0
      s.recentFolders.setLen 0
      st.apply Command(kind: ckSettings, settings: s)
      doAssert st.keptSettings.recentFiles.len == 0 and st.keptSettings.recentFolders.len == 0
      # the windows' arrangement: an agent's is not saved, the user's is
      st.apply Command(origin: coAgent, kind: ckLayout, arrangement: "[Window][Agent]")
      st.flushFiles()
      doAssert not fileExists(dir / LayoutFileName), "an agent's arrangement was saved"
      st.apply Command(kind: ckLayout, arrangement: "[Window][Mine]")
      st.flushFiles()
      let layout = readFile(dir / LayoutFileName)
      doAssert "Mine" in layout and "Agent" notin layout, layout
      st.shutdown()
      let again = appIn(dir)
      doAssert again.settings.plot.display.mode == dmWiggle and
        again.settings.plot.display.gain == user.plot.display.gain
      doAssert again.settings.readout == @[rfTime, rfAmplitude]
    block aReopenOfNoFile:
      # Seen to fail: "nope.sgy is opened again" was logged (the line is written
      # in `reopenWith` before the open), and the choice kept for the path that
      # is no file. The open job decides: a file that cannot be
      # opened gives one failure message and keeps no choice; a file that exists
      # outside the file list is opened (with a pre-check of the list, "was
      # opened" failed).
      var st = appIn(dir)
      st.apply Command(kind: ckOpen, paths: @[mine])
      doAssert st.settle(st.sessions.len == 1)
      let missing = agentDir / "nope.sgy"
      var applied = false
      let answer = st.runCommand(fe, $(%*{"kind": "reopen", "reopenPath": missing,
        "openChoice": toJson(OpenChoice(verifyAll: true))}), applied)
      doAssert applied, answer
      doAssert st.settle(busy(st, fe).len == 0), $busy(st, fe)
      var failures = 0
      for e in st.log:
        if "Cannot open " & missing in e.text: inc failures
      doAssert failures == 1, "the failure was said " & $failures & " times"
      doAssert not st.log.has("is opened again"), "said opened again before the open"
      doAssert st.openChoiceOf(canonical(missing)).isDefault, "a choice kept for no file"
      doAssert st.sessions.len == 1 and st.sessions[0].path == canonical(mine)
      let outside = agentDir / "outside.sgy"
      copyFile(mine, outside)
      discard st.runCommand(fe, $(%*{"kind": "reopen", "reopenPath": outside,
        "openChoice": toJson(OpenChoice(verifyAll: true))}), applied)
      doAssert st.settle(st.sessions.len >= 1 and
        st.sessions.anyIt(it.path == canonical(outside) and it.facts.opened.choice.verifyAll)),
        "a file outside the file list was not opened"
      st.shutdown()

    block aTableAskedBeyondTheLimits:
      # Seen to fail: rows at 9223372036854775000 raised OverflowDefect in the
      # Headers reader (the program ended), and 8000 columns were taken. The
      # rows are clamped to what an int32 holds and to MaxTableRows, and a table
      # of more than MaxTableColumns columns is refused, with the words said.
      var st = appIn(dir)
      st.apply Command(kind: ckOpen, paths: @[mine])
      doAssert st.settle(st.sessions.len == 1)
      var applied = false
      var view = toJson(TableView(fields: @["keys.channel"], scope: tsFile, rows: 0 .. 0))
      view["rows"]["a"] = newJInt(9223372036854775000'i64)
      view["rows"]["b"] = newJInt(9223372036854775000'i64)
      discard st.runCommand(fe, $(%*{"kind": "headers shown", "inspect": ["trace table"],
        "table": view}), applied)
      doAssert applied, "the command was not taken"
      doAssert st.settle(not st.inspection.waiting), "the table was not answered"
      let rows = st.inspection.table.rows
      doAssert rows.a == int(int32.high) and rows.b - rows.a < MaxTableRows and
        rows.b >= rows.a, $rows
      doAssert st.inspection.answer.table.first == rows.a and
        st.inspection.answer.table.rowTraces.len == 0, $st.inspection.answer.table.first
      var wide = toJson(TableView(fields: @["keys.channel"], scope: tsFile, rows: 0 .. 0))
      wide["fields"] = %*(newSeq[string](8000).mapIt("keys.channel"))
      applied = false
      let shown = st.inspection.table
      discard st.runCommand(fe, $(%*{"kind": "headers shown", "inspect": ["trace table"],
        "table": wide}), applied)
      doAssert st.inspection.table == shown, "the table of 8000 columns was taken"
      var said = false
      for e in st.log:
        if "Ignored \"headers shown\": 8000 columns asked" in e.text: said = true
      doAssert said, "the refusal was not said"
      st.shutdown()

    doAssert (readFile(mine), getLastModificationTime(mine)) == fixtures, "a fixture changed"
    echo "tagentsession: ok"

when isMainModule:
  main()
