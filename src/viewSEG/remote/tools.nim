## The tools agent control offers, answered on the UI thread from the
## application state, as the windows read it and with the commands they
## issue (docs/agent-control.md describes them for a user):
##
## - `command`: one `Command` from JSON (`remote/schema`), given to `apply`;
## - `state`: the file list, the open files, the panels (view, display, gain,
##   order, the traces at each position, the edits), the selection, the jobs,
##   the newest messages, the survey;
## - `headers`: one trace's keys and header fields;
## - `screenshot`: a PNG of the window or a part of it: the frontend reads
##   the pixels back (`Frontend.shoot`, the only part on the UI thread);
##   `pictureAnswer` scales them down and encodes them on the server thread,
##   with the encoder the frontend gave (`PngEncoder`);
## - `wait`: until no job runs and every panel's picture is complete
##   (`remote/control` keeps it across frames; `busy` says what is left).
##
## Each tool's answer is the JSON text of an MCP tool result. Input comes
## from an agent: every problem with it is a result with `isError`, never an
## exception.

import std/[algorithm, base64, json, math, monotimes, sets, strutils, times]
import parseSEG
import ../core/[geometry, state]
import protocol, schema

const
  ToolNames* = ["command", "state", "headers", "screenshot", "wait"]
  StateParts* = ["fileList", "files", "panels", "selection", "jobs", "messages", "survey"]
  ShotTargets* = ["window", "plot", "seismic", "files", "records", "messages", "jobs",
    "toolbar", "statusbar"]
    ## what `screenshot` takes a picture of: the whole window, the Seismic
    ## window's picture of the traces alone, or one window
  DefaultShotSide* = 1600 ## the longest side of a screenshot, unless asked
  MaxShotSide* = 4096
  MaxShotBytes* = 16 * 1024 * 1024 ## the largest PNG a screenshot returns
  DefaultListed = 200 ## the longest list `state` returns, unless asked
  MaxListed = 100_000
  DefaultMessages = 20
  MaxMessages = 1000
  DefaultWaitSeconds* = 30
  PanelKinds = {ckGather, ckView, ckDisplay, ckHeader, ckSort, ckReverseAll, ckBack,
    ckShowFile, ckShowTrace, ckEdit, ckUndoEdit, ckClearEdits, ckFilter}
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

  Frontend* = object
    ## What only the frontend can do. A nil hook: that part is not available
    ## (a test without a window).
    shoot*: proc (target: string): Shot {.closure.}
      ## the pixels of `target` (one of `ShotTargets`) as the last frame drew
      ## them
    drawnView*: proc (panel: PanelId; view: var Viewport): bool {.closure.}
      ## the view `panel`'s picture was last drawn for; false when the
      ## frontend draws no picture of that panel
    showView*: proc (panel: PanelId; view: Viewport): bool {.closure.}
      ## shows `view` in `panel`'s plot, as a pan or zoom of the user's would;
      ## false when the frontend has no plot for it

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
       "record or a trace, change a panel's view, display, gain, display header, sort " &
       "or trace filter, kill or reverse traces (kept beside the file, which is never " &
       "changed), select traces, load survey files. The arguments are the command: " &
       "its \"kind\" and the fields that kind takes. A panel (1 is the Seismic window) " &
       "keeps what is not given: {\"kind\": \"display\", \"display\": {\"mode\": " &
       "\"density\"}} changes the mode only. \"panel\" defaults to 1; \"edit traces\" " &
       "without \"edited\" edits the selected traces of the panel's file, and \"on\" " &
       "defaults to true. Paths are best absolute. Trace ids are survey-wide: " &
       "`state` gives each file's firstTrace and each panel's positions (the trace " &
       "index in its file at each position, in the order shown). Returns at once with " &
       "what the program said; what reads data finishes later: call `wait`. Refused: " &
       "whatever writes a file, and the user's preferences and window layout.",
     "inputSchema": commandSchema()},
    {"name": "state",
     "description": "What viewSEG holds now: the file list (fileList), the open files " &
       "(files), the panels (panels: the file, record, layout, view, display and gain, " &
       "display header, order, trace filter, polarity, the traces at each position, " &
       "the edits, whether the picture is complete), the selection, the jobs, the " &
       "newest messages and the survey. All parts unless some are named.",
     "inputSchema": {"type": "object", "properties": {
       "parts": {"type": "array", "items": {"type": "string", "enum": parts},
         "description": "the parts to give; all when not given"},
       "messages": {"type": "integer", "minimum": 0, "maximum": MaxMessages,
         "description": "how many of the newest messages (default " & $DefaultMessages & ")"},
       "since": {"type": "integer", "minimum": 0,
         "description": "only the messages from this serial on"},
       "limit": {"type": "integer", "minimum": 1, "maximum": MaxListed,
         "description": "the longest list given: files listed, positions, selected " &
           "traces, edits (default " & $DefaultListed & ")"}},
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
       "the panel's view), or one window. Call `wait` first after a command that " &
       "reads data.",
     "inputSchema": {"type": "object", "properties": {
       "window": {"type": "string", "enum": shotEnum,
         "description": "what to take (default \"window\")"},
       "maxSize": {"type": "integer", "minimum": 64, "maximum": MaxShotSide,
         "description": "the longest side in pixels; larger pictures are scaled down " &
           "(default " & $DefaultShotSide & ")"}},
       "additionalProperties": false}},
    {"name": "wait",
     "description": "Waits until no job runs or waits and every panel's picture is " &
       "complete (read, sorted and drawn), at least one frame after the last command; " &
       "or until the timeout. Says whether it is idle, and what is still going if not.",
     "inputSchema": {"type": "object", "properties": {
       "timeout": {"type": "number", "minimum": 0, "maximum": MaxWaitSeconds,
         "description": "seconds (default " & $DefaultWaitSeconds & ")"}},
       "additionalProperties": false}}]
  $(%*{"tools": tools})

