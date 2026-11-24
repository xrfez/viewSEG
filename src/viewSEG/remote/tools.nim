## The tools agent control offers, answered on the UI thread from the
## application state, as the windows read it and with the commands they
## issue (docs/agent-control.md describes them for a user):
##
## - `command`: one `Command` from JSON (`remote/schema`), given to `apply`;
## - `state`: the file list, the open files, the panels (view, display, gain,
##   order, the traces at each position, the edits), the selection, the jobs,
##   the newest messages, the survey, the Headers window (its tab, the traces
##   it is about and what its reader read of them, the file's facts);
## - `headers`: one trace's keys and header fields, read on a job (the
##   file's map may be on a drive that does not answer): `askTraceHeaders`,
##   then `headersAnswer` in later frames (`remote/control` keeps the call);
## - `screenshot`: a PNG of the window or a part of it: the frontend reads
##   the pixels back (`Frontend.shoot`, the only part on the UI thread);
##   `pictureAnswer` scales them down and encodes them on the server thread,
##   with the encoder the frontend gave (`PngEncoder`);
## - `wait`: until no job runs, every panel's picture is complete and the
##   Headers window's reader has answered (`remote/control` keeps it across
##   frames; `busy` says what is left).
##
## Each tool's answer is the JSON text of an MCP tool result. Input comes
## from an agent: every problem with it is a result with `isError`, never an
## exception.

import std/[algorithm, base64, json, math, monotimes, os, sets, strutils, tables, times]
import parseSEG
import ../core/[explain, firstbreaks, geometry, join, log, properties, shortcuts, state, units,
  versions]
import protocol, schema

const
  ToolNames* = ["command", "state", "headers", "screenshot", "wait"]
  StateParts* = ["program", "fileList", "files", "panels", "selection", "map", "jobs",
    "messages", "survey", "headers", "memory", "spectra", "displayPresets", "plots", "project",
    "properties", "compare", "vendorMaps"]
  ShotTargets* = ["window", "plot", "seismic", "aux", "aux plot", "map", "files", "records",
    "headers", "messages",
    "jobs", "toolbar", "statusbar", "spectrum", "fft", "compare"]
    ## what `screenshot` takes a picture of: the whole window, the Seismic
    ## window's picture of the traces alone ("aux plot": the Aux window's), or one window
    ## ("aux" the Aux window, "spectrum" the
    ## live spectrum panel, "fft" the FFT window opened last; "fft 2" names
    ## FFT window 2, "new plot 3" the analysis window 3)
  DefaultShotSide* = 1600 ## the longest side of a screenshot, unless asked
  MaxShotSide* = 4096
  MaxShotBytes* = 16 * 1024 * 1024 ## the largest PNG a screenshot returns
  DefaultListed = 200 ## the longest list `state` returns, unless asked
  MaxListed = 100_000
  DefaultMessages = 20
  MaxMessages = 1000
  DefaultWaitSeconds* = 30
  PanelKinds = {ckGather, ckView, ckDisplay, ckHeader, ckSort, ckReverseAll, ckBack,
    ckShowFile, ckShowTrace, ckEdit, ckOwnFilter, ckTimeShift, ckUndoEdit, ckRedoEdit,
    ckClearEdits, ckFilter,
    ckProcessing,
    ckDisplayPreset}
    ## the kinds of `Command`'s branch with `panel`, a display, a view, a filter

type
  Shot* = object
    ## A picture the frontend took, as it took it.
    pixels*: seq[Rgba] ## rows from the top; empty when there is none
    width*, height*: int
    error*: string     ## why there is none, in plain words

  Picture* = object
    ## A picture to answer with, for the server thread to scale and encode.
    shot*: Shot
    maxSide*: int ## its longest side, at most
    target*: string

  PngEncoder* = proc (pixels: openArray[Rgba]; w, h: int): (string, string) {.nimcall, gcsafe.}
    ## PNG bytes of `pixels` (`w` by `h`, rows from the top), or "" and why
    ## not; called on the server thread

  PlotAxes* = object
    ## The axes of one plot of an analysis window as the frontend drew them last
    ## frame (NaN limits: not drawn, or not numbers) and whether the user moved
    ## each off its fit.
    xLo*, xHi*, yLo*, yHi*: float64
    xZoomed*, yZoomed*: bool

  Frontend* = object
    ## What only the frontend can do. A nil hook: that part is not available
    ## (a test without a window).
    shoot*: proc (target: string): Shot {.closure.}
      ## the pixels of `target` (one of `ShotTargets`) as the last frame drew
      ## them
    drawnView*: proc (panel: PanelId; view: var Viewport): bool {.closure.}
      ## the view `panel`'s picture was last drawn for; false when the
      ## frontend draws no picture of that panel
    plotAxes*: proc (id: string): PlotAxes {.closure.}
      ## the axes of plot `id` ("new plot 2.plot 3": the window's mark, the plot's index)
    showView*: proc (panel: PanelId; view: Viewport): bool {.closure.}
      ## shows `view` in `panel`'s plot, as a pan or zoom of the user's would;
      ## false when the frontend has no plot for it
    showMapView*: proc (view: MapView): bool {.closure.}
      ## shows `view` in the map, as a pan or zoom of the user's would; false
      ## when the frontend has no map

# ---------------------------------------------------------- the list --

proc toolList*(): string =
  ## The JSON text `tools/list` answers with.
  var shotEnum = newJArray()
  for t in ShotTargets: shotEnum.add newJString(t)
  var parts = newJArray()
  for p in StateParts: parts.add newJString(p)
  let tools = %*[
    {"name": "command",
     "description": "Do one thing the windows do: open or list files, show a file, a " &
       "record or a trace, change a panel's view, display, gain, clip percentile, density " &
       "colour map, display presets, filters (\"processing\": " &
       "DC removal, low-cut, high-cut, band-pass, notches; raw or processed; Aux filtered " &
        "or not), correlate with the selected reference (\"correlate\": true or false), " &
        "display header, sort or trace filter, kill or reverse traces (kept beside " &
        "the file, which is never " &
       "changed), select traces, load survey files, move the map, show or hide its " &
       "layers, select or hover points on it, show a point's record. The arguments are " &
       "the command: " &
       "its \"kind\" and the fields that kind takes. A panel (1 is the Seismic window) " &
       "keeps what is not given: {\"kind\": \"display\", \"display\": {\"mode\": " &
       "\"density\"}} changes the mode only. \"panel\" defaults to 1; \"edit traces\" " &
       "without \"edited\" edits the selected traces of the panel's file, and \"on\" " &
       "defaults to true; \"map layer\" without \"shown\" shows it. A relative path is " &
       "read against the program's folder (`state`'s program.folder): the program may " &
       "run on another machine than you, with other paths. Trace ids are survey-wide: " &
       "`state` gives each file's firstTrace and each panel's positions (the trace " &
       "index in its file at each position, in the order shown). Returns at once with " &
       "what the program said; what reads data finishes later: call `wait`. Refused: " &
       "whatever writes a file, and the user's preferences and window layout.",
     "inputSchema": commandSchema()},
    {"name": "state",
     "description": "What viewSEG holds now: its own folder and working folder " &
        "(program, including shortcuts: each gesture's group, keys and what it does), " &
        "the file list (fileList), the open files (files), the panels " &
       "(panels: the file, record, layout, view, display and gain, filters, display header, " &
       "order, trace filter, polarity, the traces at each position, the edits, whether " &
       "the picture is complete), the selection, the map (its view, its layers, each " &
       "in its group, Preplot (the survey files) or Recorded (the seismic files' own " &
       "positions), shown or hidden by its own toggle and drawn or not, the groups " &
       "hidden, the template box: the spread planned for the record on show, its X or O " &
       "record and stations, read or generated, the folder's shots: its files read and the " &
       "survey's sources that have one, the filters shown on the record shown with what " &
       "each found, the points selected and hovered), the jobs, " &
       "the newest messages, the survey, and the Headers window (headers: the tab shown, " &
       "what it has on screen, the traces its Trace tab is about and what its reader read " &
       "of them, and the facts its Summary gives of the file the plot shows), and what " &
       "is remembered about files (memory: as the File memory window last listed it; the " &
       "command \"list file memory\" reads it again), and the named display presets " &
       "(displayPresets: each one's name and display; each panel's displayPreset names the " &
        "one it shows, \"\" for none). The compare window (compare: slot A, slot B, " &
        "the correlation table, and why a difference is not shown). All parts unless some " &
        "are named.",
     "inputSchema": {"type": "object", "properties": {
       "parts": {"type": "array", "items": {"type": "string", "enum": parts},
         "description": "the parts to give; all when not given"},
       "messages": {"type": "integer", "minimum": 0, "maximum": MaxMessages,
         "description": "how many of the newest messages (default " & $DefaultMessages & ")"},
       "since": {"type": "integer", "minimum": 0,
         "description": "only the messages from this serial on"},
       "limit": {"type": "integer", "minimum": 1, "maximum": MaxListed,
         "description": "the longest list given: files listed, positions, selected " &
           "traces and points, edits (default " & $DefaultListed & ")"}},
       "additionalProperties": false}},
    {"name": "headers",
     "description": "One trace's keys (geometry, stations, offset, status) and every " &
       "header field of it as the file has it (block, field, value, byte offset). Name " &
       "the trace by its survey-wide id (\"trace\"), by a panel's position " &
       "(\"panel\", \"position\": 0 is the leftmost), or by an open file's id and its " &
       "index in that file (\"file\", \"index\").",
     "inputSchema": {"type": "object", "properties": {
       "trace": {"type": "integer", "minimum": 0},
       "panel": {"type": "integer", "minimum": 1},
       "position": {"type": "integer", "minimum": 0},
       "file": {"type": "integer", "minimum": 1},
       "index": {"type": "integer", "minimum": 0}},
       "additionalProperties": false}},
    {"name": "screenshot",
     "description": "A PNG of what the user sees now: the whole window, the Seismic " &
       "window's picture of the traces alone (\"plot\": its pixels are the data, at " &
       "the panel's view), or one window (\"map\" is the Map window, \"headers\" the " &
       "Headers window). Call `wait` first " &
       "after a command that " &
       "reads data.",
     "inputSchema": {"type": "object", "properties": {
       "window": {"anyOf": [{"type": "string", "enum": shotEnum},
           {"type": "string", "pattern": "^fft [1-9][0-9]{0,3}$"},
           {"type": "string", "pattern": "^new plot [1-9][0-9]{0,3}$"}],
         "description": "what to take (default \"window\"): \"spectrum\" is the live " &
           "spectrum panel, \"fft\" the FFT window opened last, \"fft 2\" FFT window 2, " &
           "\"new plot 3\" analysis window 3 (New plot)"},
       "maxSize": {"type": "integer", "minimum": 64, "maximum": MaxShotSide,
         "description": "the longest side in pixels; larger pictures are scaled down " &
           "(default " & $DefaultShotSide & ")"}},
       "additionalProperties": false}},
    {"name": "wait",
     "description": "Waits until no job runs or waits, every panel's picture is " &
       "complete (read, sorted and drawn) and the Headers window's reader has read what " &
       "it has on screen, at least one frame after the last command; " &
       "or until the timeout. Says whether it is idle, and what is still going if not.",
     "inputSchema": {"type": "object", "properties": {
       "timeout": {"type": "number", "minimum": 0, "maximum": MaxWaitSeconds,
         "description": "seconds (default " & $DefaultWaitSeconds & ")"}},
       "additionalProperties": false}}]
  $(%*{"tools": tools})

