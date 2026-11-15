## The map's view models: the layers it draws, each with its colour and
## shape; the highlight (the points of the trace under the pointer in the
## plot, and of the selection); the point under the map's own pointer and
## what the map says of it; and the coordinates and units the status bar
## shows. Toolkit-neutral: the frontend draws what these say.
##
## **Layers** (`mapLayers`), drawn in this order: the survey files'
## receivers, then their sources, as filled discs (sources over receivers);
## the open files' own receivers and sources (their traces' coordinates), as
## rings, so where they
## agree with the survey files each disc sits in a ring and where they do
## not both show; the highlight on top. Each can be hidden.
##
## **Colours** (`mapInk`): the plot's background (paper by default, or the
## theme's, as the plot window's colour scheme says), sources in the theme's
## red and receivers in its blue (its green where the blue is the accent,
## which marks the selection), each made readable on the background; the
## hovered points in the highlight colour and the selected ones in the
## accent colour, as in the plot.

import std/[intsets, math, strutils]
from parseSEG import known, recordsAt, stationKey
import ../core/[geometry, state]
import plotink, theme

type
  MapShape* = enum
    msDisc = "disc" ## a filled disc: a survey file's point
    msRing = "ring" ## a ring: an open file's own position

  MapInk* = object
    ## The map's colours.
    background*: Rgba
    roles*: array[PointRole, Rgba] ## sources, receivers
    hover*: Rgba                   ## the points under the pointer, in the map or in the plot
    selected*: Rgba                ## the selected points
    outline*: Rgba                 ## round the highlighted points: the background's opposite

  MapLayerView* = object
    ## One layer of the map, as the frontend draws and lists it.
    key*: MapLayerKey
    layer*: SurveyLayerId ## `NoSurveyLayer` for the highlight
    role*: PointRole
    name*: string         ## "Receivers of line3.rps"
    file*: string         ## the file's name; "" for the highlight
    points*: int
    colour*: Rgba
    shape*: MapShape
    shown*: bool
    spacing*: float64     ## how far apart its points typically are (`core/maplod`)

  MapHighlight* = object
    ## The points the map highlights.
    hovered*: seq[PointRef]  ## of the trace under the pointer in the plot
    selected*: seq[PointRef] ## selected on the map, and of the selected traces

  PointInfo* = object
    ## What the map says of a point: a title and lines under it.
    title*: string
    lines*: seq[string]

const
  MaxHighlighted* = 200_000 ## selected points drawn at most
  MinMarker* = 2'f32        ## the smallest disc, pixels at 100 %: points crowded on the screen
  MaxMarker* = 5'f32        ## the largest disc: points far apart on the screen
  RingRoom* = 4'f32         ## how much wider than its disc an open file's ring is
  InfoRecords = 6           ## records named one by one in a point's information

func mapInk*(t: Theme; colours: PlotColours; custom = CustomColours()): MapInk =
  ## The map's colours in theme `t`, on the background of the plot's colour
  ## scheme `colours`.
  let plot = plotInk(t, DisplaySettings(colours: colours, custom: custom))
  let bg = plot.background
  let blue = if distance(t.roles[rlInfo], t.roles[rlAccent]) < 40: t.palette[bcGreen]
             else: t.roles[rlInfo]
  result = MapInk(background: bg, hover: plot.wiggle.hover, selected: plot.wiggle.selected,
    outline: (if luminance(bg) > 0.18: PaperInk else: PaperBackground))
  result.roles[prSource] = readableOn(t.roles[rlError], bg)
  result.roles[prReceiver] = readableOn(blue, bg)

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func roleName(r: PointRole; many: bool): string =
  case r
  of prSource: (if many: "Sources" else: "Source")
  of prReceiver: (if many: "Receivers" else: "Receiver")

func mapLayers*(st: AppState; ink: MapInk): seq[MapLayerView] =
  ## The map's layers, in the order they are drawn (`mapLayers` above), the
  ## highlight last.
  template add(l: SurveyLayer; r: PointRole) =
    if l.points[r].len > 0:
      let key = l.keyOf(r)
      result.add MapLayerView(key: key, layer: l.id, role: r, file: l.name, points:
        l.points[r].len, colour: ink.roles[r], shown: st.map.shown(key),
        spacing: l.levels[r].spacing,
        shape: (if l.origin == loTraces: msRing else: msDisc),
        name: roleName(r, true) & (if l.origin == loTraces: " in " else: " of ") & l.name)
  for origin in [loSurveyFile, loTraces]:
    for r in [prReceiver, prSource]:
      for l in st.survey.layers:
        if l.origin == origin: add(l, r)
  result.add MapLayerView(key: HighlightKey, name: "Highlight: the trace under the " &
    "pointer, the selection", colour: ink.hover, shape: msDisc,
    shown: st.map.shown(HighlightKey))

