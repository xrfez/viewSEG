## The survey: where sources and receivers are, for the map and for linking
## traces to the places they were recorded at. One model, two sources of
## positions, each a `SurveyLayer`:
##
## - **an open file's traces** (`loTraces`): each trace's source and
##   receiver coordinates from its keys (parseSEG applies the SEG-Y
##   scalar), read on a job once the file is open (`core/surveyjobs`);
## - **a survey file** (`loSurveyFile`) loaded on its own, with or without a
##   seismic file: SPS source (S) and receiver (R) points, SPS relations (X,
##   O) and SEG P1 shotpoints.
##
## **Positions are per trace**, so land, marine and transition data all
## work: a trace's source and its receiver each become a point of the
## layer, and two become one point only where they repeat, at the same
## station and the same coordinates (a land receiver recorded in every
## shot). A streamer's receivers move with every shot, so each is a point
## of its own. A survey file's station given twice is one point, at the
## coordinates given last (as parseSEG's join takes them).
##
## **Missing and zero coordinates are data:** a position without
## coordinates, or at (0, 0) (a header left empty), is counted
## (`Positions`) and left off the map, and nothing raises.
##
## **Points** (`PointSet`, one per role) are kept in the order of their
## spatial index (`core/spatial`): point `i` of a role is at
## `index.x(i)`, `index.y(i)`, and `nearest` and `within` give point
## numbers. A survey file's points are found by station (`stationPoint`);
## a traces layer keeps, per role, each trace's point and station and the
## traces at each point and station.
##
## **Links** (for linked highlighting): `tracePoints` gives the points a
## trace was recorded at in every layer (its own file's, by trace; the
## survey files', by its stations, filled from the files' relations when
## its keys lack them, as parseSEG's join fills them); `tracesAt` gives the
## traces of the open files recorded at a point. **The join** is
## parseSEG's own: the import reads the survey files into one
## `SurveyGeometry` with `addSps` / `addP1` (`core/surveyjobs`).
##
## Layers are made off the UI thread (the builders below) and do not change
## once made: a changed file, or keys changed by a join, make a new layer.
## The map's levels of detail (`core/maplod`) are made with the layer, on the
## same worker (`withLevels`).

import std/[algorithm, intsets, math, options, os, strutils, tables, times]
import parseSEG
import filekinds, maplod, session, spatial

export maplod, spatial

type
  IdTable = object
    ## Open addressing over the ids of a list that grows (0, 1, 2 ...), each
    ## id's hash kept: a million traces are grouped in well under a second,
    ## also in a debug build.
    slots: seq[int32] ## a power of two long; -1 for empty
    hashes: seq[uint64] ## per id

  SurveyLayerId* = distinct int
    ## Names a layer; never reused. `NoSurveyLayer` (0) names none.

  PointRole* = enum
    prSource = "source"
    prReceiver = "receiver"

  LayerOrigin* = enum
    loTraces = "traces"          ## an open file's traces
    loSurveyFile = "survey file" ## an SPS or P1 file

  Station* = object
    ## A station: line, point and point index. Line and point are NaN when
    ## not known.
    line*, point*: float64
    index*: int16

  Positions* = object
    ## What became of the positions of one role of a layer.
    given*: int     ## traces (seismic ones) or records looked at
    placed*: int    ## with coordinates: on the map
    missing*: int   ## without coordinates (or not finite): left off the map
    zero*: int      ## at (0, 0): left off the map
    merged*: int    ## traces: placed at a point an earlier trace has (same station, same place)
    replaced*: int  ## survey files: a station given again (the last one is kept)
    moved*: int     ## survey files: of those, at other coordinates
    noStation*: int ## without a station (line or point unknown, or not a number)

  PointSet* = object
    ## The points of one role of a layer, in the order of `index`.
    index*: SpatialIndex
    z*: seq[float64] ## elevation; NaN when not known
    station*: seq[Station]
    ids: IdTable     ## survey files: the point of each station
    traceStart, traceList: seq[int32]
      ## traces: the traces at point `i` are traceList[traceStart[i] ..< traceStart[i + 1]]

  StationSet = object
    ## A traces layer's stations of one role, and the traces of each
    ## (whether they have coordinates or not).
    keys: seq[StationKey]
    ids: IdTable
    traceStart, traceList: seq[int32]

  SurveyLayer* = object
    ## Where the sources and receivers of one file are.
    id*: SurveyLayerId
    origin*: LayerOrigin
    kind*: FileKind       ## the file's kind (a survey kind, or a seismic one)
    path*, name*: string
    size*: int64          ## survey files: the file's size and time as it was read
    modified*: Time
    session*: SessionId   ## traces: the open file; `NoSession` for a survey file
    base*: int            ## traces: the survey-wide id of the file's trace 0
    keysRevision*: int    ## traces: the keys it was made from (parseSEG's `keysRevision`)
    traces*: int          ## traces: the file's traces
    auxiliary*: int       ## traces: of those, not seismic (no position taken)
    points*: array[PointRole, PointSet]
    counts*: array[PointRole, Positions]
    relations*: ref SurveyGeometry
      ## survey files: the SPS relation records (X, O) as parseSEG's join reads
      ## them, empty for none; nil for a traces layer. On the heap, and never
      ## changed once the layer is made, so that a job can read them where
      ## they are (`checkWork`) while the UI thread keeps them alive: a copy
      ## of a large X file's costs a frame
    relationRuns*: int ## X and O records kept
    xRuns*: int ## of those, X records (the source domain's): what records are checked against
    relationRecords*: int ## field records they describe
    gridUnit*: GridUnit ## survey files: the unit the SPS header gives
    bounds*: Bounds ## of every point
    levels*: array[PointRole, PointLevels]
      ## each role's points for the map, coarser and coarser (`withLevels`)
    pointOf, stationOf: array[PointRole, seq[int32]]
      ## traces: per trace, its point and its station (-1 for none)
    stations: array[PointRole, StationSet]

  Survey* = object
    ## Every layer: the survey files loaded and the open files' traces.
    layers: seq[SurveyLayer]
    nextId: int
    revision*: int ## bumped on every change

  PointRef* = object
    ## A point of a layer.
    layer*: SurveyLayerId
    role*: PointRole
    point*: int