# ------------------------------------------------------------ helpers --

func isShotTarget*(t: string): bool =
  ## Whether `screenshot` can take `t`: one of `ShotTargets`, or "fft N",
  ## FFT window N.
  if t in ShotTargets: return true
  for (prefix, longest) in [("fft ", 8), ("new plot ", 13)]:
    if t.len in prefix.len + 1 .. longest and t.startsWith(prefix) and
        t[prefix.len] in {'1' .. '9'}:
      for c in t.substr(prefix.len):
        if c notin Digits: return false
      return true
  false

proc args(text: string; n: var JsonNode): string =
  ## Parses a call's arguments into `n`; "" when they are a JSON object.
  result = parseBounded(text, n)
  if result.len == 0 and n.kind != JObject: result = "the arguments are an object"

proc intArg(n: JsonNode; key: string; default, lo, hi: int; problems: var seq[string]): int =
  ## The integer `n[key]` within `lo .. hi`, `default` when not given.
  result = default
  let v = n.getOrDefault(key)
  if v != nil:
    if v.kind != JInt: problems.add key & ": an integer"
    elif v.num < lo or v.num > hi: problems.add key & ": from " & $lo & " to " & $hi
    else: result = int(v.num)

proc refused(problems: openArray[string]): string =
  textResult("refused: " & problems.join("; "), isError = true)

func clipped(xs: openArray[int]; limit: int): JsonNode =
  result = newJArray()
  for i in 0 ..< min(xs.len, limit): result.add newJInt(xs[i])

# ------------------------------------------------------------- command --

proc prefill(state: AppState; given: Command; c: var Command) =
  ## What a command of `c`'s kind keeps when not given: its panel's display,
  ## filters, display header, view, trace filter, order and polarity now (`c` is
  ## fresh; `given` is the command as first read, for its panel).
  if c.kind in PanelKinds:
    c.panel = if given.panel == NoPanel: MainPanel else: given.panel
    let k = state.findPanel(c.panel)
    if k >= 0:
      template p: untyped = state.panels[k]
      c.view = p.view
      c.header = p.header
      if p.layers.len > 0:
        c.display = p.layers[0].display
        c.filter = p.layers[0].filter
        c.order = p.layers[0].order
        c.reverse = p.layers[0].reversed
        c.processing = p.layers[0].processing
  case c.kind
  of ckEdit, ckOwnFilter, ckTimeShift: c.on = true
  of ckMapView: c.mapView = state.map.view
  of ckMapLayer: c.shown = true
  of ckSpectrum:
    c.spectrumOf = if given.spectrumOf == NoPanel: MainPanel else: given.spectrumOf
    c.spectrumShow = state.settings.spectrum.window
  of ckSpectrumDisplay:
    c.spectrum = given.spectrum
    let w = state.findSpectrum(given.spectrum)
    if w >= 0:
      c.spectrumShow = state.spectra[w].display
      c.frozen = state.spectra[w].frozen
  of ckCloseSpectrum, ckSpectrumCursor: c.spectrum = given.spectrum
  of ckStepTrace: (c.spectrumOf, c.stepBy) = (MainPanel, 1)
  of ckOpenPlot: c.plotOf = if given.plotOf == NoPanel: MainPanel else: given.plotOf
  of ckPlotDisplay, ckPlotCursor:
    # what the window has, so that what is not given stays
    c.plot = given.plot
    let w = state.findPlot(given.plot)
    if w >= 0:
      c.plotParams = state.plots[w].params
      c.plotFrozen = state.plots[w].frozen
      c.plotCursor = state.plots[w].cursor
      c.plotCursorOn = state.plots[w].cursorOn
  of ckClosePlot: c.plot = given.plot
  of ckSpectrumPanel: c.onScreen = true
  of ckAuxWindow: c.onScreen = true
  of ckCompareDisplay: c.compareShow = state.compareOptions
  of ckCompareWindow: c.compareOpen = true
  of ckSubfolders: c.subfolders = true
  of ckCorrelate:
    c.correlate = true
    if given.panel == NoPanel: c.panel = MainPanel
  of ckSetCompare:
    c.compareSlot = if given.compareSlot == cwBoth: cwA else: given.compareSlot
    c.compareTrace = given.compareTrace
  of ckJoin, ckSelectUnmatched:
    # the file the plot shows, and the join window's options
    let i = state.shownFile(state.findPanel(MainPanel))
    let file = if i >= 0: state.sessions[i].id else: NoSession
    if c.kind == ckJoin: (c.joinFile, c.joinOptions) = (file, state.settings.join)
    else: c.unmatchedOf = file
  else: discard

proc fromProgram(path: string): string =
  ## `path` made absolute against the program's folder, when it is relative.
  if path.len == 0 or path.isAbsolute: path
  else: normalizedPath(getAppDir() / path)

proc selectedIn(state: AppState; panel: PanelId): seq[int] =
  ## The selected traces of the file `panel` shows, survey-wide ids, ascending.
  let k = state.findPanel(panel)
  let i = if k >= 0: state.shownFile(k) else: -1
  if i >= 0:
    for t in state.selection.selected:
      if t in state.sessions[i]: result.add t
  result.sort()

func correlateSentence(state: AppState): string =
  ## What the last correlate command left: the raw record, a job under way, the
  ## correlated record, or why it cannot.
  if not state.correlateOn: return "Showing the raw record."
  if state.correlateNote.len > 0: return state.correlateNote
  if state.correlating: return "Correlating with the selected reference."
  "Showing the correlated record."

proc runCommand*(state: var AppState; fe: Frontend; arguments: string;
    applied: var bool): string =
  ## The `command` tool: decodes the command, fills what is not given from
  ## the state, and applies it as a window's command is (a view through the
  ## frontend, which owns the plot's view, when it has one), as agent
  ## control's: it changes what is shown, and nothing that is saved.
  ## `applied` is set when it was. The answer says what the program logged
  ## meanwhile.
  var n: JsonNode
  var why = args(arguments, n)
  if why.len > 0: return refused([why])
  var kind: CommandKind
  why = kindOf(n, kind)
  if why.len > 0: return refused([why])
  var problems: seq[string]
  var first = newCommand(kind)
  decodeFields(n, first, problems)
  if problems.len > 0: return refused(problems)
  var c = newCommand(kind)
  state.prefill(first, c)
  decodeFields(n, c, problems)
  if problems.len > 0: return refused(problems)
  if kind in {ckEdit, ckOwnFilter, ckTimeShift} and not n.hasKey("edited"):
    c.edited = state.selectedIn(c.panel)
  if kind == ckOwnFilter and not n.hasKey("processing"):
    c.processing = Processing()
  case kind
  of ckOpen, ckBrowse, ckLoadSurvey:
    for p in c.paths.mitems: p = fromProgram(p)
  of ckShowFile, ckShowTrace: c.path = fromProgram(c.path)
  of ckTreatAs: c.treatPath = fromProgram(c.treatPath)
  of ckJoin:
    for f in c.joinFiles.mitems: f.path = fromProgram(f.path)
    # Not given: what the headers say, worked out by the import as it reads
    # the files (as the window does for a unit nobody chose).
    if not n.hasKey("joinUnits"):
      c.joinUnits = JoinUnits(surveyFromHeaders: true, fileFromHeaders: true)
  of ckSurveyUnits:
    for f in c.unitsOf.mitems: f.path = fromProgram(f.path)
  of ckChooseUnit:
    for p in c.unitChoice.survey.mitems: p = fromProgram(p)
    if c.unitChoice.file.len > 0: c.unitChoice.file = fromProgram(c.unitChoice.file)
  else: discard
  c.origin = coAgent # what it changes is for the session only: core decides (`keeps`)
  let before = state.log.nextSerial
  if kind == ckView and fe.showView != nil and fe.showView(c.panel, c.view):
    discard # the frontend moves its plot next frame and reports the view (ckView)
  elif kind == ckMapView and fe.showMapView != nil and fe.showMapView(c.mapView):
    discard # likewise the map
  else:
    state.apply c
  applied = true
  var said = newJArray()
  var ignored = false
  for e in state.log.since(before):
    said.add %*{"severity": $e.severity, "source": e.source, "text": e.text}
    if e.source == "commands" and e.severity >= sevWarning: ignored = true
  var done = %*{"command": $kind, "ignored": ignored, "messages": said}
  if kind == ckCorrelate: done["sentence"] = %correlateSentence(state)
  textResult($done, isError = ignored)