# ------------------------------------------------------------ helpers --

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
  ## display header, view, trace filter, order and polarity now (`c` is
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
  if c.kind == ckEdit:
    c.on = true

proc selectedIn(state: AppState; panel: PanelId): seq[int] =
  ## The selected traces of the file `panel` shows, survey-wide ids, ascending.
  let k = state.findPanel(panel)
  let i = if k >= 0: state.shownFile(k) else: -1
  if i >= 0:
    for t in state.selection.selected:
      if t in state.sessions[i]: result.add t
  result.sort()

proc runCommand*(state: var AppState; fe: Frontend; arguments: string;
    applied: var bool): string =
  ## The `command` tool: decodes the command, fills what is not given from
  ## the state, and applies it as a window's command is (a view through the
  ## frontend, which owns the plot's view, when it has one). `applied` is set
  ## when it was. The answer says what the program logged meanwhile.
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
  if kind == ckEdit and not n.hasKey("edited"):
    c.edited = state.selectedIn(c.panel)
  let before = state.log.nextSerial
  if kind == ckView and fe.showView != nil and fe.showView(c.panel, c.view):
    discard # the frontend moves its plot next frame and reports the view (ckView)
  else:
    state.apply c
  applied = true
  var said = newJArray()
  var ignored = false
  for e in state.log.since(before):
    said.add %*{"severity": $e.severity, "source": e.source, "text": e.text}
    if e.source == "commands" and e.severity >= sevWarning: ignored = true
  let done = %*{"command": $kind, "ignored": ignored, "messages": said}
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
  elif not p.laidOut: result = "laying out"
  elif state.sorting(k): result = "sorting"
  elif not p.pending.isEmpty and (p.pending.gen != p.requestGen or tiles.len == 0 or
      tiles[^1].request != p.pending):
    result = "reading"
  else:
    var drawn: Viewport
    if fe.drawnView != nil and fe.drawnView(p.id, drawn) and not drawn.sameSpans(p.view):
      result = "not drawn yet"
    else:
      result = "complete"