const NoSurveyLayer* = SurveyLayerId(0)

func `==`*(a, b: SurveyLayerId): bool {.borrow.}

func key*(p: PointRef): int {.inline.} =
  ## A number that names `p` alone (for sets of points).
  (int(p.layer) shl 33) or (ord(p.role) shl 32) or p.point
func `$`*(id: SurveyLayerId): string = "survey layer " & $int(id)

func len*(p: PointSet): int {.inline.} = p.index.len
  ## The number of points.

func noStation(): Station {.inline.} = Station(line: NaN, point: NaN)

func known*(s: Station): bool {.inline.} =
  ## Both the line and the point are known.
  not (s.line.isNaN or s.point.isNaN)

func finite(x: float64): bool {.inline.} = abs(x) < Inf

func asStation(k: StationKey): Station {.inline.} =
  Station(line: k.line, point: k.point, index: k.index)

# ------------------------------------------------------------- id tables --

func mix(z: uint64): uint64 {.inline.} =
  # SplitMix64's finaliser: every input bit moves every output bit.
  var v = z
  v = (v xor (v shr 30)) * 0xBF58476D1CE4E5B9'u64
  v = (v xor (v shr 27)) * 0x94D049BB133111EB'u64
  v xor (v shr 31)

func bits(x: float64): uint64 {.inline.} =
  # 0.0 and -0.0 alike.
  if x == 0: 0'u64 else: cast[uint64](x)

proc resize(t: var IdTable; cap: int) =
  t.slots = newSeq[int32](cap)
  for s in t.slots.mitems: s = -1
  let mask = uint64(cap - 1)
  for id, h in t.hashes:
    var at = h and mask
    while t.slots[at] >= 0: at = (at + 1) and mask
    t.slots[at] = int32(id)

proc fitted(hashes: sink seq[uint64]): IdTable =
  ## A table of ids 0 ..< hashes.len, with those hashes.
  result = IdTable(hashes: hashes)
  var cap = 64
  while cap < 2 * result.hashes.len + 2: cap *= 2
  result.resize(cap)

template find(t: IdTable; h: uint64; isSame: untyped): int32 =
  ## The id whose key `isSame` (an expression of `id`) says is the key
  ## hashed to `h`; -1 for none.
  var found = -1'i32
  if t.slots.len > 0:
    let mask = uint64(t.slots.len - 1)
    var at = h and mask
    while found < 0 and t.slots[at] >= 0:
      let id {.inject.} = t.slots[at]
      if t.hashes[id] == h and isSame: found = id
      else: at = (at + 1) and mask
  found

