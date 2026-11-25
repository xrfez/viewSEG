## The plot menu's choices for a receiver station that clearly moved: put it at the position
## the trace's own headers give (offered when that is more than a metre from the position in
## force), put it at a position typed in a small dialog (from this trace's time on, or for
## every trace), and take its moves away. A click sends `ckStationMove`; the header position
## is read off the UI thread by `ckOwnPosition`, sent when the menu opens. A move is kept in
## the project and never written into a survey or seismic file.

import std/[math, options, parseutils, sequtils, strutils]
import imguin/cimgui
import parseSEG
import ../../core/[join, state, stationindex, stationmoves]
import marks, placement

const
  HeaderItem = "Move this station to the position in this trace's headers"
  DialogId = "Move station###stamove"

type
  StationMoveUi* = object
    ## The dialog's own state between frames.
    ask: bool                 ## the menu asked for the dialog: open it next frame
    key: StationKey
    time: float64             ## the trace's time (UTC POSIX seconds), NaN for none
    was: tuple[x, y: float64] ## the position in force when the dialog opened
    fromHere: bool
    x, y, elev: array[32, char]
    note: array[128, char]

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc fill[N: static int](buf: var array[N, char]; text: string) =
  zeroMem(addr buf[0], buf.len)
  if text.len > 0: copyMem(addr buf[0], text.cstring, min(text.len, buf.len - 1))

proc text[N: static int](buf: var array[N, char]): string =
  $cast[cstring](addr buf[0])

func num(x: float64): string =
  if x == x: formatFloat(x, ffDecimal, 2) else: ""

proc parse(s: string): Option[float64] =
  ## The number `s` says (blanks around it allowed); none for anything else.
  let t = s.strip
  var v = 0.0
  if t.len > 0 and parseutils.parseFloat(t, v) == t.len and v == v and abs(v) < Inf: some(v)
  else: none(float64)

proc forgetCommand*(m: StationMove): Command =
  Command(kind: ckStationMove, moveLine: m.station.line, movePoint: m.station.point,
    moveIndex: int(m.station.index), moveForget: true, moveHasFrom: m.fromTime.isSome,
    moveFrom: m.fromTime.get(0.0))

proc drawStationMoveGroup*(ui: var StationMoveUi; st: AppState; under: int;
    found: Option[TraceKeys]; marks: var Marks; cmds: var seq[Command]) =
  ## The three choices for the receiver station of survey-wide trace `under`, whose keys
  ## `found` is the copy taken when the menu opened; nothing for a trace with no station (an
  ## auxiliary trace, a file without keys).
  if found.isNone: return
  let keys = found.get
  if not keys.isSeismic or keys.rcvLine != keys.rcvLine or keys.rcvPoint != keys.rcvPoint: return
  let key = stationKey(keys.rcvLine, keys.rcvPoint, keys.rcvIndex)
  let word = "receiver " & stationWords(key)
  let moves = st.movesAppliedTo(key)
  let dated = moves.anyIt(it.fromTime.isSome)
  let inForce = (x: keys.rcvX, y: keys.rcvY)
  let own = st.ownPositionOf(under)
  let d = if own.isSome: hypot(own.get.x - inForce.x, own.get.y - inForce.y) else: NaN
  let units = st.headerUnitsProblem(under)
  let far = own.isSome and st.headerMoveOffered(d)
  let offered = far and units.len == 0
  let source = if moves.len > 0: "the move's" elif st.joins.len > 0: "the survey's"
               else: "the present"
  let label = HeaderItem & (if offered: " (" & st.moveDistanceWords(d) & " from " & source &
    " position)" else: "")
  let hasElev = own.isSome and own.get.z == own.get.z and own.get.z != 0
  if igMenuItem_Bool(label.cstring, nil, false, offered):
    cmds.add Command(kind: ckStationMove, moveLine: key.line, movePoint: key.point,
      moveIndex: int(key.index), moveX: own.get.x, moveY: own.get.y,
      moveElev: own.get.z, moveHasElev: hasElev, moveHasWas: inForce.x == inForce.x,
      moveWasX: inForce.x, moveWasY: inForce.y, moveNote: "the position in the trace's headers")
  marks.mark("plot.menu.stamove.header")
  marks.mark("plot.menu.stamove.header.item " & label)
  tip(if offered: "Put " & word & " at the position this trace's own header gives, for every " &
        "trace of the station. Kept in the project; no survey or seismic file is changed. " &
        "An elevation of exactly 0 in the header counts as not given: the survey's elevation " &
        "stays." & (if dated: " A move of this station from a time on is kept: the traces " &
        "from that time on keep that position." else: "")
      elif units.len > 0: "Not offered: " & units & "."
      elif own.isNone: "This trace's header gives " & word & " no position to move it to " &
        "(or it is still being read)."
      else: "This trace's header agrees with the position in force for " & word & " (within " &
        "1 m).")
  if igMenuItem_Bool("Move this station...", nil, false, true):
    ui.key = key
    ui.time = keys.time
    ui.was = inForce
    ui.fromHere = false
    ui.x.fill num(inForce.x)
    ui.y.fill num(inForce.y)
    ui.elev.fill num(keys.rcvZ)
    ui.note.fill ""
    ui.ask = true
  marks.mark("plot.menu.stamove.dialog")
  tip("Say where " & word & " sits: every trace of it, or from this trace's time on")
  if igMenuItem_Bool("Remove the move of this station", nil, false, moves.len > 0):
    for m in moves: cmds.add forgetCommand(m)
  marks.mark("plot.menu.stamove.remove")
  tip(if moves.len > 0: "Take the move of " & word & " away: the survey's or the header's " &
        "position holds again"
      else: "No move is kept for " & word)

