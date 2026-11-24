## The project document (`project.nif`) and the note of who has a project
## open (`owner.nif`), as NIF text a person can read:
##
## ```
## (.nif27)
## (.vendor "viewSEG")
## (project
##  (version 1)
##  (name "Land 2026")
##  (created "2026-11-15T21:40:00Z")
##  (data (folder (path "../field/day1") (absolute "/mnt/field/day1")))
##  (survey
##   (file (kind sps) (role column) (copy "survey/files/land.sps")
##    (path "../survey/land.sps") (absolute "/mnt/survey/land.sps")
##    (size 4812733) (modified 1763200961 120000000) (quick "9a0c51f3e2d4b6a7"))
##   (join (trailingDigits false) (multiComponent false) (coordinates fill) ...)
##   (units (survey usFeet) (file usFeet) (surveyFromHeaders false) (fileFromHeaders true))
##   (notes "H20 Description of grid units: US survey feet")
##   (imported "2026-11-15T21:42:10Z")
##   (store (format 1) (bytes 31457280) (hash "51f3...") (sources 1200) (receivers 3954)
##    (relations 1200)))
##  (processing (dc none) (band bandPass) (f1 4.0) ...)
##  (displayPresets (preset "Section" (mode density) ...)))
## ```
##
## Reading is forgiving and says what it did: what is missing keeps its
## default, what cannot be used is said with its line, and what this
## version does not know is kept (`ProjectDoc.later`) and written back as it
## was. A document of a later version than `ProjectVersion` reads as far as
## it can; the program then opens the project read-only.
##
## A station moved during a deployment is
## `(stationMoves (move (line ...) (point ...) (index ...) (x ...) (y ...)))`.
## `fromTime` (the same absolute time as `TraceKeys.time`) and `elev` are
## written when given; a move with no `fromTime` holds for every trace of
## the station. Absent means no moves. The position is not written into the
## seismic file or the survey file.

import std/[math, options, strutils, times]
import parseSEG
import analysis, breakmodel, identity, join, nif, processing, project, settings,
  settingsnif, stationmoves, vendormaps, vibprofile

const
  KindNames: array[JoinFileKind, string] = ["sps", "p1", "csv"]
  RoleNames: array[CsvRole, string] = ["column", "sources", "receivers"]
  UnitNames: array[SurveyUnit, string] = ["notGiven", "metres", "feet", "usFeet", "degrees",
    "arcSeconds", "dms"]