template findOrAdd(t: var IdTable; h: uint64; isSame, addNew: untyped): (int32, bool) =
  ## `find`, and true when found; else runs `addNew` (which adds the key of
  ## id `t.hashes.len` to the caller's list) and gives that id, and false.
  if (t.hashes.len + 1) * 2 > t.slots.len: t.resize(max(64, t.slots.len * 2))
  let mask = uint64(t.slots.len - 1)
  var at = h and mask
  var found = -1'i32
  while found < 0 and t.slots[at] >= 0:
    let id {.inject.} = t.slots[at]
    if t.hashes[id] == h and isSame: found = id
    else: at = (at + 1) and mask
  if found >= 0: (found, true)
  else:
    found = int32(t.hashes.len)
    t.slots[at] = found
    t.hashes.add h
    addNew
    (found, false)

func stationHash(k: StationKey): uint64 {.inline.} =
  mix(bits(k.line) xor mix(bits(k.point) xor (uint64(cast[uint16](k.index)) shl 1)))

func pointHash(station: int32; x, y: float64): uint64 {.inline.} =
  mix(bits(x) xor mix(bits(y) xor (uint64(cast[uint32](station)) shl 7)))

func same(a: StationKey; b: StationKey): bool {.inline.} =
  a.line == b.line and a.point == b.point and a.index == b.index

func same(a: Station; b: StationKey): bool {.inline.} =
  a.line == b.line and a.point == b.point and a.index == b.index

# ------------------------------------------------------------ building --

proc groups(owner: openArray[int32]; count: int; start, list: var seq[int32]) =
  ## The members of each of `count` groups (`owner[member]` is its group,
  ## -1 for none), in member order: group g's are `list[start[g] ..<
  ## start[g + 1]]`.
  start = newSeq[int32](count + 1)
  for g in owner:
    if g >= 0: inc start[g + 1]
  for g in 1 .. count: start[g] += start[g - 1]
  list = newSeq[int32](start[count])
  var fill = start
  for member, g in owner:
    if g >= 0:
      list[fill[g]] = int32(member)
      inc fill[g]

proc indexed(xs, ys, zs: openArray[float64]; stations: openArray[Station]):
    tuple[points: PointSet; rank: seq[int32]] =
  ## Points (`xs[i]`, `ys[i]`) in a spatial index, with their elevations and
  ## stations in its order, and where each given point went.
  var order: seq[int32]
  result.points = PointSet(index: initSpatialIndex(xs, ys, order))
  result.points.z = newSeq[float64](order.len)
  result.points.station = newSeq[Station](order.len)
  result.rank = newSeq[int32](order.len)
  for i, old in order:
    result.points.z[i] = zs[old]
    result.points.station[i] = stations[old]
    result.rank[old] = int32(i)

type
  TracePending = object
    ## One role's points and stations while a traces layer is made.
    xs, ys, zs: seq[float64]
    pointStation: seq[int32] ## per point: its station; -1 for none
    points, stationIds: IdTable
    stations: seq[StationKey]
    last: tuple[x, y, line, point: uint64; index: int16; station, at: int32]
    hasLast: bool

  TraceLayerBuilder* = object
    ## Makes a traces layer from a file's keys, a chunk at a time (`add`),
    ## then `finish`.
    layer: SurveyLayer
    pending: array[PointRole, TracePending]
    next: int ## the trace `add` takes next

const
  Missing = -1'i32 ## a position without coordinates
  Zero = -2'i32    ## a position at (0, 0)

proc initTraceLayerBuilder*(path: string; kind: FileKind; session: SessionId;
    base, traces, keysRevision: int): TraceLayerBuilder =
  ## A builder for the `traces` traces of open file `session` (at `path`),
  ## whose trace 0 is survey-wide trace `base`.
  result = TraceLayerBuilder(layer: SurveyLayer(origin: loTraces, kind: kind, path: path,
    name: path.extractFilename, session: session, base: base, traces: traces,
    keysRevision: keysRevision))
  for r in PointRole:
    result.layer.pointOf[r] = newSeq[int32](traces)
    result.layer.stationOf[r] = newSeq[int32](traces)