func markerSize*(spacing, pixel: float64): float32 =
  ## The diameter, in pixels at 100 %, of a survey file's point whose
  ## layer's points are typically `spacing` apart, on a map where a pixel at
  ## 100 % is `pixel` survey units: `MaxMarker` where they are far apart on
  ## the screen, smaller as they crowd, down to `MinMarker`, so lines of
  ## points stay lines when zoomed out.
  if not (spacing > 0 and pixel > 0): return MaxMarker
  clamp(float32(spacing / pixel * 0.9), MinMarker, MaxMarker)

func ringSize*(spacing, pixel: float64): float32 =
  ## The diameter of an open file's ring round a point: its disc's and
  ## `RingRoom` more; below `MaxMarker` it is drawn as a disc (a ring that
  ## small is a blot).
  markerSize(spacing, pixel) + RingRoom * (markerSize(spacing, pixel) - MinMarker) /
    (MaxMarker - MinMarker)

func highlightOf*(st: AppState): MapHighlight =
  ## The points of the trace under the pointer in the plot, and those
  ## selected (on the map, and of the selected traces; at most
  ## `MaxHighlighted`), each once.
  let sel = st.selection
  if sel.hover >= 0: result.hovered = st.survey.tracePointsOf(sel.hover)
  var seen: IntSet
  for p in sel.points:
    if p.key notin seen and st.survey.find(p.layer) >= 0:
      seen.incl p.key
      result.selected.add p
  for t in sel.selected:
    if result.selected.len >= MaxHighlighted: break
    for p in st.survey.tracePointsOf(t):
      if p.key notin seen:
        seen.incl p.key
        result.selected.add p

func positionOf*(st: AppState; p: PointRef): MapPoint =
  ## Where point `p` is; NaN when its layer is gone.
  let i = st.survey.find(p.layer)
  if i < 0 or p.point notin 0 ..< st.survey.layers[i].points[p.role].len:
    return mapPoint(NaN, NaN)
  let ix = addr st.survey.layers[i].points[p.role].index
  mapPoint(ix[].x(p.point), ix[].y(p.point))

func pointsAt*(st: AppState; at: MapPoint; radius: float64): seq[PointRef] =
  ## The point of a shown layer nearest `at`, no farther than `radius`
  ## (survey units), first; then the points of the other shown layers on
  ## the same spot (within a hundredth of `radius`): a survey file's
  ## receiver and the open file's own, say. None when no point is that near.
  var best = -1.0
  var found: seq[(float64, PointRef)]
  for l in st.survey.layers:
    for r in PointRole:
      if st.map.shown(l.keyOf(r)):
        let q = l.points[r].index.nearest(at.x, at.y, radius)
        if q >= 0:
          let d = hypot(l.points[r].index.x(q) - at.x, l.points[r].index.y(q) - at.y)
          found.add (d, PointRef(layer: l.id, role: r, point: q))
          if best < 0 or d < best: best = d
  if best < 0: return
  var first = -1
  for i, (d, _) in found:
    if first < 0 and d == best: first = i
  let here = st.positionOf(found[first][1])
  result.add found[first][1]
  for i, (_, p) in found:
    if i != first:
      let q = st.positionOf(p)
      if hypot(q.x - here.x, q.y - here.y) <= radius / 100: result.add p

func pointsIn*(st: AppState; box: Bounds): seq[PointRef] =
  ## The points of the shown layers in `box` (survey coordinates).
  for l in st.survey.layers:
    for r in PointRole:
      if st.map.shown(l.keyOf(r)):
        for q in l.points[r].index.within(box):
          result.add PointRef(layer: l.id, role: r, point: q)

func unitsOf*(st: AppState): string =
  ## The survey's units as the status bar and the scale bar write them: the
  ## first survey file's that says ("ft", "US ft", "m", or its own words);
  ## "" when none does.
  for l in st.survey.layers:
    if l.origin == loSurveyFile and l.gridUnit.known:
      let u = l.gridUnit
      if u.metres > 0:
        if abs(u.metres - 1) <= 1e-9: return "m"
        if abs(u.metres - 0.3048) <= 1e-9: return "ft"
        if abs(u.metres - 1200 / 3937) <= 1e-9: return "US ft"
      let n = u.name.strip.toLowerAscii
      if n in ["m", "meter", "meters", "metre", "metres"]: return "m"
      if n in ["ft", "foot", "feet"]: return "ft"
      return u.name.strip
  ""

func fixed(x: float64; decimals: int): string =
  if x.isNaN: ""
  elif decimals <= 0: formatFloat(round(x), ffDecimal, 0).strip(leading = false, chars = {'.'})
  else: formatFloat(x, ffDecimal, decimals)

func coordinatesText*(at: MapPoint; perPixel: float64; units: string): string =
  ## The pointer's coordinates as the status bar shows them: "E 1833476.1
  ## N 417000.8 ft", to a pixel's step.
  let d = decimalsFor(perPixel)
  "E " & fixed(at.x, d) & "   N " & fixed(at.y, d) & (if units.len > 0: " " & units
    else: "  (units not given)")