# --------------------------------------------------------------- state --

proc pictureOf(state: AppState; k: int; fe: Frontend): string =
  ## Where `panels[k]`'s picture stands: "complete", or what it waits for.
  template p: untyped = state.panels[k]
  let tiles = state.tiles(k)
  let (waitingFor, waiting) = state.reopening(p.id)
  if waitingFor.len > 0:
    result = if waiting: "waiting for its file to stop changing" else: "opening its file"
  elif p.layers.len == 0 or p.layers[0].source.kind != lsRecord or
      state.shownFile(k) < 0:
    result = "nothing shown"
  elif p.templateWait: result = "waiting for the check of the record against its template"
  elif not p.laidOut: result = "laying out"
  elif p.layout.traces == 0 or p.layout.samples == 0:
    result = "nothing to draw" # the trace filter hides every trace, or none has samples
  elif state.sorting(k): result = "sorting"
  elif not p.pending.isEmpty and (p.pending.gen != p.requestGen or tiles.len == 0 or
      tiles[^1].request != p.pending):
    result = "reading"
  elif p.relevel and p.levelAsked: result = "taking the record's level"
  elif p.view.columns <= 0 or p.view.rows <= 0:
    result = "no room to draw" # the window leaves the plot no pixels: nothing to wait for
  else:
    var drawn: Viewport
    if fe.drawnView != nil and fe.drawnView(p.id, drawn) and not drawn.sameSpans(p.view):
      result = "not drawn yet"
    else:
      result = "complete"

proc breaksJson(b: FirstBreaks; unit: SurveyUnit; fromSurvey: bool): JsonNode =
  ## What the first-break overlay's model is (`core/firstbreaks`), for the panel's `state`.
  result = %*{"state": $b.state, "picked": b.picked, "modelled": b.modelled,
    "offsetsFrom": $b.source, "words": b.modelWords(unit, fromSurvey),
    "unitFromSurvey": fromSurvey, "key": {"given": b.keyParts.given, "off": b.keyParts.off}}
  if b.state == bkDone:
    # what the guided passes read (`core/firstbreakjobs`)
    result["pickedOn"] = %($b.pickedOn)
    result["highCutHz"] = %b.highCutHz
    result["pickWindowMs"] = %b.pickWindowMs
    if b.pickNote.len > 0: result["pickNote"] = %b.pickNote
  result["model"] = %(if b.isGiven: "given" else: "fitted")
  if b.isGiven:
    let m = b.given
    result["velocityUnit"] = %unit.velocityUnit
    result["velocities"] = %(if m.segments == 2: @[m.v1, m.v2] else: @[m.v1])
    result["interceptMs"] = %m.interceptMs
    result["crossover"] = (if m.segments == 2: %m.crossover else: newJNull())
    result["picksUsed"] = %b.used
  elif b.segments > 0:
    result["velocityUnit"] = %unit.velocityUnit
    result["velocities"] = %(if b.segments == 1: @[b.fit.v1] else: @[b.fit.v1, b.fit.v2])
    result["interceptMs"] = %b.fit.interceptMs
    result["crossover"] = (if b.segments == 2: %b.fit.crossover else: newJNull())
    result["picksUsed"] = %b.used
  if b.hasModel:
    # what the rule found (`core/breakrule`): the same numbers the key, the marks and the
    # words use
    let r = b.rule
    func num(x: float64): JsonNode = (if x.isNaN: newJNull() else: %x)
    result["comparableTraces"] = %r.nComparable
    result["noBreakFoundTraces"] = %r.nNoBreak
    result["beyondRangeTraces"] = %r.nBeyond
    result["farOffModelTraces"] = %r.nFarOff
    result["givenModelMismatch"] = %(b.isGiven and r.mismatch)
    result["offModelTraces"] = %r.nOffModel
    result["offNeighbourTraces"] = %r.nOffNeighbours
    result["flaggedTraces"] = %r.nFlagged
    result["limitMs"] = num(r.limitMs)
    result["sigmaMs"] = num(r.sigmaMs)
    result["neighbourLimitMs"] = num(r.stationLimitMs)
    result["medianPickMinusModelMs"] = num(r.medianMs)
    result["secondPass"] = %b.twoPass
    result["sourceStatement"] = %r.statementWords
    result["earlyBearingDeg"] = num(r.earlyBearingDeg)
    result["earlyTowardAngleDeg"] = num(r.earlyTowardDeg)
    if b.passNote.len > 0: result["passNote"] = %b.passNote
    result["picksGuided"] = %(case b.guided
      of gdOwn: "by this model"
      of gdMaking: "by another model, while this one's are made"
      of gdFailed: "by another model: this one's could not be made")
    if b.guided != gdOwn: result["guideNote"] = %b.guideNote

proc noteSession(node: JsonNode; s: Session) =
  ## `path` is the file on disk. A derived session says so, and names its origin.
  node["path"] = %s.diskPath
  if s.derived:
    node["derived"] = %true
    node["origin"] = %s.origin

proc panelJson(state: AppState; k: int; fe: Frontend; limit: int): JsonNode =
  template p: untyped = state.panels[k]
  result = %*{"id": int(p.id), "title": state.windowTitle(p.id), "role": $p.role,
    "shows": $p.shows,
    "picture": state.pictureOf(k, fe), "laidOut": p.laidOut, "layout": toJson(p.layout),
    "view": toJson(p.view), "canGoBack": p.back.len > 0, "header": toJson(p.header),
    "correlate": state.correlateOn, "correlating": state.correlating,
    "level": toJson(p.level), "levelOver": p.levelSampling}
  let i = state.shownFile(k)
  if i >= 0:
    let s = state.sessions[i]
    var file = %*{"id": int(s.id), "firstTrace": s.base}
    file.noteSession(s)
    result["file"] = file
  if p.layers.len > 0:
    let layer = p.layers[0]
    if layer.source.kind == lsRecord:
      let g = layer.source.gather
      result["gather"] = %g
      if i >= 0:
        result["gathers"] = %state.sessions[i].gathers.len
        if g in 0 ..< state.sessions[i].records.len:
          result["record"] = toJson(state.sessions[i].records[g])
    result["display"] = toJson(layer.display)
    result["gainDbApplied"] = %layer.display.appliedGainDb(p.kind)
    if layer.display.firstBreaks:
      if state.breaksIndex(k) >= 0:
        result["firstBreaks"] = breaksJson(state.shownBreaks(k), state.breakOffsetUnit(k),
          state.breakUnitFromSurvey(k))
    let shown = state.settings.displayPresets.shownPreset(layer.display)
    result["displayPreset"] = %(if shown >= 0: state.settings.displayPresets[shown].name else: "")
    result["filter"] = toJson(layer.filter)
    if layer.filter.templateOnly: result["templateWait"] = %p.templateWait
    result["order"] = toJson(layer.order)
    result["reversed"] = %layer.reversed
    result["processing"] = toJson(layer.processing)
    result["filtersReach"] = %($state.filterReach(p))
    let note = layer.processing.filterNote(p.layout)
    if note.len > 0: result["processingNote"] = %note
  result["positionCount"] = %p.shown.len
  result["positions"] = clipped(p.shown, limit)
  if i >= 0:
    let e = state.editsOf(k)
    let all = 0 ..< state.sessions[i].len
    result["killed"] = clipped(e.listIn(teKilled, all), limit)
    result["reversedTraces"] = clipped(e.listIn(teReversed, all), limit)
    result["excludedTraces"] = clipped(e.listIn(teExcluded, all), limit)
    var own = newJArray()
    for f in e.filtersIn(all):
      if own.len >= limit: break
      own.add %*{"trace": f.trace, "place": $f.filter.place, "words": filterWords(f.filter),
        "band": $f.filter.spec.band, "dc": $f.filter.spec.dc,
        "f1": f.filter.spec.f1, "f2": f.filter.spec.f2, "f3": f.filter.spec.f3,
        "f4": f.filter.spec.f4}
    result["ownFilters"] = own
    result["allReversed"] = %e.allReversed
    result["canUndoEdit"] = %e.canUndo
    result["canRedoEdit"] = %e.canRedo
    result["undo"] = %e.undoText
    result["redo"] = %e.redoText
    let r = state.remembering(state.sessions[i].path)
    result["remembered"] = %*{"identityKnown": r.known, "confirmed": r.confirmed,
      "document": r.doc}

