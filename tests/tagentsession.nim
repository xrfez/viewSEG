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
##   log still says what the agent's commands did;
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
## setting nobody has decided on: gadget".

import std/[json, math, os, sequtils, strutils, tables]
import viewSEG/core/[geometry, settingsnif, state]
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
# shown` says what its reader reads, which is no setting.
const Reached = {
  "theme": "", "window.x": "", "window.y": "", "window.width": "", "window.height": "",
  "window.maximized": "", "recentFiles": "open", "recentFolders": "browse",
  "plot.display.visible": "",
  "plot.display.mode": "display", "plot.display.fills": "display",
  "plot.display.colours": "display", "plot.display.custom.background": "display",
  "plot.display.custom.line": "display", "plot.display.custom.positive": "display",
  "plot.display.custom.negative": "display", "plot.display.custom.hover": "display",
  "plot.display.custom.selected": "display", "plot.display.gain": "display",
  "plot.display.gainDb": "display", "plot.display.agcWindowMs": "display",
  "plot.display.fixedClip": "display",
  "plot.display.normScope": "display", "plot.display.normStat": "display",
  "plot.display.timeGain": "display", "plot.display.dbPerS": "display",
  "plot.display.power": "display", "plot.display.untilMs": "display",
  "plot.display.clipPercentile": "display", "plot.display.overlap": "display",
  "plot.order": "sort", "plot.header.auto": "display header",
  "plot.header.fields": "display header", "scale.length": "", "scale.speed": "",
  "calibrations": "", "readout": "", "sortPresets": "", "customOrder": "sort",
  "messages.autoScroll": "", "messages.hidden": "", "cursorLine": "",
  "files.followLatest": "", "files.prepareNext": "", "map.info": "", "map.lengths": "",
  "map.hiddenGroups": "", "map.templateBox": "", "map.spreadTemplate.shape": "",
  "map.spreadTemplate.lines": "", "map.spreadTemplate.channels": "",
  "map.spreadTemplate.inlineHalf": "", "map.spreadTemplate.crosslineHalf": "",
  "join.trailingDigits": "", "join.multiComponent": "", "join.lineNames": "",
  "join.coordinates": "", "join.recordMatch": "", "join.traceMatch": "",
  "headers.tab": "", "headers.traceTab": "", "headers.followPointer": "",
  "headers.asDisplayed": "", "headers.columns": ""}.toTable

proc flatten[T](x: T; at: string; into: var OrderedTable[string, string]) =
  ## Every setting in `x` by its path ("plot.display.mode"), with its value
  ## as text.
  when T is object and T isnot Rgba:
    for name, f in fieldPairs(x): flatten(f, (if at.len > 0: at & "." else: "") & name, into)
  else:
    into[at] = $x

proc flat(s: Settings): OrderedTable[string, string] =
  flatten(s, "", result)

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

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

const Everything = DisplaySettings(mode: dmWiggleDensity, fills: {wfNegative},
  colours: pcCustom, custom: CustomColours(background: Rgba(r: 1, g: 2, b: 3, a: 255),
    line: Rgba(r: 250, g: 128, b: 0, a: 255), positive: Rgba(r: 9, g: 8, b: 7, a: 128),
    negative: Rgba(r: 200, a: 255), hover: Rgba(g: 200, a: 255),
    selected: Rgba(b: 200, a: 255)),
  gain: dgExponential, gainDb: -7.5, agcWindowMs: 250, fixedClip: 0.125, normScope: perPanel,
  normStat: normRms, timeGain: tgPower, dbPerS: 12, power: 1.5, untilMs: 3500,
  clipPercentile: 98.5, overlap: 2.5)
  ## a display with every field away from its default
const Keys = @[SortKey(field: hfOffset, descending: true), SortKey(field: hfChannel)]
  ## a sort that is no preset: the user's own keys (`customOrder`) too