func lengthText*(length: float64; units: string): string =
  ## A length as the scale bar and the ruler write it: "500 ft", "1.25 km"
  ## in metres from 1 km on.
  let u = if units.len > 0: units else: "units"
  if units == "m" and length >= 1000:
    let km = length / 1000
    (if km == round(km): $int(km) else: formatFloat(km, ffDecimal, 2)) & " km"
  elif length == round(length) and abs(length) < 1e15: $int64(length) & " " & u
  else: formatFloat(length, ffDecimal, (if length >= 10: 1 else: 2)) & " " & u

func stationText(s: Station): string =
  if not s.known: return "no station"
  func num(x: float64): string =
    if x == round(x) and abs(x) < 1e15: $int64(x) else: formatFloat(x, ffDecimal, 2)
  "line " & num(s.line) & ", point " & num(s.point) &
    (if s.index > 1: ", index " & $s.index else: "")

proc recordsText(st: AppState; traces: openArray[int]): string =
  ## "12 traces in 3 records: FFID 12900, 12901, 12902" for survey-wide
  ## traces of the open files.
  var names: seq[(bool, string)] # an FFID, or a place in the file
  var seen: IntSet
  var records = 0
  for t in traces:
    let i = st.findTrace(t)
    if i >= 0:
      let s = st.sessions[i]
      let g = s.gatherOf(t - s.base)
      let key = i * 1_000_000_000 + g
      if g >= 0 and key notin seen:
        seen.incl key
        inc records
        if names.len < InfoRecords:
          let f = s.records[g].record
          names.add (if f.isNaN: (false, "record " & $(g + 1)) else: (true, $int64(f)))
  result = plural(traces.len, "trace", "traces")
  if records > 0:
    var all = true
    for (ffid, _) in names: all = all and ffid
    var parts: seq[string]
    for (ffid, text) in names: parts.add (if ffid and not all: "FFID " & text else: text)
    result.add " in " & plural(records, "record", "records") & ": " &
      (if all: "FFID " else: "") & parts.join(", ") & (if records > names.len: ", ..." else: "")

func elided*(name: string; most = 44): string =
  ## `name`, its middle given up for "..." when it is longer than `most`
  ## characters (survey files often have long names that end in what tells
  ## them apart).
  if name.len <= most: name
  else: name[0 ..< most - most div 3 - 3] & "..." & name[^(most div 3) .. ^1]

func merged*(infos: openArray[PointInfo]): seq[PointInfo] =
  ## What is said of several points on one spot (a survey file's receiver
  ## and the open file's own): each line once, and a title only where it
  ## names another point.
  var seen: seq[string]
  for i in infos:
    var m = PointInfo(title: if i.title in seen: "" else: i.title)
    seen.add i.title
    for l in i.lines:
      if l notin seen:
        m.lines.add l
        seen.add l
    if m.title.len > 0 or m.lines.len > 0: result.add m

proc pointInfo*(st: AppState; p: PointRef; units: string): PointInfo =
  ## What the map says of point `p`: its role, station and file; its
  ## coordinates and elevation; the traces of the open files recorded there
  ## and their records; for a survey file's source, the field records the
  ## loaded relation files give it.
  let i = st.survey.find(p.layer)
  if i < 0 or p.point notin 0 ..< st.survey.layers[i].points[p.role].len: return
  template l: untyped = st.survey.layers[i]
  let ps = addr l.points[p.role]
  let station = ps.station[p.point]
  result.title = roleName(p.role, false) & ", " & stationText(station)
  let d = 1
  let u = if units.len > 0: " " & units else: ""
  var place = "E " & fixed(ps.index.x(p.point), d) & "   N " & fixed(ps.index.y(p.point), d)
  if not ps.z[p.point].isNaN: place.add "   Z " & fixed(ps.z[p.point], d)
  result.lines.add place & u
  result.lines.add (if l.origin == loTraces: "In the traces of " else: "In ") & elided(l.name)
  let traces = st.survey.tracesAt(p)
  if traces.len > 0: result.lines.add st.recordsText(traces)
  elif l.origin == loSurveyFile and st.sessions.len > 0:
    result.lines.add "No trace of the open files"
  if l.origin == loSurveyFile and p.role == prSource and station.known:
    var records: seq[int64]
    for m in st.survey.layers:
      if m.origin == loSurveyFile and m.relationRuns > 0:
        for r in m.relations[].recordsAt(stationKey(station.line, station.point,
            station.index)):
          if r notin records: records.add r
    if records.len > 0:
      var names: seq[string]
      for r in records:
        if names.len < InfoRecords: names.add $r
      result.lines.add "Field " & (if records.len == 1: "record " else: "records ") &
        names.join(", ") & (if records.len > names.len: ", ... (" & $records.len & ")"
        else: "") & " in the relation file"