proc timeText(t: Time): string = t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc parseTimeText(s: string; t: var Time): bool =
  try:
    t = parse(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime
    true
  except TimeParseError, ValueError:
    false

proc value(w: var NifWriter; tag: string; s: string) =
  w.open tag
  w.add s
  w.close

proc value(w: var NifWriter; tag: string; i: int64) =
  w.open tag
  w.add i
  w.close

proc value(w: var NifWriter; tag: string; b: bool) =
  w.open tag
  w.add b
  w.close

proc value(w: var NifWriter; tag: string; x: float64) =
  w.open tag
  w.add x
  w.close

proc finite(x: float64): bool {.inline.} =
  x == x and x != Inf and x != -Inf

proc writeMove(w: var NifWriter; m: StationMove) =
  w.open "move"
  w.value("line", m.station.line)
  w.value("point", m.station.point)
  w.value("index", int64(m.station.index))
  if m.fromTime.isSome: w.value("fromTime", m.fromTime.get)
  w.value("x", m.x)
  w.value("y", m.y)
  if m.elev.isSome: w.value("elev", m.elev.get)
  if m.note.len > 0: w.value("note", m.note)
  w.close

proc choice(w: var NifWriter; tag, name: string) =
  w.open tag
  w.ident name
  w.close

proc place(w: var NifWriter; p: ProjectPath) =
  if p.path.len > 0: w.value("path", p.path)
  if p.absolute.len > 0: w.value("absolute", p.absolute)

proc modified(w: var NifWriter; t: Time; tag = "modified") =
  w.open tag
  w.add t.toUnix
  w.add int64(t.nanosecond)
  w.close

proc writeLimit(w: var NifWriter; tag: string; x: float64) =
  if finite(x): w.value(tag, x)

proc writeVibProfile(w: var NifWriter; p: VibQcProfile) =
  ## The job's vibrator QC profile. A limit or a typed value that is not set
  ## is left out; a field this version does not know is written back.
  w.open "vibProfile"
  if finite(p.qcWindowMs): w.value("qcWindowMs", p.qcWindowMs)
  w.value("harmonics", int64(p.harmonics))
  w.choice("accelSet", $p.accelSet)
  w.open "limits"
  w.writeLimit("avgPhaseDeg", p.limits.avgPhaseDeg)
  w.writeLimit("peakPhaseDeg", p.limits.peakPhaseDeg)
  w.writeLimit("avgDistortionPct", p.limits.avgDistortionPct)
  w.writeLimit("peakDistortionPct", p.limits.peakDistortionPct)
  w.writeLimit("avgForcePct", p.limits.avgForcePct)
  w.writeLimit("peakForcePct", p.limits.peakForcePct)
  w.close
  if finite(p.forceScale.datCountsPerLbf) or finite(p.forceScale.vibAccMvPerCount):
    w.open "forceScale"
    if finite(p.forceScale.datCountsPerLbf):
      w.value("datCountsPerLbf", p.forceScale.datCountsPerLbf)
    if finite(p.forceScale.vibAccMvPerCount):
      w.value("vibAccMvPerCount", p.forceScale.vibAccMvPerCount)
    w.close
  if finite(p.forceHundredPct): w.value("forceHundredPct", p.forceHundredPct)
  if finite(p.targetPct): w.value("targetPct", p.targetPct)
  if p.referenceId.len > 0: w.value("referenceId", p.referenceId)
  if finite(p.topHz): w.value("topHz", p.topHz)
  for n in p.later: w.add n
  w.close

proc writeVibWeights(w: var NifWriter; m: VibJobWeights) =
  ## The job's vibrator weights, in kilograms. One not set is left out; a field
  ## this version does not know is written back. Not a file header's weights.
  w.open "vibWeights"
  if finite(m.holdDownKg): w.value("holdDownKg", m.holdDownKg)
  if finite(m.baseplateMassKg): w.value("baseplateMassKg", m.baseplateMassKg)
  if finite(m.reactionMassKg): w.value("reactionMassKg", m.reactionMassKg)
  for n in m.later: w.add n
  w.close

proc projectDocument*(d: ProjectDoc): string =
  ## `d` as the project document (the module's documentation).
  var w = initNifWriter(breakDepth = 2)
  w.open "project"
  w.value("version", int64(ProjectVersion))
  w.value("name", d.name)
  if d.created != Time(): w.value("created", timeText(d.created))
  w.open "data"
  for f in d.data:
    w.open "folder"
    w.place f
    w.close
  w.close
  if d.hasSurvey or d.hasImport:
    w.open "survey"
    for f in d.survey:
      w.open "file"
      w.choice("kind", KindNames[f.kind])
      if f.kind == jkCsv: w.choice("role", RoleNames[f.role])
      w.value("copy", f.copy)
      w.place f.original
      w.value("size", f.size)
      w.modified f.modified
      w.value("quick", hex(f.quick))
      if f.full != 0: w.value("full", hex(f.full))
      if f.changedModified != Time(): w.modified(f.changedModified, "changedModified")
      w.close
    w.writeJoinOptions(d.options)
    w.open "units"
    w.choice("survey", UnitNames[d.units.survey])
    w.choice("file", UnitNames[d.units.file])
    w.value("surveyFromHeaders", d.units.surveyFromHeaders)
    w.value("fileFromHeaders", d.units.fileFromHeaders)
    w.close
    if d.notes.len > 0:
      w.open "notes"
      for n in d.notes: w.add n
      w.close
    if d.imported != Time(): w.value("imported", timeText(d.imported))
    if d.hasStore:
      w.open "store"
      w.value("format", int64(d.store.format))
      w.value("bytes", d.store.bytes)
      w.value("hash", hex(d.store.hash))
      w.value("sources", int64(d.store.sources))
      w.value("receivers", int64(d.store.receivers))
      w.value("relations", int64(d.store.relations))
      w.close
    w.close
  if d.hasImport:
    w.open "importing"
    for f in d.importing:
      w.open "file"
      w.choice("kind", KindNames[f.kind])
      if f.kind == jkCsv: w.choice("role", RoleNames[f.role])
      w.place f.original
      if f.known:
        w.value("size", f.size)
        w.modified f.modified
        w.value("quick", hex(f.quick))
      w.close
    w.close
  w.value("referenceId", d.referenceId)
  for c in d.vibRoles: w.value("vibRole", c)
  for c in d.vibTops: w.value("vibTop", c)
  if d.hasVibProfile: w.writeVibProfile(d.vibProfile)
  if d.vibJobWeights.weightsSet: w.writeVibWeights(d.vibJobWeights)
  if d.stationMoves.len > 0:
    w.open "stationMoves"
    for m in d.stationMoves: w.writeMove m
    w.close
  if d.lastFolder.len > 0: w.value("lastFolder", d.lastFolder)
  if d.includeSubfolders: w.value("includeSubfolders", true)
  case d.vendorChoice.mode
  of vmAutomatic: discard
  of vmNamed: w.value("vendorMap", d.vendorChoice.name)
  of vmNone: w.value("vendorMap", "") # (a named map is never empty)
  if d.hasProcessing: w.writeProcessing(d.processing)
  if d.hasPresets: w.writeDisplayPresets(d.displayPresets)
  if d.hasBreakModel: w.writeBreakModel(d.breakModel)
  for n in d.later: w.add n
  w.close
  w.finish

# ----------------------------------------------------------------- reading --

type Reading = object
  name: string
  problems: seq[string]

proc problem(r: var Reading; n: NifNode; text: string) =
  if r.problems.len < WordedProblems: r.problems.add r.name & " line " & $n.line & ": " & text
  else: r.problems.add ""

proc text(r: var Reading; n: NifNode; x: var string) =
  if n.kids.len == 1 and n.kids[0].kind == nkString: x = n.kids[0].text
  else: r.problem(n, "(" & n.tag & ") needs a string")

proc integer(r: var Reading; n: NifNode; x: var int64) =
  if n.kids.len == 1 and n.kids[0].kind == nkInt: x = n.kids[0].intVal
  else: r.problem(n, "(" & n.tag & ") needs a whole number")

proc count(r: var Reading; n: NifNode; x: var int) =
  var v = 0'i64
  r.integer(n, v)
  if v >= 0 and v <= high(int32): x = int(v)
  else: r.problem(n, "(" & n.tag & ") needs a count")

proc flag(r: var Reading; n: NifNode; x: var bool) =
  if n.kids.len == 1 and n.kids[0].kind == nkIdent and n.kids[0].text in ["true", "false"]:
    x = n.kids[0].text == "true"
  else: r.problem(n, "(" & n.tag & ") needs true or false")

proc choice[T: enum](r: var Reading; n: NifNode; names: array[T, string]; x: var T) =
  if n.kids.len == 1 and n.kids[0].kind == nkIdent:
    for v, name in names:
      if name == n.kids[0].text:
        x = v
        return
  r.problem(n, "(" & n.tag & ") needs one of " & names.join(", "))

proc time(r: var Reading; n: NifNode; x: var Time) =
  var s = ""
  r.text(n, s)
  if s.len > 0 and not parseTimeText(s, x): r.problem(n, "(" & n.tag & ") is not a time")

proc hash(r: var Reading; n: NifNode; x: var uint64) =
  var s = ""
  r.text(n, s)
  if s.len != 16 or not s.allCharsInSet(HexDigits):
    r.problem(n, "(" & n.tag & ") needs 16 hexadecimal digits")
  else: x = fromHex[uint64](s)

proc place(r: var Reading; n: NifNode; p: var ProjectPath): bool =
  ## Takes `(path ...)` and `(absolute ...)` of `n` into `p`; false for
  ## another node.
  result = true
  if n.isTree("path"): r.text(n, p.path)
  elif n.isTree("absolute"): r.text(n, p.absolute)
  else: result = false

proc folders(r: var Reading; n: NifNode; d: var ProjectDoc) =
  for c in n.kids:
    if c.isTree("folder"):
      var p = ProjectPath()
      for k in c.kids:
        if k.kind != nkTree or not r.place(k, p): discard # a later version's
      if p.path.len == 0 and p.absolute.len == 0: r.problem(c, "(folder) names no folder")
      elif d.data.len < MaxProjectData: d.data.add p
    else: r.problem(c, "(data) holds folders: (folder (path ...) (absolute ...))")

proc isSurveyCopy(copy: string): bool =
  ## `copy` is `survey/files/<name>` with `<name>` a plain file name: not
  ## empty, not `.` or `..`, and without a separator or a drive colon.
  const Prefix = SurveyCopies & "/"
  if not copy.startsWith(Prefix): return false
  let name = copy[Prefix.len .. ^1]
  name.len > 0 and name notin [".", ".."] and name.find({'/', '\\', ':'}) < 0

proc surveyFile(r: var Reading; n: NifNode; d: var ProjectDoc) =
  var f = SurveyCopy()
  for k in n.kids:
    if k.kind != nkTree: r.problem(k, "(file) holds trees")
    elif r.place(k, f.original): discard
    else:
      case k.tag
      of "kind": r.choice(k, KindNames, f.kind)
      of "role": r.choice(k, RoleNames, f.role)
      of "copy": r.text(k, f.copy)
      of "size": r.integer(k, f.size)
      of "modified":
        if k.kids.len == 2 and k.kids[0].kind == nkInt and k.kids[1].kind == nkInt and
            k.kids[1].intVal in 0 ..< 1_000_000_000:
          f.modified = initTime(k.kids[0].intVal, int(k.kids[1].intVal))
        else: r.problem(k, "(modified) needs seconds and nanoseconds")
      of "quick": r.hash(k, f.quick)
      of "full": r.hash(k, f.full)
      of "changedModified":
        if k.kids.len == 2 and k.kids[0].kind == nkInt and k.kids[1].kind == nkInt and
            k.kids[1].intVal in 0 ..< 1_000_000_000:
          f.changedModified = initTime(k.kids[0].intVal, int(k.kids[1].intVal))
      else: discard
  if f.copy.len == 0: r.problem(n, "a survey file names no copy; it is left out")
  elif not f.copy.isSurveyCopy:
    r.problem(n, "a survey file's copy is not a file in survey/files; it is left out")
  else: d.survey.add f

proc importFiles(r: var Reading; n: NifNode; d: var ProjectDoc) =
  for c in n.kids:
    if c.isTree("file"):
      var f = ImportFile()
      for k in c.kids:
        if k.kind != nkTree: r.problem(k, "(file) holds trees")
        elif r.place(k, f.original): discard
        elif k.tag == "kind": r.choice(k, KindNames, f.kind)
        elif k.tag == "role": r.choice(k, RoleNames, f.role)
        elif k.tag == "size": r.integer(k, f.size)
        elif k.tag == "modified":
          if k.kids.len == 2 and k.kids[0].kind == nkInt and k.kids[1].kind == nkInt and
              k.kids[1].intVal in 0 ..< 1_000_000_000:
            f.modified = initTime(k.kids[0].intVal, int(k.kids[1].intVal))
          else: r.problem(k, "(modified) needs seconds and nanoseconds")
        elif k.tag == "quick":
          r.hash(k, f.quick)
          f.known = true
      if f.original.path.len == 0 and f.original.absolute.len == 0:
        r.problem(c, "an imported file names no original; it is left out")
      elif d.importing.len < 4096: d.importing.add f
    else: r.problem(c, "(importing) holds files")

proc units(r: var Reading; n: NifNode; u: var JoinUnits) =
  for k in n.kids:
    if k.isTree("survey"): r.choice(k, UnitNames, u.survey)
    elif k.isTree("file"): r.choice(k, UnitNames, u.file)
    elif k.isTree("surveyFromHeaders"): r.flag(k, u.surveyFromHeaders)
    elif k.isTree("fileFromHeaders"): r.flag(k, u.fileFromHeaders)

proc finiteNumber(n: NifNode; x: var float64): bool =
  ## Whether `n` is `(tag v)` with `v` a finite number.
  if n.kids.len != 1: return false
  case n.kids[0].kind
  of nkFloat: x = n.kids[0].floatVal
  of nkInt: x = float64(n.kids[0].intVal)
  else: return false
  x == x and x != Inf and x != -Inf

proc readMove(r: var Reading; n: NifNode; moves: var StationMoves) =
  ## One `(move ...)`. A move without a line, a point, an x or a y, or with a
  ## `fromTime` or an index that is not usable, is left out. An elevation that
  ## is not a number is said and left out; the move is kept. A field this
  ## version does not know is skipped.
  var
    line, point, x, y: float64
    index: int16
    fromTime, elev: Option[float64]
    note = ""
    hasLine, hasPoint, hasX, hasY, badFrom, badIndex, badElev: bool
  for k in n.kids:
    if k.kind != nkTree: r.problem(k, "(move) holds trees")
    else:
      case k.tag
      of "line":
        if finiteNumber(k, line): hasLine = true
        else: r.problem(k, "(line) needs a number")
      of "point":
        if finiteNumber(k, point): hasPoint = true
        else: r.problem(k, "(point) needs a number")
      of "index":
        if k.kids.len == 1 and k.kids[0].kind == nkInt and
            k.kids[0].intVal >= low(int16).int64 and k.kids[0].intVal <= high(int16).int64:
          index = int16(k.kids[0].intVal)
        else:
          badIndex = true
          r.problem(k, "(index) needs a whole number from " & $low(int16) & " to " &
            $high(int16))
      of "fromTime":
        var t = 0.0
        if finiteNumber(k, t): fromTime = some(t)
        else:
          badFrom = true
          r.problem(k, "(fromTime) needs a time")
      of "x":
        if finiteNumber(k, x): hasX = true
        else: r.problem(k, "(x) needs a number")
      of "y":
        if finiteNumber(k, y): hasY = true
        else: r.problem(k, "(y) needs a number")
      of "elev":
        var z = 0.0
        if finiteNumber(k, z): elev = some(z)
        else:
          badElev = true
          r.problem(k, "(elev) needs a number; the move is kept without an elevation")
      of "note": r.text(k, note)
      else: discard
  if badFrom or badIndex or not hasLine or not hasPoint or not hasX or not hasY:
    r.problem(n, "a station move is left out")
  else:
    if badElev: elev = none(float64)
    moves.add StationMove(station: StationKey(line: line, point: point, index: index),
      fromTime: fromTime, x: x, y: y, elev: elev, note: note)

proc readMoves(r: var Reading; n: NifNode; moves: var StationMoves) =
  for c in n.kids:
    if c.isTree("move"): r.readMove(c, moves)
    else: r.problem(c, "(stationMoves) holds moves")

proc store(r: var Reading; n: NifNode; s: var StoreInfo) =
  for k in n.kids:
    if k.kind == nkTree:
      case k.tag
      of "format": r.count(k, s.format)
      of "bytes": r.integer(k, s.bytes)
      of "hash": r.hash(k, s.hash)
      of "sources": r.count(k, s.sources)
      of "receivers": r.count(k, s.receivers)
      of "relations": r.count(k, s.relations)
      else: discard

proc survey(r: var Reading; n: NifNode; d: var ProjectDoc) =
  for c in n.kids:
    if c.kind != nkTree: r.problem(c, "(survey) holds trees")
    else:
      case c.tag
      of "file": r.surveyFile(c, d)
      of "join": d.options = readJoinOptions(c, r.name, d.options, r.problems)
      of "units": r.units(c, d.units)
      of "notes":
        for v in c.kids:
          if v.kind == nkString: d.notes.add v.text
      of "imported": r.time(c, d.imported)
      of "store": r.store(c, d.store)
      else: discard

proc number(r: var Reading; n: NifNode; range: SettingRange; x: var float64) =
  ## `(tag v)`: `x` = v when it is a number `range` allows.
  if n.kids.len == 1 and n.kids[0].kind in {nkFloat, nkInt}:
    let v = if n.kids[0].kind == nkFloat: n.kids[0].floatVal
            else: float64(n.kids[0].intVal)
    if range.allows(v): x = v
    else: r.problem(n, "(" & n.tag & ") needs a number " & range.words)
  else: r.problem(n, "(" & n.tag & ") needs a number")

proc whole(r: var Reading; n: NifNode; lo, hi: int; x: var int) =
  if n.kids.len == 1 and n.kids[0].kind == nkInt and n.kids[0].intVal >= lo and
      n.kids[0].intVal <= hi:
    x = int(n.kids[0].intVal)
  else:
    r.problem(n, "(" & n.tag & ") needs a whole number from " & $lo & " to " & $hi)

proc accel(r: var Reading; n: NifNode; x: var AccelSet) =
  if n.kids.len == 1 and n.kids[0].kind == nkIdent:
    for v in AccelSet:
      if $v == n.kids[0].text:
        x = v
        return
  r.problem(n, "(accelSet) needs A or B")

proc limits(r: var Reading; n: NifNode; p: var VibQcProfile) =
  ## A limit written is on; one left out is off. A field not known is kept.
  p.limits = QcLimits(avgPhaseDeg: NaN, peakPhaseDeg: NaN, avgDistortionPct: NaN,
    peakDistortionPct: NaN, avgForcePct: NaN, peakForcePct: NaN)
  for l in n.kids:
    if l.kind != nkTree: r.problem(l, "(limits) holds trees")
    else:
      case l.tag
      of "avgPhaseDeg": r.number(l, NumberRange, p.limits.avgPhaseDeg)
      of "peakPhaseDeg": r.number(l, NumberRange, p.limits.peakPhaseDeg)
      of "avgDistortionPct": r.number(l, NumberRange, p.limits.avgDistortionPct)
      of "peakDistortionPct": r.number(l, NumberRange, p.limits.peakDistortionPct)
      of "avgForcePct": r.number(l, NumberRange, p.limits.avgForcePct)
      of "peakForcePct": r.number(l, NumberRange, p.limits.peakForcePct)
      else: p.later.add l

proc forceScale(r: var Reading; n: NifNode; p: var VibQcProfile) =
  for k in n.kids:
    if k.kind != nkTree: r.problem(k, "(forceScale) holds trees")
    else:
      case k.tag
      of "datCountsPerLbf": r.number(k, ForceScaleRange, p.forceScale.datCountsPerLbf)
      of "vibAccMvPerCount": r.number(k, ForceScaleRange, p.forceScale.vibAccMvPerCount)
      else: p.later.add k

proc vibProfile(r: var Reading; n: NifNode; d: var ProjectDoc) =
  ## One profile. A field this version does not know is kept and written back.
  d.hasVibProfile = true
  for c in n.kids:
    if c.kind != nkTree: r.problem(c, "(vibProfile) holds trees")
    else:
      case c.tag
      of "qcWindowMs": r.number(c, WindowMsRange, d.vibProfile.qcWindowMs)
      of "harmonics": r.whole(c, int(HarmonicRange.lo), int(HarmonicRange.hi),
          d.vibProfile.harmonics)
      of "accelSet": r.accel(c, d.vibProfile.accelSet)
      of "limits": r.limits(c, d.vibProfile)
      of "forceScale": r.forceScale(c, d.vibProfile)
      of "forceHundredPct": r.number(c, MassKgRange, d.vibProfile.forceHundredPct)
      of "targetPct": r.number(c, TargetPctRange, d.vibProfile.targetPct)
      of "referenceId": r.text(c, d.vibProfile.referenceId)
      of "topHz": r.number(c, TopHzRange, d.vibProfile.topHz)
      else: d.vibProfile.later.add c

proc vibWeights(r: var Reading; n: NifNode; d: var ProjectDoc) =
  ## The job's weights. A field this version does not know is kept and written back.
  for c in n.kids:
    if c.kind != nkTree: r.problem(c, "(vibWeights) holds trees")
    else:
      case c.tag
      of "holdDownKg": r.number(c, MassKgRange, d.vibJobWeights.holdDownKg)
      of "baseplateMassKg": r.number(c, MassKgRange, d.vibJobWeights.baseplateMassKg)
      of "reactionMassKg": r.number(c, MassKgRange, d.vibJobWeights.reactionMassKg)
      else: d.vibJobWeights.later.add c

proc readProject*(doc: openArray[NifNode]; name: string; problems: var seq[string]): ProjectDoc =
  ## The project document `doc` (`parseNif`; `name` names it in problems).
  ## Raises `NifError` when it is not a project document.
  var r = Reading(name: name)
  result = ProjectDoc(version: 0)
  var root = -1
  for i, n in doc:
    if n.kind == nkTree and n.tag.startsWith("."): discard
    elif root < 0 and n.isTree("project"): root = i
  if root < 0:
    var e = newException(NifError, name & " holds no (project ...)")
    e.line = (if doc.len > 0: doc[0].line else: 0)
    raise e
  for c in doc[root].kids:
    if c.kind != nkTree: r.problem(c, "(project) holds trees")
    else:
      case c.tag
      of "version":
        var v = 0'i64
        r.integer(c, v)
        result.version = int(clamp(v, 0, high(int32)))
      of "name": r.text(c, result.name)
      of "created": r.time(c, result.created)
      of "data": r.folders(c, result)
      of "survey": r.survey(c, result)
      of "importing": r.importFiles(c, result)
      of "processing":
        result.processing = readProcessing(c, name, Processing(), r.problems)
        result.hasProcessing = true
      of "displayPresets":
        result.displayPresets = readDisplayPresets(c, name, r.problems)
        result.hasPresets = true
      of "breakModel":
        result.breakModel = readBreakModel(c, name, BreakModel(), r.problems)
        result.hasBreakModel = true
      of "referenceId": r.text(c, result.referenceId)
      of "lastFolder": r.text(c, result.lastFolder)
      of "includeSubfolders": r.flag(c, result.includeSubfolders)
      of "vibRole":
        var text = ""
        r.text(c, text)
        if text.len > 0 and result.vibRoles.len < 256: result.vibRoles.add text
      of "vibTop":
        var text = ""
        r.text(c, text)
        if text.len > 0 and result.vibTops.len < 256: result.vibTops.add text
      of "vibProfile": r.vibProfile(c, result)
      of "vibWeights": r.vibWeights(c, result)
      of "stationMoves": r.readMoves(c, result.stationMoves)
      of "vendorMap":
        var name = ""
        r.text(c, name)
        result.vendorChoice = if name.len == 0: VendorChoice(mode: vmNone)
                              else: VendorChoice(mode: vmNamed, name: name)
      else: result.later.add c
  if result.version == 0:
    r.problem(doc[root], "(project) gives no (version); read as version " & $ProjectVersion)
    result.version = ProjectVersion
  elif result.version > ProjectVersion:
    r.problem(doc[root], "written by a newer viewSEG (project version " & $result.version &
      "; this one reads " & $ProjectVersion & "): it is opened read-only")
  problems.add r.problems

proc readProject*(text, name: string; problems: var seq[string]): ProjectDoc =
  ## `readProject` of the document in `text`; raises `NifError` when it is
  ## not NIF or not a project document.
  readProject(parseNif(text, name), name, problems)

# ------------------------------------------------------------------- owner --

proc ownerDocument*(o: Owner): string =
  var w = initNifWriter(breakDepth = 1)
  w.open "owner"
  w.value("host", o.host)
  w.value("user", o.user)
  w.value("process", int64(o.pid))
  w.value("since", timeText(o.since))
  w.close
  w.finish

proc readOwner*(text: string): Owner =
  ## What `owner.nif` says; empty fields for what it does not (it is a note).
  result = Owner()
  try:
    for n in parseNif(text, OwnerName):
      if n.isTree("owner"):
        var r = Reading(name: OwnerName)
        for k in n.kids:
          if k.isTree("host"): r.text(k, result.host)
          elif k.isTree("user"): r.text(k, result.user)
          elif k.isTree("process"):
            var v = 0'i64
            r.integer(k, v)
            result.pid = int(v)
          elif k.isTree("since"): r.time(k, result.since)
  except NifError:
    discard

proc words*(o: Owner): string =
  ## Who it is, in words: "viewSEG on ws12 (alice, process 4711) since 21:40".
  if o.host.len == 0 and o.user.len == 0: return "another viewSEG"
  result = "viewSEG on " & (if o.host.len > 0: o.host else: "another computer")
  var extra: seq[string] = @[]
  if o.user.len > 0: extra.add o.user
  if o.pid > 0: extra.add "process " & $o.pid
  if extra.len > 0: result.add " (" & extra.join(", ") & ")"
  if o.since != Time(): result.add " since " & o.since.utc.format("yyyy-MM-dd HH:mm") & " UTC"