proc sweepJson(state: AppState; e: FileEntry): JsonNode =
  ## What the file list knows of a signature file from its header: its trigger (a `.vib`'s start
  ## second), controller, vibrator, line, station, shot, sweep id, length, state, pair and the
  ## controller's QC numbers. A `.vib` with a pair takes the controller, vibrator and QC of its
  ## `.dat`.
  let i = e.sweep
  if i.problem.len > 0: return %*{"problem": i.problem}
  let list = state.fileList
  var partner = list.pairs.getOrDefault(e.path)
  var info = i
  var controllerFrom = i.serialFrom
  if e.kind == fkVib and partner.len > 0:
    let d = list.find(partner)
    if d >= 0 and list.entries[d].kind == fkDat:
      info.controller = list.entries[d].sweep.controller
      info.vibrator = list.entries[d].sweep.vibrator
      info.qc = list.entries[d].sweep.qc
      controllerFrom = sfPair
  result = %*{"kind": (if e.kind == fkDat: "dat" else: "vib"),
    "trigger": timeText(i.triggerNs, if e.kind == fkDat: 9 else: 0),
    "triggerIsStart": i.timeIsStart,
    "controller": (if controllerFrom == sfNone: newJNull() else: %info.controller),
    "controllerFrom": (case controllerFrom
    of sfFile: "file"
    of sfFolder: "folder"
    of sfPair: "pair"
    else: ""),
    "vibrator": (if info.vibrator > 0: %info.vibrator else: newJNull()),
    "fileNumber": i.fileNumber, "samples": i.samples, "declared": i.declared,
    "intervalUs": i.intervalUs, "lengthS": float(i.samples) * i.intervalUs / 1e6,
    "complete": i.complete, "pulse": e.kind == fkDat and i.sweepNumber == 16,
    "pair": (if partner.len > 0: %partner else: newJNull())}
  if e.kind == fkDat:
    for (k, v) in [("line", i.line), ("station", i.station), ("shot", i.shotId),
        ("sweepId", i.sweepId)]:
      result[k] = if v > 0: %v else: newJNull()
  var limits = ""
  for l in info.qc.limits: limits.add $l
  result["qc"] = if info.qc.valid: %*{"forceAvgPct": int(info.qc.forceAvgPct),
    "thdMaxPct": int(info.qc.thdMaxPct), "limits": limits} else: newJNull()

proc fileListJson(state: AppState; limit: int): JsonNode =
  let l = state.fileList
  result = %*{"title": l.title, "folder": l.folder, "scanning": l.scanning,
    "chosen": l.chosen, "subfolders": l.recursive, "capped": l.capped,
    "looked": l.looked, "count": l.entries.len, "others": l.others,
    "unreadable": l.unreadable, "failed": l.failed, "error": l.error}
  var entries = newJArray()
  for i in 0 ..< min(l.entries.len, limit):
    let e = l.entries[i]
    var row = %*{"name": e.name, "path": e.path, "kind": $e.kind, "size": e.size,
      "status": $e.status, "new": e.isNew, "folder": e.folder}
    if e.kind in SignatureFileKinds: row["sweep"] = sweepJson(state, e)
    entries.add row
  result["entries"] = entries
  result["signatureFiles"] = %state.settings.files.listSignatureFiles
  result["pairs"] = %(l.pairs.len div 2)

proc pointJson(state: AppState; p: PointRef): JsonNode =
  ## A map point: its layer, role and index, and where it is.
  result = %*{"layer": int(p.layer), "role": $p.role, "point": p.point}
  let i = state.survey.find(p.layer)
  if i >= 0 and p.point in 0 ..< state.survey.layers[i].points[p.role].len:
    template ps: untyped = state.survey.layers[i].points[p.role]
    result["x"] = toJson(ps.index.x(p.point))
    result["y"] = toJson(ps.index.y(p.point))
    if p.point < ps.station.len: result["station"] = toJson(ps.station[p.point])

proc mapJson(state: AppState; limit: int): JsonNode =
  ## The map: its view, its layers (each role of each survey layer, shown or
  ## hidden, with its points), the points selected and hovered.
  let m = state.map
  let hiddenGroups = state.settings.map.hiddenGroups
  var groups = newJArray()
  for g in hiddenGroups: groups.add %($g)
  result = %*{"view": toJson(m.view), "canGoBack": m.back.len > 0,
    "highlightShown": m.shown(HighlightKey), "groupsHidden": groups}
  var layers = newJArray()
  for i in 0 ..< state.survey.layers.len: # by index: `for l in` copies every layer
    template l: untyped = state.survey.layers[i]
    for role in PointRole:
      if l.points[role].len > 0:
        let key = l.keyOf(role)
        layers.add %*{"layer": int(l.id), "name": l.name, "kind": $l.kind,
          "group": $l.groupOf, "mapLayer": toJson(key), "points": l.points[role].len,
          "shown": m.shown(key), "drawn": m.drawn(hiddenGroups, l, role)}
  result["layers"] = layers
  # The template box: the spread planned for the record on show.
  var spread = %*{"shown": state.settings.map.templateBox}
  if state.settings.map.templateBox:
    let sp = state.shownSpread
    spread["domain"] = %($sp.domain)
    spread["record"] = %sp.record
    spread["planned"] = %sp.stations
    spread["placed"] = %sp.places.len
    spread["generated"] = %sp.generated
    spread["byPlace"] = %sp.byPlace
    spread["from"] = %sp.source
    spread["made"] = %state.spreads.words
  result["template"] = spread
  # The units the files name, and whether they disagree.
  var units = newJArray()
  for (what, u) in state.unitSources: units.add %*{"from": what, "unit": $u}
  var heads = newJArray() # what survey files' headers say (`read survey units`)
  for h in state.heads:
    heads.add %*{"path": h.file.path, "read": h.done, "unit": $h.head.unit,
      "said": h.head.said, "problem": h.problem}
  result["units"] = %*{"named": units, "disagree": state.unitsDisagree, "surveyFiles": heads}
  # The folder's shots: its files read, and the survey's sources that have one.
  template x: untyped = state.shots
  result["folderShots"] = %*{"shown": state.settings.map.folderShots, "filesRead": x.shotFiles,
    "toRead": x.pending.len + x.jobPaths.len, "notAnswering": x.later.len,
    "folderNotAnswering": x.waiting,
    "sourcesWithFile": x.pointRefs.len}
  # The filters shown, on the record shown: what each found.
  if state.settings.map.filters != {}:
    let hits = state.filterHits
    var filters = newJObject()
    for f in state.settings.map.filters:
      filters[$f] = %*{"state": $hits[f].state, "count": hits[f].count, "note": hits[f].note,
        "traces": clipped(hits[f].traces, limit)}
    result["filters"] = filters
    let n = state.recordQc.noise
    if n.ready:
      result["noise"] = %*{"area": n.areaWords, "notes": n.notesWords,
        "choice": NoiseChoiceNames[n.asked.choice], "judged": n.judged, "inArea": n.inArea,
            "outsideTemplate": n.outsideCount,
        "outsideTemplate": n.outsideCount,
        "sensorOrStationUnknown": n.unknown, "incompleteNodes": n.incomplete,
        "noSamples": n.unusable, "notJudged": n.notJudged, "noisy": n.noisy, "weak": n.weak,
        "louder": n.louderCount, "lines": n.lines, "linesReached": n.linesReached}
  var selected = newJArray()
  for i in 0 ..< min(state.selection.points.len, limit):
    selected.add state.pointJson(state.selection.points[i])
  result["selectedCount"] = %state.selection.points.len
  result["selected"] = selected
  var hovered = newJArray()
  for p in state.selection.hoverPoints: hovered.add state.pointJson(p)
  result["hovered"] = hovered

func evenlyOf(n, limit: int): seq[int] =
  ## At most `limit` indices of `0 ..< n`, evenly, the first and the last
  ## among them.
  if n <= limit or limit < 2:
    for i in 0 ..< min(n, max(limit, 1)): result.add i
  else:
    for k in 0 ..< limit: result.add int(round(float64(k) * float64(n - 1) /
      float64(limit - 1)))

func rangeJson(lo, hi: float64): JsonNode =
  ## `[lo, hi]`; null when either is not a number (the plot was not drawn, or its
  ## axis has no numbers: nothing to read on it).
  if lo.classify in {fcNan, fcInf, fcNegInf} or hi.classify in {fcNan, fcInf, fcNegInf}:
    newJNull()
  else: %*[lo, hi]