proc place(b: var TraceLayerBuilder; r: PointRole; t: int; x, y, z, line, point: float64;
    index: int16) =
  ## Trace `t`'s position in role `r`.
  template p: untyped = b.pending[r]
  template c: untyped = b.layer.counts[r]
  inc c.given
  var station, at: int32
  let now = (x: bits(x), y: bits(y), line: bits(line), point: bits(point))
  if p.hasLast and now.x == p.last.x and now.y == p.last.y and now.line == p.last.line and
      now.point == p.last.point and index == p.last.index:
    # As the trace before (a shot's source, a station's other components).
    (station, at) = (p.last.station, p.last.at)
  else:
    station = -1
    if not (line.isNaN or point.isNaN):
      let key = stationKey(line, point, index)
      station = p.stationIds.findOrAdd(stationHash(key), same(p.stations[id], key),
        p.stations.add key)[0]
    if not (finite(x) and finite(y)): at = Missing
    elif x == 0 and y == 0: at = Zero
    else:
      at = p.points.findOrAdd(pointHash(station, x, y), p.xs[id] == x and p.ys[id] == y and
        p.pointStation[id] == station, (p.xs.add x; p.ys.add y; p.zs.add z;
        p.pointStation.add station))[0]
      if p.zs[at].isNaN: p.zs[at] = z
    p.last = (now.x, now.y, now.line, now.point, index, station, at)
    p.hasLast = true
  if station < 0: inc c.noStation
  case at
  of Missing: inc c.missing
  of Zero: inc c.zero
  else:
    inc c.placed
  b.layer.stationOf[r][t] = station
  b.layer.pointOf[r][t] = max(at, -1)

proc add*(b: var TraceLayerBuilder; keys: openArray[TraceKeys]) =
  ## Takes the keys of the next `keys.len` traces. Raises `ValueError` past
  ## the file's last trace.
  if b.next + keys.len > b.layer.traces:
    raise newException(ValueError, "more keys than the file has traces")
  for k in keys:
    let t = b.next
    inc b.next
    if not k.isSeismic:
      inc b.layer.auxiliary
      for r in PointRole:
        b.layer.pointOf[r][t] = -1
        b.layer.stationOf[r][t] = -1
    else:
      b.place(prSource, t, k.srcX, k.srcY, k.srcZ, k.srcLine, k.srcPoint, k.srcIndex)
      b.place(prReceiver, t, k.rcvX, k.rcvY, k.rcvZ, k.rcvLine, k.rcvPoint, k.rcvIndex)

proc finish*(b: var TraceLayerBuilder): SurveyLayer =
  ## The layer: its points indexed, each point's and station's traces.
  ## Traces never given (`add`) have no position.
  for t in b.next ..< b.layer.traces:
    for r in PointRole:
      b.layer.pointOf[r][t] = -1
      b.layer.stationOf[r][t] = -1
  result = move b.layer
  for r in PointRole:
    template p: untyped = b.pending[r]
    var stations = newSeq[Station](p.xs.len)
    for i, s in p.pointStation:
      stations[i] = if s >= 0: asStation(p.stations[s]) else: noStation()
    var (points, rank) = indexed(p.xs, p.ys, p.zs, stations)
    for at in result.pointOf[r].mitems:
      if at >= 0: at = rank[at]
    groups(result.pointOf[r], points.len, points.traceStart, points.traceList)
    result.counts[r].merged = result.counts[r].placed - points.len
    result.bounds.incl points.index.bounds
    result.points[r] = move points
    var ss = StationSet(keys: move p.stations, ids: move p.stationIds)
    groups(result.stationOf[r], ss.keys.len, ss.traceStart, ss.traceList)
    result.stations[r] = move ss

# -------------------------------------------------------- survey files --

type
  FilePending = object
    ## One role's points while a survey file's layer is made.
    xs, ys, zs: seq[float64]
    stations: seq[Station]
    ids: IdTable

  SurveyFileBuilder* = object
    ## Makes a survey file's layer from its records (`addPoint`,
    ## `addRelations`), then `finish`.
    layer: SurveyLayer
    pending: array[PointRole, FilePending]

proc initSurveyFileBuilder*(path: string; kind: FileKind; size: int64;
    modified: Time; lineNames: openArray[(string, float64)] = [];
    trailingDigits = false): SurveyFileBuilder =
  ## A builder for the survey file at `path`, of `kind`, read at `size`
  ## bytes and `modified`, whose text line names (SPS 1.0, P1) are numbers
  ## as parseSEG's join makes them: `lineNames` mapped, else with
  ## `trailingDigits` the digits they end in (`lineOf`).
  let relations = new SurveyGeometry
  relations[] = initSurveyGeometry()
  relations.trailingDigits = trailingDigits
  for (name, line) in lineNames:
    if name.strip.len > 0 and not line.isNaN: relations[].mapLine(name, line)
  SurveyFileBuilder(layer: SurveyLayer(origin: loSurveyFile, kind: kind, path: path,
    name: path.extractFilename, size: size, modified: modified, relations: relations))