proc drawStationMoveDialog*(ui: var StationMoveUi; st: AppState; marks: var Marks;
    cmds: var seq[Command]) =
  ## The dialog while it is open: Move sends `ckStationMove`, Cancel (or Escape) changes
  ## nothing.
  if ui.ask:
    ui.ask = false
    igOpenPopup_Str(DialogId.cstring, 0)
  centreModal(DialogId)
  igSetNextWindowSizeConstraints(ImVec2_c(x: igGetFontSize() * 24, y: 0),
    ImVec2_c(x: igGetFontSize() * 34, y: 4000), nil, nil)
  if not igBeginPopupModal(DialogId.cstring, nil, ImGui_WindowFlags_AlwaysAutoResize.cint):
    return
  marks.markWindow("stamove")
  let unit = st.stationMoveUnit.abbreviation
  let inUnit = if unit.len > 0: " (" & unit & ")" else: ""
  igTextUnformatted(("Receiver station " & stationWords(ui.key)).cstring, nil)
  marks.mark("stamove.station")
  igSeparator()
  const flags = ImGui_InputTextFlags_AutoSelectAll.cint
  let width = igGetFontSize() * 12
  igSetNextItemWidth(width)
  discard igInputText(("X" & inUnit & "###stamovex").cstring, cast[cstring](addr ui.x[0]),
    csize_t(ui.x.len), flags, nil, nil)
  marks.mark("stamove.x")
  igSetNextItemWidth(width)
  discard igInputText(("Y" & inUnit & "###stamovey").cstring, cast[cstring](addr ui.y[0]),
    csize_t(ui.y.len), flags, nil, nil)
  marks.mark("stamove.y")
  igSetNextItemWidth(width)
  discard igInputText(("Elevation" & inUnit & " (optional)###stamovez").cstring,
    cast[cstring](addr ui.elev[0]), csize_t(ui.elev.len), flags, nil, nil)
  marks.mark("stamove.elev")
  let timed = ui.time == ui.time
  igBeginDisabled(not timed)
  let fromWords = "From this trace's time on" &
    (if timed: " (" & utcWords(ui.time) & ")" else: "")
  discard igCheckbox(fromWords.cstring, addr ui.fromHere)
  igEndDisabled()
  marks.mark("stamove.from")
  tip(if timed: "Off: the position holds for every trace of the station. On: it holds from " &
        "this trace's time on; earlier traces keep the position they have."
      else: "This trace has no time.")
  igSetNextItemWidth(width * 2)
  discard igInputText("Note###stamovenote", cast[cstring](addr ui.note[0]), csize_t(ui.note.len),
    0, nil, nil)
  marks.mark("stamove.note")
  let x = parse(ui.x.text)
  let y = parse(ui.y.text)
  let z = parse(ui.elev.text)
  let ok = x.isSome and y.isSome and (ui.elev.text.strip.len == 0 or z.isSome)
  igSeparator()
  igBeginDisabled(not ok)
  if igButton("Move", ImVec2_c(x: 0, y: 0)):
    cmds.add Command(kind: ckStationMove, moveLine: ui.key.line, movePoint: ui.key.point,
      moveIndex: int(ui.key.index), moveX: x.get, moveY: y.get, moveElev: z.get(0.0),
      moveHasElev: z.isSome, moveFrom: ui.time, moveHasFrom: ui.fromHere and timed,
      moveWasX: ui.was.x, moveWasY: ui.was.y, moveHasWas: ui.was.x == ui.was.x,
      moveNote: ui.note.text.strip)
    igCloseCurrentPopup()
  igEndDisabled()
  marks.mark("stamove.move")
  tip(if ok: "Keep this position for the station" else: "X and Y are numbers")
  igSameLine(0, -1)
  if igButton("Cancel", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape, false):
    igCloseCurrentPopup()
  marks.mark("stamove.cancel")
  igEndPopup()