proc plotJson(w: AnalysisWindow; fe: Frontend; units: UnitSystem; limit: int): JsonNode =
  ## An analysis window: what it shows and how, and its numbers: each plot's
  ## curves at most `limit` points (evenly), an image's size, axes and, per
  ## column (at most `limit`), the y of its largest value.
  template r: untyped = w.result
  var plots = newJArray()
  for p in r.plots:
    let at = evenlyOf(p.xs.len, limit)
    var xs = newJArray()
    for i in at: xs.add toJson(p.xs[i])
    var curves = newJArray()
    for c in p.curves:
      var ys = newJArray()
      if c.xs.len > 0:
        # its own xs (a limit's two ends): all of them
        var own = newJArray()
        for i in evenlyOf(c.xs.len, limit):
          own.add toJson(c.xs[i])
          ys.add toJson(if i < c.ys.len: c.ys[i] else: NaN)
        curves.add %*{"name": c.name, "style": $c.style, "xs": own, "ys": ys}
      else:
        for i in at: ys.add toJson(if i < c.ys.len: c.ys[i] else: NaN)
        curves.add %*{"name": c.name, "style": $c.style, "ys": ys}
    var axes = PlotAxes(xLo: NaN, xHi: NaN, yLo: NaN, yHi: NaN)
    if fe.plotAxes != nil: axes = fe.plotAxes("new plot " & $w.id & ".plot " & $plots.len)
    plots.add %*{"title": p.title, "x": p.xLabel, "y": p.yLabel, "xs": xs, "curves": curves,
      "xRange": rangeJson(axes.xLo, axes.xHi), "yRange": rangeJson(axes.yLo, axes.yHi),
      "zoomed": {"x": axes.xZoomed, "y": axes.yZoomed},
      "explain": explainPane(w, units, plots.len)}
  result = %*{"id": w.id, "title": w.title, "view": $w.view, "frozen": w.frozen,
    "params": toJson(w.params), "traces": clipped(w.traces, limit), "reference": w.reference,
    "filters": w.filters, "waiting": w.waiting, "cursor": toJson(w.cursor),
    "cursorOn": w.cursorOn,
    "problem": r.problem, "note": r.note, "warning": r.warning, "measuredAgainst": r.against,
        "used": r.used, "leftOut": r.leftOut, "notNumber": r.notNumber, "zeroed": r.zeroed,
    "passedBy": r.passedBy, "notDrawn": r.notDrawn,
    "dtMs": toJson(r.dtMs), "plots": plots, "explain": explainWindow(w, units)}
  if r.table.len > 0:
    var rows = newJArray()
    for row in r.table:
      var cells = newJArray()
      for c in row: cells.add newJString(c)
      rows.add cells
    result["table"] = rows
  if w.sweep.given:
    # which sweep a signature file's window is of (null: the file does not give it)
    let i = w.sweep
    func given(n: int64): JsonNode = (if n > 0: %n else: newJNull())
    result["sweep"] = %*{"triggerUtc": (if i.triggerNs == 0: newJNull()
      else: %timeText(i.triggerNs, (if i.fromStart: 0 else: 9))),
      "triggerIsRecordingStart": i.fromStart, "controller": given(i.controller),
      "vibrator": given(i.vibrator), "line": given(i.line), "station": given(i.station),
      "shotId": given(i.shotId), "sweepId": given(i.sweepId), "words": i.identityLine,
      "copyLine": w.identityCopy}
  if r.view == avVibrator and r.problem.len == 0 and r.qc.rows.len > 0:
    # the verdict, judged the way a vibrator controller's QC reports it
    let q = r.qc
    var limits = newJArray()
    for row in q.rows:
      limits.add %*{"limit": $row.limit, "measured": toJson(row.measured),
        "bound": toJson(row.bound), "unit": row.limit.unitOf.strip,
        "pass": (if row.status == qsNotJudged: newJNull() else: %(row.status ==
            qsPass)),
        "status": $row.status, "worstWindowMs": toJson(row.atMs),
            "why": row.why}
    let s = q.stats
    result["verdict"] = %($q.verdict)
    result["verdictLine"] = %q.line
    result["judged"] = %r.judged # the signal judged: GF, or GF (M, B)
    result["bothSignals"] = %r.bothSignals # the unit has both: `roles.judge` chooses
    result["judgeWarning"] = %r.judgeWarning
    result["qcLimits"] = limits
    result["windowStats"] = %*{"windowMs": toJson(s.windowMs),
        "windows": s.windows,
      "avgPhaseDeg": toJson(s.avgPhaseDeg), "peakPhaseDeg": toJson(
          s.peakPhaseDeg),
      "peakPhaseAtMs": toJson(s.peakPhaseAtMs),
      "avgDistortionPct": toJson(s.avgDistortionPct),
      "peakDistortionPct": toJson(s.peakDistortionPct),
      "peakDistortionAtMs": toJson(s.peakDistortionAtMs),
      "avgForce": toJson(s.avgForce), "minForce": toJson(s.minForce),
      "minForceAtMs": toJson(s.minForceAtMs), "peakForce": toJson(s.peakForce),
      "peakForceAtMs": toJson(s.peakForceAtMs), "avgForcePct": toJson(
          s.avgForcePct),
      "minForcePct": toJson(s.minForcePct), "peakForcePct": toJson(
          s.peakForcePct),
      "hundredPctForce": toJson(q.hundredPct), "forceNote": q.forceNote}
    result["band"] = %*{"hz": toJson(r.band.hz), "suggestedHz": toJson(
        r.band.suggestedHz),
      "largestChordHz": toJson(r.band.chordHz), "typed": r.band.typed,
      "exact": r.band.exact, "warning": r.band.warning, "uncertain": r.band.uncertain,
      "uncertaintyHz": toJson(r.band.uncertaintyHz)}
    if r.polarity.line.len > 0 or r.controller.len > 0:
      # a signature file's: the ground force's relation to the reference (reported, never
      # changed) and the controller's QC beside this analysis's
      result["polarity"] = %*{"kind": $r.polarity.kind,
        "meanPhaseDeg": toJson(r.polarity.meanPhaseDeg),
        "consistency": toJson(r.polarity.consistency), "reversedForAnalysis": r.polarity.reversed,
        "line": r.polarity.line}
      var ctl = newJArray()
      for c in r.controller:
        ctl.add %*{"measure": c.label, "thisWindow": c.viewseg, "controller": c.controller}
      result["controller"] = ctl
      result["controllerNote"] = %r.controllerNote
      result["hundredForce"] = %r.hundredWords
      result["hundredHint"] = %r.hundredHint
      result["hundredProblem"] = %r.hundredProblem
      result["forceScale"] = %r.scaleWords
    result["alignment"] = %*{"kind": r.alignment.kind, "shiftMs": toJson(
        r.alignment.shiftMs),
      "match": toJson(r.alignment.match), "words": r.alignment.words}
  if r.view == avCorrelation and r.plots.len > 0:
    # one entry per table row; null for a trace not drawn (the reference itself)
    var lags = newJArray()
    var verdicts = newJArray()
    var drawn = 0
    if r.table.len > 1:
      for row in r.table[1 .. ^1]:
        if row.len > 3 and row[3] == "not drawn":
          lags.add newJNull()
          verdicts.add newJNull()
        else:
          lags.add toJson(r.peakLagMs(drawn))
          verdicts.add newJString(r.verdictOf(drawn))
          inc drawn
    else:
      for c in 0 ..< r.plots[0].curves.len div 2:
        lags.add toJson(r.peakLagMs(c))
        verdicts.add newJString(r.verdictOf(c))
    result["peakLagMs"] = lags
    result["verdicts"] = verdicts
  if not r.image.isEmpty:
    let img = r.image
    var peaks = newJArray()
    var times = newJArray()
    for col in evenlyOf(img.cols, limit):
      var best = 0
      for row in 0 ..< img.rows:
        if img.valueAt(col, row) > img.valueAt(col, best): best = row
      times.add toJson(img.x0 + float64(col) * img.dx)
      peaks.add toJson(img.y0 + float64(best) * img.dy)
    result["image"] = %*{"columns": img.cols, "rows": img.rows, "x": img.xLabel,
      "y": img.yLabel, "unit": img.unit, "x0": img.x0, "dx": img.dx, "y0": img.y0,
      "dy": img.dy, "lo": img.lo, "hi": img.hi, "peakXs": times, "peakYs": peaks}

proc spectrumJson(w: SpectrumWindow; units: UnitSystem; limit: int): JsonNode =
  ## A spectrum window: what it shows and how, and its numbers: per curve
  ## the amplitude at most `limit` points from 0 Hz to Nyquist (the largest
  ## of each run of `step` bins, so a peak is kept), and its peak.
  template sp: untyped = w.spectrum
  let bins = sp.raw.len
  let step = if bins > limit: (bins + limit - 1) div limit else: 1
  proc curve(amps: seq[float64]; reference: float64): JsonNode =
    if amps.len == 0: return newJNull()
    var lin = newJArray()
    var k = 0
    while k < amps.len:
      var top = 0.0
      for j in k ..< min(k + step, amps.len): top = max(top, amps[j])
      lin.add toJson(top)
      k += step
    let peak = amps.peakBin
    %*{"amplitude": lin, "peakHz": (if peak >= 0: toJson(float(peak) * sp.binHz) else: newJNull()),
      "peakAmplitude": toJson(amps.peakOf),
      "peakDb": toJson(levelDb(amps.peakOf, reference))}
  proc gains(hz, g: seq[float64]): JsonNode =
    # on its own grid, at most `limit` points: the smallest of each run, at
    # its frequency, so a notch is kept
    if g.len == 0 or g.len != hz.len: return newJNull()
    let run = max(1, (g.len + limit - 1) div max(limit, 1))
    var at, gain = newJArray()
    var k = 0
    while k < g.len:
      var least = k
      for j in k ..< min(k + run, g.len):
        if g[j] < g[least]: least = j
      at.add toJson(hz[least])
      gain.add toJson(g[least])
      k += run
    result = %*{"hz": at, "gain": gain, "points": g.len}
  let reference = max(sp.raw.peakOf, sp.processed.peakOf)
  proc atBin(amps: seq[float64]; k: int): JsonNode =
    if k notin 0 ..< amps.len: newJNull()
    else: %*{"amplitude": toJson(amps[k]), "db": toJson(levelDb(amps[k], reference))}
  let k = w.cursor.x
  let cursor = if not w.cursor.held: %*{"held": false}
               else: %*{"held": true, "bin": k, "hz": toJson(float64(k) * sp.binHz),
                 "heldHz": toJson(w.cursorHz), "curve": w.cursor.y,
                 "curveName": $w.cursorCurve, "raw": sp.raw.atBin(k),
                 "processed": sp.processed.atBin(k)}
  result = %*{"id": w.id, "title": w.title, "live": w.id == LiveSpectrum,
    "onScreen": (if w.id == LiveSpectrum: w.shown else: true), "frozen": w.frozen,
    "display": toJson(w.display), "of": $w.chosen, "file": w.file, "record": w.record,
    "traces": clipped(w.traces, limit), "traceCount": w.traces.len, "filters": w.filters,
    "waiting": w.waiting, "requests": w.asks,
    "spectrum": {"asked": sp.asked, "averaged": sp.averaged, "killed": sp.killed,
      "dead": sp.dead, "failed": sp.failed, "atOtherInterval": sp.atOtherInterval,
      "readFromFile": sp.read, "dtMs": toJson(sp.dtMs), "fromMs": toJson(sp.fromMs),
      "toMs": toJson(sp.toMs), "windowSamples": sp.windowLen, "nfft": sp.nfft,
      "binHz": toJson(sp.binHz), "bins": bins, "step": step,
      "nyquistHz": toJson(if sp.dtMs > 0: 500 / sp.dtMs else: NaN),
      "raw": curve(sp.raw, reference), "processed": curve(sp.processed, reference),
      "processedWith": (if sp.processed.len > 0: sp.filters else: ""),
      "filtersAsked": sp.filters, "filterAux": sp.filterAux, "filtered": sp.filtered,
      "passedBy": sp.passedBy, "filterNote": sp.filterNote,
      "filterProblem": sp.filterProblem, "response": gains(sp.responseHz, sp.response),
      "problem": sp.problem},
    "filterWords": w.filterText, "cursor": cursor,
    "explain": explainSpectrumWindow(w, units)}