proc panelJson(state: AppState; k: int; fe: Frontend; limit: int): JsonNode =
  template p: untyped = state.panels[k]
  result = %*{"id": int(p.id), "title": state.windowTitle(p.id), "shows": $p.shows,
    "picture": state.pictureOf(k, fe), "laidOut": p.laidOut, "layout": toJson(p.layout),
    "view": toJson(p.view), "canGoBack": p.back.len > 0, "header": toJson(p.header),
    "level": toJson(p.level)}
  let i = state.shownFile(k)
  if i >= 0:
    let s = state.sessions[i]
    result["file"] = %*{"id": int(s.id), "path": s.path, "firstTrace": s.base}
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
    result["filter"] = toJson(layer.filter)
    result["order"] = toJson(layer.order)
    result["reversed"] = %layer.reversed
  result["positionCount"] = %p.shown.len
  result["positions"] = clipped(p.shown, limit)
  if i >= 0:
    let e = state.editsOf(k)
    let all = 0 ..< state.sessions[i].len
    result["killed"] = clipped(e.listIn(teKilled, all), limit)
    result["reversedTraces"] = clipped(e.listIn(teReversed, all), limit)
    result["canUndoEdit"] = %e.canUndo

proc fileListJson(state: AppState; limit: int): JsonNode =
  let l = state.fileList
  result = %*{"title": l.title, "folder": l.folder, "scanning": l.scanning,
    "chosen": l.chosen, "count": l.entries.len, "others": l.others,
    "unreadable": l.unreadable, "failed": l.failed, "error": l.error}
  var entries = newJArray()
  for i in 0 ..< min(l.entries.len, limit):
    let e = l.entries[i]
    entries.add %*{"name": e.name, "path": e.path, "kind": $e.kind, "size": e.size,
      "status": $e.status, "new": e.isNew}
  result["entries"] = entries

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
      files.add %*{"id": int(s.id), "path": s.path, "name": s.name, "traces": s.len,
        "firstTrace": s.base, "gathers": s.gathers.len}
    r["files"] = files
  if "panels" in wanted:
    var panels = newJArray()
    for k in 0 ..< state.panels.len: panels.add state.panelJson(k, fe, limit)
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
      messages.add %*{"serial": e.serial, "severity": $e.severity, "source": e.source,
        "text": e.text, "where": e.loc.where}
    r["messages"] = messages
  if "survey" in wanted:
    var layers = newJArray()
    for l in state.survey.layers:
      layers.add %*{"id": int(l.id), "origin": $l.origin, "kind": $l.kind, "name": l.name,
        "path": l.path, "sources": l.points[prSource].len,
        "receivers": l.points[prReceiver].len, "counts": {
          "sources": toJson(l.counts[prSource]), "receivers": toJson(l.counts[prReceiver])}}
    r["survey"] = layers
  textResult($r)

# ------------------------------------------------------------- headers --

proc traceHeaderReport*(state: AppState; arguments: string): string =
  ## The `headers` tool: one trace's keys and header fields.
  var n: JsonNode
  let why = args(arguments, n)
  if why.len > 0: return refused([why])
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
  if problems.len > 0 or session < 0 or index < 0: return refused(problems)
  let s = state.sessions[session]
  var r = %*{"trace": s.base + index, "file": int(s.id), "path": s.path, "index": index,
    "edits": toJson(state.traceEdits(s.base + index))}
  for g, gather in s.gathers:
    if index in gather.traces: r["gather"] = %g
  try:
    r["keys"] = toJson(s.file.traceKeys([index])[0])
    var rows = newJArray()
    for h in s.file.traceHeaders(index):
      rows.add %*{"block": h.blockName, "field": h.field, "value": $h.value,
        "offset": h.offset, "size": h.size}
    r["headers"] = rows
  except CatchableError as e:
    return textResult("cannot read the headers of trace " & $(index + 1) & " of " & s.name &
      ": " & e.msg, isError = true)
  textResult($r)

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
      if v.kind != JString or v.str notin ShotTargets:
        problems.add "window: one of " & ShotTargets.join(", ")
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
  ## What `wait` still waits for: the jobs running or waiting, and each panel
  ## whose picture is not complete; none when everything is done.
  for j in state.jobs.active:
    result.add "job \"" & j.spec.title & "\" (" & $j.state & ")"
  if state.fileList.scanning: result.add "the folder's listing"
  for k in 0 ..< state.panels.len:
    let picture = state.pictureOf(k, fe)
    if picture notin ["complete", "nothing shown"]:
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