const Header = HeaderChoice(auto: false, fields: @[hfSrcLine, hfChannel])

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
  doAssert carried(before, before, after) == after, "carried onto the settings before: after"

block everySettingDecided:
  var missing, gone: seq[string]
  let leaves = flat(Settings())
  for path in leaves.keys:
    if path notin Reached: missing.add path
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
  doAssert mine in saved and "(gain none)" in saved, saved

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
    st.agent(%*{"kind": "display header", "header": toJson(Header)})
    st.agent(%*{"kind": "sort", "order": toJson(Keys)})
    st.agent(%*{"kind": "trace filter", "filter": {"seismic": true, "auxiliary": true}})
    st.agent(%*{"kind": "reverse all", "reverse": true})
    let t = st.firstTrace + 3
    st.agent(%*{"kind": "hover", "trace": t})
    st.agent(%*{"kind": "select", "traces": [t]})
    st.agent(%*{"kind": "headers shown", "inspect": ["trace headers", "trace samples"]})
    doAssert st.inspection.answer.traces.len == 1, "the Headers window's reader read nothing"
    st.agent(%*{"kind": "headers shown", "inspect": []})
    st.agent(%*{"kind": "edit traces", "edit": "killed"})
    st.agent(%*{"kind": "undo edit"})
    st.agent(%*{"kind": "clear edits"})
    st.agent(%*{"kind": "clear selection"})
    st.agent(%*{"kind": "join geometry", "joinFiles": [{"path": sps.s, "kind": "SPS"},
      {"path": sps.r, "kind": "SPS"}, {"path": sps.x, "kind": "SPS"}]})
    st.agent(%*{"kind": "select unmatched"})
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
    # Fixed, with no amplitude yet: it takes one from the data shown
    st.agent(%*{"kind": "display", "display": {"gain": "fixed", "fixedClip": nil}})
    let shown = st.panel(MainPanel).layers[0].display
    doAssert shown.gain == dgFixed and shown.fixedClip > 0, "no amplitude from the data"
    doAssert shown.mode == Everything.mode and shown.overlap == Everything.overlap,
      "what is shown is the agent's"
    st.agent(%*{"kind": "close", "file": int(st.sessions[0].id)})
    doAssert given == Offered, "not given: " & $(Offered - given)
    let session = flat(st.settings)
    let kept = flat(st.keptSettings)
    for path, was in before:
      doAssert kept[path] == was, "the agent's \"" & Reached[path] & "\" reached " & path &
        ", which is saved: " & was & " -> " & kept[path]
      if Reached[path].len == 0:
        doAssert session[path] == was, "an agent changed " & path & " for the session (" &
          was & " -> " & session[path] & "): say so in `Reached`"
      else:
        doAssert session[path] != was, "the agent's \"" & Reached[path] & "\" did not " &
          "change " & path & " for the session: this test does not show it is not saved"
    doAssert theirs in st.settings.recentFiles and agentDir in st.settings.recentFolders,
      "the recent lists of the session hold what the agent opened"
    doAssert st.log.has("Opened shot.sgy")
    st.flushFiles()
    doAssert readFile(dir / SettingsFileName) == saved, "the settings file changed"
    st.shutdown()
    doAssert readFile(dir / SettingsFileName) == saved, "the settings file changed at the end"
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
    st.apply Command(kind: ckHeader, panel: MainPanel, header: Header)
    st.apply Command(kind: ckSort, panel: MainPanel, order: Keys)
    var d = st.panel(MainPanel).layers[0].display
    d.gain = dgFixed
    d.fixedClip = NaN
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    doAssert st.settle(st.panel(MainPanel).layers[0].display.fixedClip > 0)
    let kept = flat(st.keptSettings)
    for path, was in before:
      if Reached[path].len > 0:
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
  doAssert (readFile(mine), getLastModificationTime(mine)) == fixtures, "a fixture changed"
  echo "tagentsession: ok"