proc vendorJson(v: VendorShown): JsonNode =
  ## The blocks the vendor maps decode, each under its map; the fields by name
  ## with their values.
  result = newJArray()
  for b in v.blocks:
    var fields = newJArray()
    for f in b.fields:
      fields.add %*{"name": f.name, "value": f.value, "unit": f.unit, "label": f.label,
        "flags": f.flags}
    result.add %*{"map": b.map, "mapFile": b.mapFile, "block": b.name, "fields": fields}

proc headersJson(state: AppState; limit: int): JsonNode =
  ## The Headers window: its tab and toggles, what it has on screen (what its
  ## reader reads), the traces its Trace tab is about and what was read of
  ## them, and the facts its Summary gives of the file the plot shows (read
  ## with the file: nothing is read here).
  let view = state.settings.headers
  template ins: untyped = state.inspection
  result = %*{"tab": $view.tab, "traceTab": $view.traceTab,
    "followPointer": view.followPointer, "asDisplayed": view.asDisplayed,
    "onScreen": toJson(ins.parts)}
  var answered = newJArray()
  let statuses = state.surveyStatuses(ins.answer.traces)
  for i in 0 ..< min(ins.answer.traces.len, limit):
    let d = ins.answer.traces[i]
    answered.add %*{"trace": d.id, "file": d.file, "index": d.trace, "fields": d.rows.len,
      "samples": d.samples.len, "samplesLeftOut": d.cut, "asDisplayed": d.displayed,
      "joined": toJson(d.joined), "survey": $statuses[i], "problem": d.problem,
          "vendor": vendorJson(d.vendor)}
  result["trace"] = %*{"chosenBy": $ins.chosen.by, "traces": clipped(ins.chosen.traces, limit),
    "total": ins.chosen.total, "reading": ins.waiting, "read": answered}
  result["notAnswering"] = %state.headersWait.words # "" while its reader answers
  template tab: untyped = ins.answer.table
  var rows = newJArray()
  for r in 0 ..< min(tab.rowTraces.len, limit):
    rows.add %*{"row": tab.first + r, "index": tab.rowTraces[r], "values": toJson(tab.values[r])}
  result["table"] = %*{"asked": toJson(ins.table), "file": tab.path, "view": toJson(tab.view),
    "count": tab.count, "traces": tab.traces.len, "rows": rows,
    "graphBuckets": tab.graphMin.len, "problems": toJson(tab.problems),
    "fields": tab.catalogue.len}
  let k = state.findPanel(MainPanel)
  let i = if k >= 0: state.shownFile(k) else: -1
  if i < 0:
    result["file"] = newJNull()
  else:
    let s = state.sessions[i]
    template facts: untyped = s.facts
    var f = %*{"id": int(s.id), "summary": toJson(facts.summary),
      "coordinateUnits": $unitOf(s.crs.units), "crs": s.crs.text.substr(0, 4095),
      "textualHeader": facts.textEncoding, "extendedTextualHeaders": facts.extendedText.len,
      "fileHeaderFields": facts.rows.len, "channelSets": facts.channelSets.len,
      "problems": toJson(facts.problems)}
    f.noteSession(s)
    let j = state.joinedOf(s.id)
    if j >= 0:
      let joined = state.joins[j]
      var files = newJArray()
      for jf in joined.files: files.add newJString(jf.path)
      f["join"] = %*{"files": files, "units": toJson(joined.units),
        "matched": joined.plan.matched, "seismic": joined.plan.seismic,
        "changed": joined.plan.changes}
    result["file"] = f

proc projectJson(state: AppState; limit: int): JsonNode =
  ## The `project` part: the project open (`open` false for none), its data
  ## folders, its survey and where it stands.
  let p = state.project
  var earlier = newJArray() # of the file the plot shows: other files once at its path
  let shown = state.shownFile(state.findPanel(MainPanel))
  if shown >= 0:
    for c in state.earlierOf(state.sessions[shown].path):
      earlier.add %*{"document": c.doc, "kept": keptWords(c.edits), "traces": c.traces,
        "opened": $c.opened}
  if not state.inProject:
    return %*{"open": false, "opening": state.projectOpening, "earlierOutputs": earlier}
  var folders = newJArray()
  for i, d in p.doc.data:
    let look = if i < p.folders.len: p.folders[i] else: PlaceLook()
    folders.add %*{"name": d.displayName, "path": d.path, "absolute": d.absolute,
      "state": $look.state, "foundAt": look.path}
  var files = newJArray()
  for i, c in p.doc.survey:
    let o = if i < p.originals.len: p.originals[i] else: OriginalLook()
    files.add %*{"copy": c.copy, "kind": $c.kind, "original": c.original.absolute,
      "state": $o.state, "foundAt": o.path, "size": c.size}
  result = %*{"open": true, "path": p.dir, "name": p.doc.name, "readOnly": p.readOnly,
    "whyReadOnly": p.whyReadOnly, "version": p.doc.version, "dataFolders": folders,
    "survey": {"files": files, "state": $p.survey, "note": p.surveyNote,
      "updateOffered": p.offer, "options": toJson(p.doc.options), "units": toJson(p.doc.units),
      "sources": p.doc.store.sources, "receivers": p.doc.store.receivers,
      "relations": p.doc.store.relations, "storeBytes": p.doc.store.bytes,
      "restoreMs": p.restoreMs},
    "displayPresets": (if p.doc.hasPresets: p.doc.displayPresets.len else: -1),
    "filters": p.doc.hasProcessing, "opening": state.projectOpening,
    "earlierOutputs": earlier}

proc vendorMapsJson(state: AppState): JsonNode =
  ## The `vendorMaps` part: the folders maps are loaded from, in order of
  ## preference, the maps loaded, and what went wrong with a map.
  let load = state.vendorLoad
  var folders = newJArray()
  for f in load.folders:
    folders.add %*{"path": f.dir, "from": $f.origin, "exists": f.there, "maps": f.loaded}
  var maps = newJArray()
  for m in load.maps:
    maps.add %*{"name": m.name, "file": m.file, "folder": m.folder, "from": $m.origin,
      "appliesTo": m.appliesTo}
  var problems = newJArray()
  for p in load.problems:
    problems.add %*{"file": p.file, "problem": p.text, "loaded": p.loaded}
  %*{"choice": state.vendorChoice.choiceWords, "folders": folders, "maps": maps,
    "problems": problems, "shadowed": load.shadowed,
    "loads": state.vendorGen}

proc signatureJson(f: SignatureFacts): JsonNode =
  ## What `state.files[]` says of a vibrator controller's signature file decoded in memory.
  let i = f.info
  let stopped = if f.kind == sgDat: (if i.complete: "" else: f.warnings.join(" "))
                elif f.endsInSweep: "the record ends inside the sweep" else: ""
  result = %*{"kind": (if f.kind == sgDat: "dat" else: "vib"),
    "samples": i.samples, "intervalUs": f.choice.intervalUs,
    "intervalAssumed": not f.intervalStated, "complete": i.complete and not f.endsInSweep,
    "stopped": stopped, "decodedAs": f.decodedAs, "traces": newJArray()}
  for t in f.traces: result["traces"].add %*{"name": t.name, "code": int(t.code), "unit": t.unit}
  if f.kind == sgDat:
    result["controller"] = %i.controller
    result["vibrator"] = %i.vibrator
    result["fileNumber"] = %i.fileNumber
    result["trigger"] = %timeText(i.triggerNs)
    result["declared"] = %i.declared
    result["forceChannels"] = %true
    result["swapped"] = %f.choice.swapForces
  else:
    result["controller"] = (if i.serialFrom == sfNone: newJNull() else: %i.controller)
    result["controllerFrom"] = %(case i.serialFrom
      of sfFolder: "folder"
      of sfPair: "pair"
      else: "")
    result["fileCounter"] = %i.fileNumber
    result["recordingBegan"] = %timeText(i.triggerNs, 0)
    result["frames"] = %i.samples
    result["trigger"] = %*{"source": (case f.trigger.source
      of trEstimated: "estimated"
      of trGiven: "given"
      else: "none"), "frame": (if f.trigger.frame.isNaN: newJNull() else: %f.trigger.frame),
      "sigmaFrames": (if f.trigger.sigmaFrames.isNaN: newJNull() else: %f.trigger.sigmaFrames),
      "startHz": (if f.trigger.startHz.isNaN: newJNull() else: %f.trigger.startHz),
      "rateHzPerS": (if f.trigger.rateHzPerS.isNaN: newJNull() else: %f.trigger.rateHzPerS),
      "crossings": f.trigger.crossings}
    result["timeZero"] = %f.trigger.timeZero
    result["primarySet"] = %"B"
    result["pair"] = if f.pair.len > 0: %f.pair else: newJNull()