func lineOf*(b: SurveyFileBuilder; name: string; numeric: float64): float64 =
  ## The line number of a record whose line field reads `name` (`numeric`
  ## when it is a number), as parseSEG's join resolves it (`resolveLine`,
  ## with the builder's line names and trailing digits); NaN for none.
  b.layer.relations[].resolveLine(name, numeric).get(NaN)

func sameLineNames*(l: SurveyLayer; lineNames: openArray[(string, float64)];
    trailingDigits: bool): bool =
  ## Whether survey file layer `l` was read with these line names and
  ## trailing digits (a text line name may be read otherwise with others).
  if l.relations.isNil: return true
  template g: untyped = l.relations[]
  var n = 0
  for (name, line) in lineNames:
    if name.strip.len > 0 and not line.isNaN:
      inc n
      if g.lineNames.getOrDefault(name.strip, NaN) != line: return false
  g.trailingDigits == trailingDigits and g.lineNames.len == n

proc addPoint*(b: var SurveyFileBuilder; r: PointRole; line, point: float64; index: int16;
    x, y, z: float64) =
  ## A point record: station (`line`, `point`, `index`; NaN line or point
  ## for none) at (`x`, `y`) with elevation `z` (NaN when not known). A
  ## station given before moves to these coordinates.
  template p: untyped = b.pending[r]
  template c: untyped = b.layer.counts[r]
  inc c.given
  let known = not (line.isNaN or point.isNaN)
  if not known: inc c.noStation
  if not (finite(x) and finite(y)): inc c.missing
  elif x == 0 and y == 0: inc c.zero
  else:
    inc c.placed
    var fresh = true
    if known:
      let key = stationKey(line, point, index)
      let (at, found) = p.ids.findOrAdd(stationHash(key), same(p.stations[id], key),
        (p.xs.add x; p.ys.add y; p.zs.add z; p.stations.add asStation(key)))
      fresh = not found
      if found:
        inc c.replaced
        if p.xs[at] != x or p.ys[at] != y: inc c.moved
        (p.xs[at], p.ys[at], p.zs[at]) = (x, y, z)
    if fresh and not known:
      # A point of its own: a hash that never matches a station's key.
      discard p.ids.findOrAdd(mix(uint64(p.xs.len) + 0x9E3779B97F4A7C15'u64), false,
        (p.xs.add x; p.ys.add y; p.zs.add z; p.stations.add noStation()))

proc addRelations*(b: var SurveyFileBuilder; f: SpsFile) =
  ## The relation records (X, O) of `f`, part of an SPS file, as parseSEG's
  ## join reads them (its point records are left alone: `addPoint` takes
  ## them); and its grid unit, when it gives one.
  if f.relations.len > 0:
    var part = SpsFile(name: f.name, revision: f.revision, headers: f.headers,
      relations: f.relations)
    b.layer.relations[].addSps(part, relationDomainOf(f.name))
  if not b.layer.gridUnit.known: b.layer.gridUnit = f.gridUnit

func relationsLog*(b: SurveyFileBuilder): lent DiagLog {.inline.} =
  ## What parseSEG's join said of the relations taken so far.
  b.layer.relations[].log

proc finish*(b: var SurveyFileBuilder): SurveyLayer =
  ## The layer: its points indexed and found by station.
  result = move b.layer
  for r in PointRole:
    template p: untyped = b.pending[r]
    var (points, _) = indexed(p.xs, p.ys, p.zs, p.stations)
    var hashes = newSeq[uint64](points.len)
    for i, s in points.station:
      hashes[i] = if s.known: stationHash(stationKey(s.line, s.point, s.index))
                  else: mix(uint64(i) + 0x9E3779B97F4A7C15'u64)
    points.ids = fitted(hashes)
    result.bounds.incl points.index.bounds
    result.points[r] = move points
  result.xRuns = result.relations[].relationCount(rdSource) # (a count walks them all)
  result.relationRuns = result.xRuns + result.relations[].relationCount(rdReceiver)
  var records = 0
  for d in RelationDomain:
    for _ in result.relations[].records(d): inc records
  result.relationRecords = records

proc withLevels*(l: var SurveyLayer) =
  ## Makes the map's levels of detail of each role's points (on the worker
  ## that made the layer: a million points take a few tens of ms).
  for r in PointRole: l.levels[r] = buildLevels(l.points[r].index)

# ------------------------------------------------------- finding points --

func stationPoint*(l: SurveyLayer; r: PointRole; s: Station): int =
  ## The point of station `s` in survey file layer `l`, as parseSEG's join
  ## finds a station: the same index, else one given for any index (0), else
  ## for a station without an index (0), the first position (1). -1 for
  ## none, for a station not known, and in a traces layer.
  result = -1
  if l.origin != loSurveyFile or not s.known: return
  let tries = [s.index, 0'i16, 1'i16]
  for i in 0 .. (if s.index == 0: 2 else: 1):
    let key = stationKey(s.line, s.point, tries[i])
    let at = l.points[r].ids.find(stationHash(key), same(l.points[r].station[id], key))
    if at >= 0: return at

func pointOf*(l: SurveyLayer; r: PointRole; trace: int): int =
  ## Traces layer `l`: the point of its file's trace `trace` (an index in
  ## the file) in role `r`; -1 for none (no coordinates, auxiliary, out of
  ## range, or a survey file's layer).
  if l.origin == loTraces and trace in 0 ..< l.pointOf[r].len: int(l.pointOf[r][trace]) else: -1

func stationOf*(l: SurveyLayer; r: PointRole; trace: int): Station =
  ## Traces layer `l`: the station of its file's trace `trace` in role `r`;
  ## not known for none.
  result = noStation()
  if l.origin == loTraces and trace in 0 ..< l.stationOf[r].len:
    let s = l.stationOf[r][trace]
    if s >= 0: result = asStation(l.stations[r].keys[s])

iterator tracesAt*(l: SurveyLayer; r: PointRole; point: int): int =
  ## Traces layer `l`: the traces (indices in its file) at `point` of role
  ## `r`, in file order.
  if l.origin == loTraces and point in 0 ..< l.points[r].len:
    let p = addr l.points[r]
    for i in p.traceStart[point] ..< p.traceStart[point + 1]: yield int(p.traceList[i])

func stationCount*(l: SurveyLayer; r: PointRole): int =
  ## Traces layer `l`: the stations of its traces in role `r`, with
  ## coordinates or not.
  l.stations[r].keys.len

iterator stationTraces*(l: SurveyLayer; r: PointRole; s: Station): int =
  ## Traces layer `l`: the traces (indices in its file) whose station in
  ## role `r` is `s`, as parseSEG's join matches them: the same index; a
  ## station of the first position (1) also takes traces without an index
  ## (0), and one for any index (0) takes every index.
  if l.origin == loTraces and s.known:
    let ss = addr l.stations[r]
    var indices: seq[int16]
    if s.index == 0:
      for i in 0'i16 .. 9'i16: indices.add i
    elif s.index == 1: indices = @[1'i16, 0'i16]
    else: indices = @[s.index]
    for index in indices:
      let key = stationKey(s.line, s.point, index)
      let at = ss.ids.find(stationHash(key), same(ss.keys[id], key))
      if at >= 0:
        for i in ss.traceStart[at] ..< ss.traceStart[at + 1]: yield int(ss.traceList[i])

# --------------------------------------------------------------- survey --

func layers*(s: Survey): lent seq[SurveyLayer] {.inline.} = s.layers
  ## Every layer: survey files in the order they were loaded, and open
  ## files' traces.

func find*(s: Survey; id: SurveyLayerId): int =
  ## The index of layer `id` in `layers`; -1 for none.
  for i, l in s.layers:
    if l.id == id: return i
  -1

func findFile*(s: Survey; path: string): int =
  ## The index of the layer of survey file `path`; -1 when it is not loaded.
  for i, l in s.layers:
    if l.origin == loSurveyFile and l.path == path: return i
  -1

func findTraces*(s: Survey; session: SessionId): int =
  ## The index of the traces layer of open file `session`; -1 for none.
  for i, l in s.layers:
    if l.origin == loTraces and l.session == session: return i
  -1

proc add*(s: var Survey; layer: sink SurveyLayer): SurveyLayerId =
  ## Adds `layer` under a new id, which it returns; it takes the place of
  ## the layer of the same survey file, or of the same open file's traces.
  inc s.nextId
  result = SurveyLayerId(s.nextId)
  layer.id = result
  let old = if layer.origin == loSurveyFile: s.findFile(layer.path)
            else: s.findTraces(layer.session)
  if old >= 0: s.layers[old] = layer
  else: s.layers.add layer
  inc s.revision

proc remove*(s: var Survey; id: SurveyLayerId): bool =
  ## Takes layer `id` out; false when there is none.
  let i = s.find(id)
  result = i >= 0
  if result:
    s.layers.delete(i)
    inc s.revision

func bounds*(s: Survey): Bounds =
  ## Of every point of every layer; empty for none.
  result = Bounds() # a result starts zeroed, not at the fields' defaults
  for l in s.layers: result.incl l.bounds

func tracePoints*(s: Survey; trace: int; keys: TraceKeys): seq[PointRef] =
  ## Where survey-wide trace `trace`, whose keys are `keys` (as a tile
  ## carries them), was recorded, in every layer: its own source and
  ## receiver points in its file's traces layer, and the points of its
  ## source and receiver stations in each survey file's layer. Stations the
  ## keys lack are filled from the survey files' relations, as parseSEG's
  ## join fills them (`joinStations`).
  var k = keys
  for l in s.layers:
    if l.relationRuns > 0 and (k.srcLine.isNaN or k.srcPoint.isNaN or k.rcvLine.isNaN or
        k.rcvPoint.isNaN):
      discard joinStations(k, l.relations[])
  let ends = [Station(line: k.srcLine, point: k.srcPoint, index: k.srcIndex),
    Station(line: k.rcvLine, point: k.rcvPoint, index: k.rcvIndex)]
  for l in s.layers:
    for r in PointRole:
      let at = case l.origin
        of loTraces: l.pointOf(r, trace - l.base)
        of loSurveyFile: l.stationPoint(r, ends[ord(r)])
      if at >= 0: result.add PointRef(layer: l.id, role: r, point: at)

func tracePointsOf*(s: Survey; trace: int): seq[PointRef] =
  ## Where survey-wide trace `trace` was recorded, as its own file's traces
  ## layer has it: its source and receiver points there, and the points of
  ## those stations in each survey file's layer. None while its file's
  ## positions are not read. (`tracePoints` also fills stations the keys
  ## lack from the relation files.)
  var own = -1
  for i, l in s.layers:
    if l.origin == loTraces and trace in l.base ..< l.base + l.traces: own = i
  if own < 0: return
  template l: untyped = s.layers[own]
  let t = trace - l.base
  for r in PointRole:
    let at = l.pointOf(r, t)
    if at >= 0: result.add PointRef(layer: l.id, role: r, point: at)
    let st = l.stationOf(r, t)
    if st.known:
      for m in s.layers:
        if m.origin == loSurveyFile:
          let p = m.stationPoint(r, st)
          if p >= 0: result.add PointRef(layer: m.id, role: r, point: p)

proc recordPoints*(s: Survey; base: int; traces: Slice[int]; record = -1'i64): seq[PointRef] =
  ## Where the traces `traces` (indices in the open file whose trace 0 is
  ## survey-wide `base`: a gather) were recorded, each point once: their
  ## points in the file's traces layer and the points of their stations in
  ## each survey file's layer. Where none of them names a station (headers
  ## with a record and a channel only), the stations the loaded relation
  ## files give field record `record` (-1 for none) stand in for theirs.
  ## None while the file's positions are not read.
  var own = -1
  for i in 0 ..< s.layers.len:
    if s.layers[i].origin == loTraces and s.layers[i].base == base: own = i
  if own < 0: return
  var seen: IntSet
  var stations: array[PointRole, seq[Station]]
  var named: array[PointRole, IntSet]
  template keep(p: PointRef) =
    if p.key notin seen:
      seen.incl p.key
      result.add p
  block:
    template l: untyped = s.layers[own]
    for t in max(traces.a, 0) .. min(traces.b, l.traces - 1):
      for r in PointRole:
        let at = l.pointOf[r][t]
        if at >= 0: keep(PointRef(layer: l.id, role: r, point: int(at)))
        let st = l.stationOf[r][t]
        if st >= 0 and st notin named[r]:
          named[r].incl st
          stations[r].add asStation(l.stations[r].keys[st])
  if stations[prSource].len + stations[prReceiver].len == 0 and record >= 0:
    var given: array[PointRole, IntSet] # by station hash: each once
    template plan(r: PointRole; k: StationKey) =
      let h = int(stationHash(k) shr 1)
      if h notin given[r]:
        given[r].incl h
        stations[r].add asStation(k)
    for i in 0 ..< s.layers.len:
      template m: untyped = s.layers[i]
      if m.origin == loSurveyFile and m.relationRuns > 0:
        for run in m.relations[].relationRuns(record):
          plan(prSource, run.fixed)
          for k in 0 ..< run.stations: plan(prReceiver, run.station(k))
  for r in PointRole:
    for st in stations[r]:
      for i in 0 ..< s.layers.len:
        if s.layers[i].origin == loSurveyFile:
          let p = s.layers[i].stationPoint(r, st)
          if p >= 0: keep(PointRef(layer: s.layers[i].id, role: r, point: p))

proc lineRange*(s: Survey; a, b: PointRef): seq[PointRef] =
  ## The points from `a` to `b` along their line: the points of `b`'s layer
  ## and role whose station is on the line of both, its point between
  ## theirs, in the order of the points (what a Shift + click from `a` to
  ## `b` selects). `b` alone when the two are of other layers or roles, not
  ## on one line, or either has no station.
  result = @[b]
  if a.layer != b.layer or a.role != b.role: return
  let i = s.find(b.layer)
  if i < 0: return
  template ps: untyped = s.layers[i].points[b.role]
  if a.point notin 0 ..< ps.len or b.point notin 0 ..< ps.len: return
  let (sa, sb) = (ps.station[a.point], ps.station[b.point])
  if not (sa.known and sb.known) or sa.line != sb.line: return
  let (lo, hi) = (min(sa.point, sb.point), max(sa.point, sb.point))
  var found: seq[(float64, int16, int)]
  for j in 0 ..< ps.len:
    let st = ps.station[j]
    if st.line == sa.line and st.point >= lo and st.point <= hi: found.add (st.point, st.index, j)
  found.sort()
  result.setLen 0
  for (_, _, j) in found: result.add PointRef(layer: b.layer, role: b.role, point: j)

func tracesAt*(s: Survey; at: PointRef): seq[int] =
  ## The survey-wide ids of the open files' traces recorded at point `at`:
  ## a traces layer's point, its traces; a survey file's point, the traces
  ## of every open file whose station it is.
  let i = s.find(at.layer)
  if i < 0 or at.point notin 0 ..< s.layers[i].points[at.role].len: return
  template l: untyped = s.layers[i]
  case l.origin
  of loTraces:
    for t in l.tracesAt(at.role, at.point): result.add l.base + t
  of loSurveyFile:
    let st = l.points[at.role].station[at.point]
    for m in s.layers:
      for t in m.stationTraces(at.role, st): result.add m.base + t

# -------------------------------------------------------------- in words --

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func problems*(l: SurveyLayer): seq[string] =
  ## What was left off the map, or taken twice, in plain words; none when
  ## every position was placed.
  let what = if l.origin == loTraces: ("trace", "traces") else: ("record", "records")
  for r in PointRole:
    let c = l.counts[r]
    let role = $r
    if c.missing > 0:
      result.add plural(c.missing, what[0], what[1]) & " without " & role & " coordinates"
    if c.zero > 0:
      result.add plural(c.zero, what[0], what[1]) & " with the " & role & " at (0, 0)"
    if l.origin == loSurveyFile and c.replaced > 0:
      result.add plural(c.replaced, role & " station", role & " stations") & " given again" &
        (if c.moved > 0: " (" & $c.moved & " at other coordinates: the last is kept)" else: "")

func summary*(l: SurveyLayer): string =
  ## What the layer holds, in plain words: "6385 receiver points",
  ## "72 traces at 3 source and 24 receiver points".
  var parts: seq[string]
  for r in PointRole:
    if l.counts[r].given > 0 or l.points[r].len > 0:
      parts.add plural(l.points[r].len, $r & " point", $r & " points")
  if l.relationRuns > 0:
    parts.add plural(l.relationRuns, "relation record", "relation records") & " for " &
      plural(l.relationRecords, "field record", "field records")
  if l.origin == loTraces:
    result = plural(l.traces, "trace", "traces") & " at " &
      (if parts.len == 0: "no point" else: parts.join(" and "))
  elif parts.len == 0: result = "no point and no relation"
  else: result = parts.join(", ")