proc propertiesJson(state: AppState): JsonNode =
  ## The properties of the file the Seismic window shows, as its Headers
  ## window's Summary gives them (sections of lines: what it is, how it was
  ## opened, its coordinates, the record shown), with the options it opens
  ## with and what its open did, as values; null when no file is shown.
  let k = state.findPanel(MainPanel)
  let i = if k >= 0: state.shownFile(k) else: -1
  if i < 0: return newJNull()
  let s = state.sessions[i]
  let gather = state.panels[k].layers[0].source.gather
  var sections = newJArray()
  var section: JsonNode = nil
  for l in summaryLines(s, gather, state.joins, state.unitChoices):
    if l.heading:
      section = %*{"title": l.label, "lines": newJArray()}
      sections.add section
    elif section != nil:
      section["lines"].add %*{"label": l.label, "value": l.value}
  result = %*{"file": int(s.id), "sections": sections,
    "openChoice": toJson(state.openChoiceOf(s.diskPath)), "opened": toJson(s.facts.opened)}
  result.noteSession(s)

proc slotJson(slot: CompareSlot): JsonNode =
  ## One compare slot: what it holds, not every sample.
  %*{"filled": slot.filled, "waiting": slot.waiting, "problem": slot.problem,
    "file": slot.fileName, "path": slot.path, "trace": slot.trace,
    "record": slot.recordText, "channel": slot.channelText, "station": slot.stationText,
    "dtMs": toJson(slot.dtMs), "t0Ms": toJson(slot.t0Ms), "fromMs": toJson(slot.fromMs),
    "toMs": toJson(slot.toMs), "samples": slot.samples.len, "reversed": slot.reversed,
    "filtered": slot.filtered,
    "filter": slot.filterWords, "shift": slot.shiftWords}

proc compareJson(state: AppState): JsonNode =
  ## Both slots and the correlation table.
  let p = state.comparePicture
  let t = p.table
  %*{"open": state.compareOpen, "slotA": slotJson(state.compareA),
    "slotB": slotJson(state.compareB), "chipA": state.compareChip(cwA),
    "chipB": state.compareChip(cwB),
    "table": {"available": t.available, "peak": toJson(t.peak), "shiftMs": toJson(t.shiftMs),
      "polarity": t.polarity, "whyNot": t.whyNot, "match": toJson(t.match.match),
      "matchShiftMs": toJson(t.match.shiftMs), "rotationDeg": toJson(t.match.rotationDeg),
      "words": t.matchWords},
    "refusal": p.refusal, "align": p.alignNote, "sameGrid": p.sameGrid,
    "options": toJson(state.compareOptions)}

proc stateReport*(state: AppState; fe: Frontend; arguments: string): string =
  ## The `state` tool.
  var n: JsonNode
  let why = args(arguments, n)
  if why.len > 0: return refused([why])
  var problems: seq[string]
  var wanted: HashSet[string]
  let parts = n.getOrDefault("parts")
  if parts == nil:
    for p in StateParts: wanted.incl p
  elif parts.kind != JArray:
    problems.add "parts: an array of " & StateParts.join(", ")
  else:
    for p in parts.elems:
      if p.kind != JString or p.str notin StateParts:
        problems.add "parts: each is one of " & StateParts.join(", ")
      else: wanted.incl p.str
  let count = intArg(n, "messages", DefaultMessages, 0, MaxMessages, problems)
  let since = intArg(n, "since", 0, 0, int.high, problems)
  let limit = intArg(n, "limit", DefaultListed, 1, MaxListed, problems)
  for key, _ in n.pairs:
    if key notin ["parts", "messages", "since", "limit"]:
      problems.add "no argument " & escapeJson(key.substr(0, 79))
  if problems.len > 0: return refused(problems)
  var r = newJObject()
  if "fileList" in wanted: r["fileList"] = state.fileListJson(limit)
  if "files" in wanted:
    var files = newJArray()
    for s in state.sessions:
      var f = %*{"id": int(s.id), "name": s.name, "traces": s.len,
        "firstTrace": s.base, "gathers": s.gathers.len}
      f.noteSession(s)
      if s.isSignature: f["signature"] = signatureJson(s.signature)
      files.add f
    r["files"] = files
  if "panels" in wanted:
    var panels = newJArray()
    for k in 0 ..< state.panels.len:
      # the Aux window's panel is listed while the window is open
      if state.panels[k].role != prAux or state.auxOpen:
        panels.add state.panelJson(k, fe, limit)
    r["panels"] = panels
  if "selection" in wanted:
    var selected: seq[int]
    for t in state.selection.selected: selected.add t
    selected.sort()
    r["selection"] = %*{"hover": state.selection.hover, "anchor": state.selection.anchor,
      "count": selected.len, "selected": clipped(selected, limit)}
  if "jobs" in wanted:
    var jobs = newJArray()
    for j in state.jobs.list:
      jobs.add %*{"id": int(j.id), "title": j.spec.title, "lane": $j.spec.lane,
        "state": $j.state, "done": j.progress.done, "total": j.progress.total,
        "phase": j.progress.phase, "error": j.error, "cancellable": j.spec.cancellable}
    r["jobs"] = jobs
  if "messages" in wanted:
    var messages = newJArray()
    let log = state.log
    let first = max(log.nextSerial - log.len, max(since, log.nextSerial - count))
    for e in log.since(first):
      messages.add %*{"serial": e.serial, "time": e.stamp, "severity": $e.severity,
        "source": e.source,
        "text": e.text, "where": e.loc.where}
    r["messages"] = messages
  if "program" in wanted:
    var working = ""
    try:
      working = getCurrentDir()
    except OSError:
      discard
    var versions = newJObject()
    for l in aboutLines(): versions[l.name] = %l.version
    var shortcuts = newJArray()
    for row in shortcutRows():
      shortcuts.add %*{"group": $row.group, "keys": row.keys, "what": row.what,
        "mouse": row.gesture == gsMouse}
    r["program"] = %*{"folder": getAppDir(), "workingFolder": working,
      "theme": state.settings.theme, "themes": state.themeNames, "versions": versions,
      "author": ProgramAuthor, "email": AuthorEmail, "copyright": CopyrightLine,
      "shortcuts": shortcuts}
  if "map" in wanted: r["map"] = state.mapJson(limit)
  if "survey" in wanted:
    var layers = newJArray()
    for l in state.survey.layers:
      layers.add %*{"id": int(l.id), "origin": $l.origin, "kind": $l.kind, "name": l.name,
        "path": l.path, "sources": l.points[prSource].len,
        "receivers": l.points[prReceiver].len, "counts": {
          "sources": toJson(l.counts[prSource]), "receivers": toJson(l.counts[prReceiver])}}
    r["survey"] = layers
  if "headers" in wanted: r["headers"] = state.headersJson(limit)
  if "properties" in wanted: r["properties"] = state.propertiesJson()
  if "displayPresets" in wanted:
    var list = newJArray()
    for p in state.settings.displayPresets:
      list.add %*{"name": p.name, "display": toJson(p.display)}
    r["displayPresets"] = list
  if "spectra" in wanted:
    var list = newJArray()
    for w in state.spectra: list.add spectrumJson(w, state.settings.units, limit)
    r["spectra"] = list
  if "plots" in wanted:
    var list = newJArray()
    for w in state.plots: list.add plotJson(w, fe, state.settings.units, limit)
    r["plots"] = list
  if "project" in wanted: r["project"] = state.projectJson(limit)
  if "compare" in wanted: r["compare"] = state.compareJson
  if "vendorMaps" in wanted: r["vendorMaps"] = state.vendorMapsJson
  if "memory" in wanted:
    let m = state.memoryList
    var files = newJArray()
    for i in 0 ..< min(m.records.len, limit):
      let f = m.records[i]
      files.add %*{"name": f.name, "path": f.path, "opened": $f.opened, "kept":
        keptWords(f.edits), "size": f.identity.size, "bytes": f.bytes, "gone": f.gone,
            "unreached": f.unreached,
        "looking": f.looking, "notAnswering": f.silent, "document": f.doc}
    r["memory"] = %*{"listed": m.listed, "listing": m.listing, "count": m.records.len,
      "files": files, "problems": m.problems}
  textResult($r)

# ------------------------------------------------------------- headers --

type
  HeaderCall* = object
    ## A `headers` call (`askTraceHeaders`): answered at once when it is
    ## refused, else once the job that reads the trace has ended
    ## (`headersAnswer`).
    answer*: string ## the tool's answer; "" while the trace is read
    job*: JobId ## the job that reads it
    head: JsonNode ## what the answer says besides what the job reads
    what: string ## "trace 6 of shot.sgy", for an answer that it could not be read

proc askTraceHeaders*(state: var AppState; arguments: string): HeaderCall =
  ## The `headers` tool: one trace's keys and header fields. The trace's
  ## headers are read from the file's map on a job, never here: a call
  ## that names a trace is answered by `headersAnswer` once the job has read
  ## it; one that does not is refused at once (`answer`).
  result = HeaderCall(job: NoJob)
  var n: JsonNode
  let why = args(arguments, n)
  if why.len > 0:
    result.answer = refused([why])
    return
  var problems: seq[string]
  for key, _ in n.pairs:
    if key notin ["trace", "panel", "position", "file", "index"]:
      problems.add "no argument " & escapeJson(key.substr(0, 79))
  var session = -1
  var index = -1
  if n.hasKey("trace"):
    let id = intArg(n, "trace", -1, 0, int.high, problems)
    session = state.findTrace(id)
    if problems.len == 0 and session < 0: problems.add "no open file holds trace " & $id
    elif session >= 0: index = id - state.sessions[session].base
  elif n.hasKey("position"):
    let panel = PanelId(intArg(n, "panel", 1, 1, int.high, problems))
    let position = intArg(n, "position", -1, 0, int.high, problems)
    let k = state.findPanel(panel)
    if problems.len > 0: discard
    elif k < 0: problems.add $panel & " does not exist"
    elif position >= state.panels[k].shown.len:
      problems.add $panel & " has " & $state.panels[k].shown.len & " positions"
    else:
      session = state.shownFile(k)
      index = state.panels[k].shown[position]
      if session < 0: problems.add $panel & " shows no open file"
  elif n.hasKey("file"):
    let file = SessionId(intArg(n, "file", 0, 1, int.high, problems))
    index = intArg(n, "index", -1, 0, int.high, problems)
    session = state.findSession(file)
    if problems.len == 0 and session < 0: problems.add $file & " is not open"
    elif problems.len == 0 and index >= state.sessions[session].len:
      problems.add $file & " has " & $state.sessions[session].len & " traces"
  else:
    problems.add "name the trace: \"trace\", or \"panel\" and \"position\", or \"file\" " &
      "and \"index\""
  if problems.len > 0 or session < 0 or index < 0:
    result.answer = refused(problems)
    return
  let s = state.sessions[session]
  var r = %*{"trace": s.base + index, "file": int(s.id), "index": index,
    "edits": toJson(state.traceEdits(s.base + index))}
  r.noteSession(s)
  for g, gather in s.gathers:
    if index in gather.traces: r["gather"] = %g
  result.head = r
  result.what = "trace " & $(index + 1) & " of " & s.name
  result.job = state.readTraceHeaders(session, index)

proc headersAnswer*(state: var AppState; c: var HeaderCall): bool =
  ## Whether `headers` call `c` is answered now (`c.answer`): its job has
  ## read the trace, or failed, or its drive has not answered for
  ## `StallAfter` (then the job is cancelled: an agent is not kept waiting
  ## on a drive that may never answer). Once a frame, after `drainInbox`.
  if c.answer.len > 0: return true
  var keys: TraceKeys
  var rows: seq[HeaderRow]
  var vendor: VendorShown
  if state.takeTraceRead(c.job, keys, rows, vendor):
    var r = c.head
    r["keys"] = toJson(keys)
    var list = newJArray()
    for h in rows:
      list.add %*{"block": h.blockName, "field": h.field, "value": $h.value,
        "offset": h.offset, "size": h.size}
    r["headers"] = list
    r["vendor"] = vendorJson(vendor)
    c.answer = textResult($r)
    return true
  let info = state.jobs.info(c.job)
  # Done, its trace not taken in yet: the job may have ended after this
  # frame's inbox was drained, and what it posted comes with the next.
  let late = info.isSome and info.get.state == jsDone and
    getMonoTime() - info.get.finishedAt < initDuration(seconds = 2)
  if not late and (info.isNone or info.get.state in {jsDone, jsFailed, jsCancelled}):
    let why = if info.isSome and info.get.error.len > 0: info.get.error else: "it was stopped"
    c.answer = textResult("cannot read the headers of " & c.what & ": " & why, isError = true)
    return true
  if late: return false
  let silent = info.get.notAnsweringFor
  if silent > initDuration():
    discard state.jobs.cancel(c.job)
    c.answer = textResult("cannot read the headers of " & c.what & " now: its drive has not " &
      "answered for " & $max(1, silent.inSeconds) & " s", isError = true)
    return true
  false

# ---------------------------------------------------------- screenshot --

proc screenshot*(fe: Frontend; arguments: string; picture: var Picture): string =
  ## The `screenshot` tool, on the UI thread: "" when `picture` holds what
  ## the frontend took, to be answered with `pictureAnswer`; else the answer
  ## (a refusal, or why there is no picture).
  var n: JsonNode
  let why = args(arguments, n)
  if why.len > 0: return refused([why])
  var problems: seq[string]
  var target = "window"
  for key, v in n.pairs:
    if key == "window":
      if v.kind != JString or not v.str.isShotTarget:
        problems.add "window: one of " & ShotTargets.join(", ") & ", \"fft N\" or \"new plot N\""
      else: target = v.str
    elif key != "maxSize":
      problems.add "no argument " & escapeJson(key.substr(0, 79))
  let side = intArg(n, "maxSize", DefaultShotSide, 64, MaxShotSide, problems)
  if problems.len > 0: return refused(problems)
  if fe.shoot == nil:
    return textResult("there is no window to take a picture of", isError = true)
  var shot = fe.shoot(target)
  if shot.error.len > 0:
    return textResult("no picture: " & shot.error, isError = true)
  if shot.width <= 0 or shot.height <= 0 or shot.pixels.len != shot.width * shot.height:
    return textResult("no picture: the frontend gave none", isError = true)
  picture = Picture(shot: move shot, maxSide: side, target: target)
  ""

func scaledDown*(pixels: openArray[Rgba]; w, h, maxSide: int): (seq[Rgba], int, int) =
  ## `pixels` (`w` by `h`) made at most `maxSide` on its longer side, each
  ## pixel the mean of the pixels it covers; a copy when they fit.
  if max(w, h) <= maxSide or w <= 0 or h <= 0:
    return (@pixels, w, h)
  let s = maxSide / max(w, h)
  let (nw, nh) = (max(1, int(float(w) * s)), max(1, int(float(h) * s)))
  var res = newSeq[Rgba](nw * nh)
  for j in 0 ..< nh:
    let (y0, y1) = (j * h div nh, max(j * h div nh + 1, (j + 1) * h div nh))
    for i in 0 ..< nw:
      let (x0, x1) = (i * w div nw, max(i * w div nw + 1, (i + 1) * w div nw))
      var r, g, b, n = 0
      for y in y0 ..< y1:
        for x in x0 ..< x1:
          let p = pixels[y * w + x]
          r += p.r.int
          g += p.g.int
          b += p.b.int
          inc n
      res[j * nw + i] = Rgba(r: uint8(r div n), g: uint8(g div n), b: uint8(b div n), a: 255)
  (res, nw, nh)

proc pictureAnswer*(p: Picture; encode: PngEncoder): string =
  ## The answer to a `screenshot` call: `p` scaled down, encoded as PNG and
  ## wrapped as an image result. Pure work on plain data, for the server
  ## thread: the UI thread only read the pixels back.
  if encode == nil:
    return textResult("no picture: this viewSEG has no PNG encoder", isError = true)
  let (small, w, h) = scaledDown(p.shot.pixels, p.shot.width, p.shot.height, p.maxSide)
  let (png, why) = encode(small, w, h)
  if why.len > 0:
    textResult("no picture: " & why, isError = true)
  elif png.len > MaxShotBytes:
    textResult("the picture is larger than " & $(MaxShotBytes div (1024 * 1024)) &
      " MiB; ask for a smaller maxSize", isError = true)
  else:
    $(%*{"content": [
      {"type": "image", "data": base64.encode(png), "mimeType": "image/png"},
      {"type": "text", "text": p.target & ": " & $w & " x " & $h & " pixels"}],
      "isError": false})

# ---------------------------------------------------------------- wait --

proc busy*(state: AppState; fe: Frontend): seq[string] =
  ## What `wait` still waits for: the jobs running or waiting, the listing,
  ## the Headers window's reader, and each panel whose picture is not
  ## complete; none when everything is done.
  for j in state.jobs.active:
    result.add "job \"" & j.spec.title & "\" (" & $j.state & ")"
  if state.fileList.scanning: result.add "the folder's listing"
  if state.inspection.waiting:
    let w = state.headersWait
    result.add "the Headers window's reader" & (if w.kind == wkNone: "" else: ": " & w.words)
  for w in state.spectra:
    if w.waiting: result.add w.title & ": its spectrum"
  if state.compareWaiting: result.add "a compare slot: its copy"
  for title in state.plotsWaiting: result.add title & ": its numbers"
  for k in 0 ..< state.panels.len:
    if state.panels[k].role == prAux and not state.auxOpen: continue
    let picture = state.pictureOf(k, fe)
    if picture notin ["complete", "nothing shown", "nothing to draw", "no room to draw"]:
      result.add state.windowTitle(state.panels[k].id) & " (" & $state.panels[k].id &
        "): " & picture

proc waitArgs*(arguments: string; seconds: var float): string =
  ## The `wait` tool's timeout in seconds, from its arguments (JSON text):
  ## "" when they are right, else the answer that refuses them.
  seconds = DefaultWaitSeconds
  var n: JsonNode
  let why = args(arguments, n)
  if why.len > 0: return refused([why])
  var problems: seq[string]
  for key, v in n.pairs:
    if key != "timeout":
      problems.add "no argument " & escapeJson(key.substr(0, 79))
    elif v.kind notin {JInt, JFloat} or v.getFloat.isNaN or v.getFloat < 0 or
        v.getFloat > float(MaxWaitSeconds):
      problems.add "timeout: seconds, from 0 to " & $MaxWaitSeconds
    else:
      seconds = v.getFloat
  if problems.len > 0: refused(problems) else: ""

proc waited*(idle: bool; since, now: MonoTime; reasons: openArray[string]): string =
  ## The `wait` tool's answer.
  var r = %*{"idle": idle, "waitedMs": (now - since).inMilliseconds}
  if not idle:
    var b = newJArray()
    for x in reasons: b.add newJString(x)
    r["busy"] = b
  textResult($r)
