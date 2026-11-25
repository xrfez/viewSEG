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
##    (relations 1200) (receiverRelations 0)))
##  (processing (dc none) (band bandPass) (f1 4.0) ...)
##  (displayPresets (preset "Section" (mode density) ...))
##  (outputPatterns (pattern "Line" (separator "_") (part "srcLine" (pad 5))
##   (part "text" (text "abc"))))
##  (outputPattern "Line"))
## ```
##
## Reading is forgiving and says what it did: what is missing keeps its
## default, what cannot be used is said with its line, and what this
## version does not know is kept (`ProjectDoc.later`) and written back as it
## was. A document of a later version than `ProjectVersion` reads as far as
## it can; the program then opens the project read-only.
##
## A shot log imported into the project is
## `(shotLogs (log (name ...) (file ...) (map (delimiter comma) (header true)
## (clock UTC) (unit metres) (role "file number") ...)))`. `file` is a plain
## file name; the text is the copy under `shotlogs/`, not a node here. Absent
## means none. `(decimalComma true)` is written when a comma is the decimal
## point; absent reads as false. A field this version does not know is kept
## and written back.
## A role that is not one, a map with more than `MaxShotLogColumns` columns,
## or a file that is not a plain name is said and left out.
##
## The column map used last is `(lastShotMap (map ...) (headerName "...") ...)`.
## `map` is written and read as a stored log's map. One `headerName` sits beside
## it per column. Absent means none. A field this version does not know is kept
## and written back. A role that is not one, more columns or header names than
## a stored map keeps, or a header name that cannot be used is said and the
## node is left out.
##
## An output file's name is `(outputPatterns (pattern "Line" (separator "_")
## (part "srcLine" (pad 5)) (part "text" (text "abc"))))` and
## `(outputPattern "Line")`, the label in use. A separator is written only
## when it is not a dot; a width only when it is not 0; text only for a text
## part. A part's kind is a fixed word (`PartKindWords`), not `$kind`, so a
## rename does not change a file. Absent means today's naming. At most
## `MaxOutputPatterns` patterns, `MaxPatternParts` parts each; a label is at
## most `MaxPatternName` characters and a text part at most `MaxPatternText`
## bytes. An unknown part word, a label given twice (without regard to case),
## or a pattern `patternProblem` refuses is said and left out, naming the
## pattern when it has a label. A child of a pattern, or of a part, that this
## version does not know is kept and written back. An extra child of a width,
## a text, a separator or the chosen label is not written back, and does not
## drop the value that is there. A chosen label that names no pattern, or one
## that is too long, reads as none, and is said.
##
## A SEG-Y text header template is `(outputTexts (text "Survey" (encoding "ascii")
## (line "C 1 {stem}") (line "")))` and `(outputText "Survey")`, the name in
## use; absent means the writer's own text. `(encoding "ebcdic")`, the
## default, is not written. A `(line "...")` is one card, cards 1 to 38 in
## order, a blank one an empty string; tokens in braces stay as typed
## (`core/outputtext`). At most `MaxOutputTexts` templates. An encoding that
## is not `ebcdic` or `ascii`, a name given twice (without regard to case), or
## a template `textProblem` refuses is said and left out. A child this
## version does not know is kept and written back; so is one of
## `(outputTexts)`. A chosen name that names no template reads as none, and
## is said.
##
## A SEG-Y binary file header set is `(outputBinaries (binary "Survey" (field
## "jobId" "7") (field "sweepLength" "10000")))` and `(outputBinary "Survey")`,
## the name in use; absent means no binary header value is set. A `(field
## "name" "value")` is one field of the library's binary header, its value
## a number as typed (`core/outputbinary`). At most `MaxOutputBinaries` sets.
## A set given twice (without regard to case) or one `binaryProblem` refuses
## is said and left out, the rest kept. A child this version does not know is
## kept and written back; so is one of `(outputBinaries)`. A chosen name that
## names no set reads as none, and is said.
##
## The auxiliary traces marked for correlation in every file of the project are
## `(auxMarks (aux 1 (ms 500.0)) (aux 3 (ms 0.0)))`: the position counts from 1 among a
## record's auxiliary traces, `ms` is the shift applied before correlating, positive
## later. A position given twice (the first counts), one outside what a mark may name, or a
## shift that is not a finite number a mark may hold is said and left out. A child this
## version does not know is kept and written back. Absent means no position is marked.
##
## A station moved during a deployment is
## `(stationMoves (move (line ...) (point ...) (index ...) (x ...) (y ...)))`.
## `fromTime` (the same absolute time as `TraceKeys.time`) and `elev` are
## written when given; a move with no `fromTime` holds for every trace of
## the station. Absent means no moves. The position is not written into the
## seismic file or the survey file.

import std/[algorithm, math, options, sequtils, strutils, times, unicode]
import parseSEG
import analysis, breakmodel, edits, identity, join, nif, outputbinary, outputnames, outputtext,
    processing, project, settings,
  settingsnif, shotlog, stationmoves, vendormaps, vibprofile

const
  KindNames: array[JoinFileKind, string] = ["sps", "p1", "csv"]
  RoleNames: array[CsvRole, string] = ["column", "sources", "receivers"]
  UnitNames: array[SurveyUnit, string] = ["notGiven", "metres", "feet", "usFeet", "degrees",
    "arcSeconds", "dms"]
  DelimNames: array[Delimiter, string] = ["comma", "tab", "semicolon", "spaces"]
  ClockNames: array[TimeClock, string] = ["UTC", "GPS"]
  LengthNames: array[shotlog.LengthUnit, string] = ["metres", "feet"]
  MaxPatternText = 120 ## a text part, in bytes
  MaxVendorName = 200  ## a vendor field part's name, in bytes
  PartLaterTag = " "
    ## Marks unknown children of a part, kept in that pattern's later list
    ## and written back inside the part. Not a tag a document can hold.
  # A part kind's word in a file. Not `$kind`: renaming the enum must not
  # change a project.
  PartKindWords: array[NamePartKind, string] = [
    "stem", "text", "record", "srcLine", "srcPoint", "srcIndex", "rcvLine",
    "rcvPoint", "rcvIndex", "time", "systemSerial", "controller", "vibrator",
    "fileNumber", "sigLine", "sigStation", "shotId", "sweepId",
    "sensorSerial", "vendor"]

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
  if p.forceHundredUnit.len > 0: w.value("forceHundredUnit", p.forceHundredUnit)
  if p.forceHundredSetKnown: w.choice("forceHundredSet", $p.forceHundredSet)
  if finite(p.targetPct): w.value("targetPct", p.targetPct)
  if p.referenceId.len > 0: w.value("referenceId", p.referenceId)
  if finite(p.topHz): w.value("topHz", p.topHz)
  if p.fromFile.len > 0: w.value("fromFile", p.fromFile)
  for n in p.later: w.add n
  w.close

proc writeShotMap(w: var NifWriter; s: StoredShotLog) =
  ## How to read the log. `decimalComma` is written only when true; absent
  ## reads as false. A field this version does not know is written back.
  w.open "map"
  w.choice("delimiter", $s.map.delimiter)
  if s.map.skipLines != 0: w.value("skipLines", int64(s.map.skipLines))
  w.value("header", s.map.hasHeader)
  if s.map.decimalComma: w.value("decimalComma", true)
  w.choice("clock", $s.map.clock)
  w.choice("unit", $s.map.lengthUnit)
  if s.map.dateTimePattern.len > 0: w.value("pattern", s.map.dateTimePattern)
  for t in s.map.sentinels: w.value("sentinel", t)
  for role in s.map.roles: w.value("role", $role)
  for n in s.mapLater: w.add n
  w.close

proc writeLastShotMap(w: var NifWriter; remembered: LastShotMap) =
  ## The column map used last, written as a stored log's map, with one header
  ## name beside it per column. A field this version does not know is written
  ## back.
  w.open "lastShotMap"
  var stored = StoredShotLog(map: remembered.map, mapLater: remembered.mapLater)
  w.writeShotMap stored
  for name in remembered.headers: w.value("headerName", name)
  for n in remembered.later: w.add n
  w.close

proc writeShotLog(w: var NifWriter; s: StoredShotLog) =
  ## One stored shot log: its name, the copy's file name, and its map.
  w.open "log"
  w.value("name", s.name)
  w.value("file", s.file)
  w.writeShotMap s
  for n in s.later: w.add n
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

proc writeNamePart(w: var NifWriter; part: NamePart; index: int; later: openArray[NifNode]) =
  w.open "part"
  w.add PartKindWords[part.kind]
  if part.pad != 0: w.value("pad", int64(part.pad))
  if part.kind in {npText, npVendor}: w.value("text", part.text)
  for n in later:
    if n.kind == nkTree and n.tag == PartLaterTag and n.kids.len >= 1 and
        n.kids[0].kind == nkInt and n.kids[0].intVal == int64(index):
      for j in 1 ..< n.kids.len: w.add n.kids[j]
  w.close

proc writeOutputPattern(w: var NifWriter; p: OutputPattern; later: openArray[NifNode]) =
  w.open "pattern"
  w.add p.name
  if p.separator != nsDot: w.value("separator", $p.separator)
  for i, part in p.parts: w.writeNamePart(part, i, later)
  for n in later:
    if n.kind != nkTree or n.tag != PartLaterTag: w.add n
  w.close

proc writeOutputPatterns(w: var NifWriter; d: ProjectDoc) =
  ## Name patterns in an `(outputPatterns ...)` tree. A separator is written
  ## only when it is not a dot, a width only when it is not 0, and text only
  ## for a text part. A child of a pattern, or of a part, that this version
  ## does not know is written back.
  w.open "outputPatterns"
  var none: seq[NifNode] = @[]
  for i, p in d.outputPatterns:
    if i < d.outputPatternLater.len: w.writeOutputPattern(p, d.outputPatternLater[i])
    else: w.writeOutputPattern(p, none)
  for n in d.outputPatternsLater: w.add n
  w.close

proc writeOutputText(w: var NifWriter; t: OutputText; later: openArray[NifNode]) =
  w.open "text"
  w.add t.name
  if t.encoding != teEbcdic: w.value("encoding", $t.encoding)
  for line in t.lines: w.value("line", line)
  for n in later: w.add n
  w.close

proc writeOutputBinary(w: var NifWriter; b: OutputBinary; later: openArray[NifNode]) =
  w.open "binary"
  w.add b.name
  for e in b.entries:
    w.open "field"
    w.add e.field
    w.add e.value
    w.close
  for n in later: w.add n
  w.close

proc writeOutputBinaries(w: var NifWriter; d: ProjectDoc) =
  ## Binary header sets in an `(outputBinaries ...)` tree. A child this
  ## version does not know is written back.
  w.open "outputBinaries"
  var none: seq[NifNode] = @[]
  for i, b in d.outputBinaries:
    if i < d.outputBinaryLater.len: w.writeOutputBinary(b, d.outputBinaryLater[i])
    else: w.writeOutputBinary(b, none)
  for n in d.outputBinariesLater: w.add n
  w.close

proc writeOutputTexts(w: var NifWriter; d: ProjectDoc) =
  ## Text header templates in an `(outputTexts ...)` tree; an encoding only
  ## when it is not EBCDIC. A child this version does not know is written back.
  w.open "outputTexts"
  var none: seq[NifNode] = @[]
  for i, t in d.outputTexts:
    if i < d.outputTextLater.len: w.writeOutputText(t, d.outputTextLater[i])
    else: w.writeOutputText(t, none)
  for n in d.outputTextsLater: w.add n
  w.close

proc writeAuxMarks(w: var NifWriter; d: ProjectDoc) =
  w.open "auxMarks"
  for e in d.auxMarks:
    w.open "aux"
    w.add int64(e.position)
    w.value("ms", e.ms)
    w.close
  for n in d.auxMarksLater: w.add n
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
      w.value("receiverRelations", int64(d.store.receiverRelations))
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
  if d.hasOutputPatterns: w.writeOutputPatterns(d)
  if d.outputPattern.len > 0: w.value("outputPattern", d.outputPattern)
  if d.hasOutputTexts: w.writeOutputTexts(d)
  if d.outputText.len > 0: w.value("outputText", d.outputText)
  if d.hasOutputBinaries: w.writeOutputBinaries(d)
  if d.outputBinary.len > 0: w.value("outputBinary", d.outputBinary)
  if d.auxMarks.len > 0 or d.auxMarksLater.len > 0: w.writeAuxMarks(d)
  if d.hasBreakModel: w.writeBreakModel(d.breakModel)
  if d.shotLogs.len > 0 or d.shotLogsLater.len > 0:
    w.open "shotLogs"
    for s in d.shotLogs: w.writeShotLog s
    for n in d.shotLogsLater: w.add n
    w.close
  if d.lastShotMap.isSome: w.writeLastShotMap(d.lastShotMap.get)
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

func finiteValue(x: float64): bool {.inline.} =
  x == x and x != Inf and x != -Inf

proc finiteNumber(n: NifNode; x: var float64): bool =
  ## Whether `n` is `(tag v)` with `v` a finite number.
  if n.kids.len != 1: return false
  case n.kids[0].kind
  of nkFloat: x = n.kids[0].floatVal
  of nkInt: x = float64(n.kids[0].intVal)
  else: return false
  finiteValue(x)

proc readMove(r: var Reading; n: NifNode; moves: var StationMoves) =
  ## One `(move ...)`. A move without a line, a point, an x or a y, or with a
  ## `fromTime` or an index that is not usable, or whose line or point
  ## `stationKey` cannot store, is left out. An elevation that is not a
  ## number is said and left out; the move is kept. A field this version
  ## does not know is skipped.
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
    let key = stationKey(line, point, index)
    if not finiteValue(key.line) or not finiteValue(key.point):
      r.problem(n, "a station's line or point cannot be stored; the move is left out")
    else:
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
      of "receiverRelations":
        r.count(k, s.receiverRelations)
        s.splitKnown = true
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

proc accel(r: var Reading; n: NifNode; x: var AccelSet): bool =
  ## Sets `x` when `n` names A or B. A bad value is a problem and `x` is left.
  if n.kids.len == 1 and n.kids[0].kind == nkIdent:
    for v in AccelSet:
      if $v == n.kids[0].text:
        x = v
        return true
  r.problem(n, "(" & n.tag & ") needs A or B")

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
      of "accelSet": discard r.accel(c, d.vibProfile.accelSet)
      of "limits": r.limits(c, d.vibProfile)
      of "forceScale": r.forceScale(c, d.vibProfile)
      of "forceHundredPct": r.number(c, MassKgRange, d.vibProfile.forceHundredPct)
      of "forceHundredUnit": r.text(c, d.vibProfile.forceHundredUnit)
      of "forceHundredSet":
        if r.accel(c, d.vibProfile.forceHundredSet):
          d.vibProfile.forceHundredSetKnown = true
      of "targetPct": r.number(c, TargetPctRange, d.vibProfile.targetPct)
      of "referenceId": r.text(c, d.vibProfile.referenceId)
      of "topHz": r.number(c, TopHzRange, d.vibProfile.topHz)
      of "fromFile": r.text(c, d.vibProfile.fromFile)
      else: d.vibProfile.later.add c

proc columnRole(name: string): tuple[ok: bool; role: ColumnRole] =
  for role in ColumnRole:
    if $role == name: return (true, role)
  (false, crText)

proc readShotMap(r: var Reading; n: NifNode; s: var StoredShotLog; bad, tooMany: var bool;
    leftOut: string) =
  ## `leftOut` is the clause after a bad role: a stored log is left out, or
  ## the remembered column map is.
  var roles = 0
  for c in n.kids:
    if c.kind != nkTree:
      r.problem(c, "(map) holds trees")
      continue
    case c.tag
    of "delimiter": r.choice(c, DelimNames, s.map.delimiter)
    of "skipLines":
      var v = 0
      r.count(c, v)
      if v > MaxShotLogSkip:
        r.problem(c, "(skipLines) is too large; it is left out")
      else: s.map.skipLines = v
    of "header": r.flag(c, s.map.hasHeader)
    of "decimalComma": r.flag(c, s.map.decimalComma)
    of "clock": r.choice(c, ClockNames, s.map.clock)
    of "unit": r.choice(c, LengthNames, s.map.lengthUnit)
    of "pattern": r.text(c, s.map.dateTimePattern)
    of "sentinel":
      if s.map.sentinels.len >= MaxShotLogSentinels:
        r.problem(c, "a shot log keeps at most " & $MaxShotLogSentinels &
          " sentinels; the rest are left out")
      else:
        var t = ""
        r.text(c, t)
        if t.len > 0: s.map.sentinels.add t
    of "role":
      inc roles
      if roles > MaxShotLogColumns:
        tooMany = true
      elif c.kids.len != 1 or c.kids[0].kind notin {nkString, nkIdent}:
        r.problem(c, "(role) needs a role name; " & leftOut)
        bad = true
      else:
        let found = columnRole(c.kids[0].text)
        if not found.ok:
          r.problem(c, "\"" & c.kids[0].text & "\" is not a column role; " & leftOut)
          bad = true
        elif not bad and not tooMany: s.map.roles.add found.role
    else: s.mapLater.add c

proc shotLog(r: var Reading; n: NifNode; d: var ProjectDoc) =
  ## One log. A role that is not one, too many columns, or a file that is
  ## not a plain name: said, and the log is left out.
  if d.shotLogs.len >= MaxShotLogs:
    r.problem(n, "a project keeps at most " & $MaxShotLogs & " shot logs; this one is left out")
    return
  var s = StoredShotLog()
  var bad = false
  var tooMany = false
  for k in n.kids:
    if k.kind != nkTree:
      r.problem(k, "(log) holds trees")
      continue
    case k.tag
    of "name": r.text(k, s.name)
    of "file": r.text(k, s.file)
    of "map": r.readShotMap(k, s, bad, tooMany, "the log is left out")
    else: s.later.add k
  if tooMany:
    r.problem(n, "a shot log keeps at most " & $MaxShotLogColumns &
      " columns; this one is left out")
    return
  if bad: return
  if s.name.len == 0 or s.name.len > MaxShotLogName:
    r.problem(n, "a shot log's name cannot be used; it is left out")
    return
  if not s.file.isShotLogFile:
    r.problem(n, "a shot log's file is not a file in shotlogs; it is left out")
    return
  d.shotLogs.add s

proc lastShotMap(r: var Reading; n: NifNode; d: var ProjectDoc) =
  ## The column map used last. A role that is not one, too many columns, or a
  ## header name that cannot be used: said, and the node is left out.
  var s = StoredShotLog()
  var bad, tooMany, headerBad, sawMap = false
  var headers: seq[string] = @[]
  var later: seq[NifNode] = @[]
  for k in n.kids:
    if k.kind != nkTree:
      r.problem(k, "(lastShotMap) holds trees")
      continue
    case k.tag
    of "map":
      if sawMap: later.add k
      else:
        sawMap = true
        r.readShotMap(k, s, bad, tooMany, "the remembered column map is left out")
    of "headerName":
      if headers.len >= MaxShotLogColumns:
        r.problem(k, "a remembered column map keeps at most " & $MaxShotLogColumns &
          " header names; it is left out")
        headerBad = true
      elif k.kids.len != 1 or k.kids[0].kind != nkString:
        r.problem(k, "(headerName) needs a string; the remembered map is left out")
        headerBad = true
      elif k.kids[0].text.len > MaxShotLogName:
        r.problem(k, "a header name is longer than a shot log's name; " &
          "the remembered map is left out")
        headerBad = true
      else: headers.add k.kids[0].text
    else: later.add k
  if not sawMap:
    r.problem(n, "a remembered column map has no map; it is left out")
    return
  if tooMany:
    r.problem(n, "a remembered column map keeps at most " & $MaxShotLogColumns &
      " columns; it is left out")
    return
  if bad or headerBad: return
  d.lastShotMap = some(LastShotMap(map: s.map, headers: headers,
    mapLater: s.mapLater, later: later))

proc shotLogs(r: var Reading; n: NifNode; d: var ProjectDoc) =
  for c in n.kids:
    if c.isTree("log"): r.shotLog(c, d)
    elif c.kind == nkTree: d.shotLogsLater.add c
    else: r.problem(c, "(shotLogs) holds logs")

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

type PatternRead = object
  ok: bool
  pattern: OutputPattern
  later: seq[NifNode]
  why: string

func partKindOf(word: string): Option[NamePartKind] =
  for kind, name in PartKindWords:
    if name == word: return some(kind)

func separatorOf(word: string): Option[NameSeparator] =
  for sep in NameSeparator:
    if $sep == word: return some(sep)

func sameLabel(a, b: string): bool = cmpRunesIgnoreCase(a, b) == 0

func leftOut(why, label: string): string =
  ## `why`, naming `label` when there is one. `patternProblem` states the rule
  ## for a control character ("holds no"); said here as the label having one.
  var body = why
  if body == "A name pattern's name holds no control characters.":
    body = "the label has a control character"
  if label.len > 0:
    if body.len == 0: body = "a name pattern cannot be used"
    if body.startsWith("A name pattern"): body[0] = 'a'
    body = "the name pattern \"" & label & "\": " & body
  if body.len == 0: "a name pattern cannot be used; it is left out"
  elif body[^1] == '.' and body.len > 1: body[0 .. ^2] & "; it is left out."
  elif body[^1] == '.': "it is left out."
  else: body & "; it is left out"

func chosenTooLong(label: string): string =
  ## `label` is too long to choose. Quotes its first 20 characters.
  let head = if validateUtf8(label) < 0: label.runeSubStr(0, 20)
             else: label[0 ..< min(20, label.len)]
  "the chosen name pattern \"" & head & "\" is too long; today's naming is used"

proc takeSeparator(k: NifNode; read: var PatternRead): bool =
  if k.kids.len >= 1 and k.kids[0].kind in {nkString, nkIdent}:
    let found = separatorOf(k.kids[0].text)
    if found.isSome:
      read.pattern.separator = found.get
      return true
  read.why = "a name pattern's separator is \".\", \"_\" or \"-\""
  false

proc markPartLater(index: int; kids: seq[NifNode]): NifNode =
  ## Unknown children of part `index`, kept in the pattern's later list and
  ## written back inside the part.
  result = NifNode(kind: nkTree, tag: PartLaterTag)
  result.kids = @[NifNode(kind: nkInt, intVal: int64(index))]
  result.kids.add kids

proc takePart(k: NifNode; read: var PatternRead): bool =
  if k.kids.len == 0 or k.kids[0].kind notin {nkString, nkIdent}:
    read.why = "a name part needs a kind"
    return false
  let word = k.kids[0].text
  let found = partKindOf(word)
  if found.isNone:
    if word.len > 64: read.why = "a part kind is not one"
    else: read.why = "\"" & word & "\" is not a name part"
    return false
  var part = NamePart(kind: found.get)
  var partLater: seq[NifNode] = @[]
  for j in 1 ..< k.kids.len:
    let c = k.kids[j]
    if c.isTree("pad"):
      if c.kids.len >= 1 and c.kids[0].kind == nkInt and
          c.kids[0].intVal >= int64(low(int)) and c.kids[0].intVal <= int64(high(int)):
        part.pad = int(c.kids[0].intVal)
      else:
        read.why = "(pad) needs a whole number"
        return false
    elif c.isTree("text"):
      if part.kind notin {npText, npVendor}:
        read.why = "only a text part or a vendor field part has text"
        return false
      if c.kids.len == 0 or c.kids[0].kind != nkString:
        read.why = "(text) needs a string"
        return false
      if c.kids[0].text.len > (if part.kind == npVendor: MaxVendorName else: MaxPatternText):
        read.why = "a name pattern's text is at most " &
          $(if part.kind == npVendor: MaxVendorName else: MaxPatternText) & " bytes"
        return false
      part.text = c.kids[0].text
    else:
      partLater.add c
  if partLater.len > 0: read.later.add markPartLater(read.pattern.parts.len, partLater)
  read.pattern.parts.add part
  true

proc readPattern(n: NifNode): PatternRead =
  ## One `(pattern "label" ...)`. `ok` is false, and `why` says why, when it
  ## cannot be kept. A child this version does not know is in `later`, as are
  ## unknown children of a part, which are written back inside the part.
  result.pattern = OutputPattern(separator: nsDot, parts: @[])
  result.later = @[]
  if n.kids.len == 0 or n.kids[0].kind != nkString:
    result.why = "A name pattern needs a name."
    return
  let raw = n.kids[0].text
  if raw.len > MaxPatternName * 4 + 64:
    result.why = "A name pattern's name is at most " & $MaxPatternName & " characters long."
    return
  let name = strip(raw)
  if name.len == 0:
    result.why = "A name pattern needs a name."
    return
  result.pattern.name = name
  if name.runeLen > MaxPatternName:
    result.why = "A name pattern's name is at most " & $MaxPatternName & " characters long."
    return
  var nparts = 0
  for i in 1 ..< n.kids.len:
    let k = n.kids[i]
    if k.isTree("separator"):
      if not takeSeparator(k, result): return
    elif k.isTree("part"):
      inc nparts
      if nparts > MaxPatternParts:
        result.why = "A name pattern has at most " & $MaxPatternParts & " parts."
        return
      if not takePart(k, result): return
    else:
      result.later.add k
  let why = patternProblem(result.pattern)
  if why.len > 0:
    result.why = why
    return
  result.ok = true

proc labelTaken(patterns: openArray[OutputPattern]; name: string): bool =
  for p in patterns:
    if sameLabel(p.name, name): return true

proc outputPatterns(r: var Reading; n: NifNode; d: var ProjectDoc) =
  ## `(outputPatterns (pattern "label" (part "srcLine") ...) ...)`. A pattern
  ## that is not one, or whose label is taken, is left out and said, as are
  ## those past `MaxOutputPatterns`. A child this version does not know is kept.
  d.hasOutputPatterns = true
  var got: seq[OutputPattern] = @[]
  var later: seq[seq[NifNode]] = @[]
  var rest: seq[NifNode] = @[]
  var over = 0
  for c in n.kids:
    if c.isTree("pattern"):
      if got.len >= MaxOutputPatterns: inc over
      else:
        let read = readPattern(c)
        if not read.ok: r.problem(c, leftOut(read.why, read.pattern.name))
        elif labelTaken(got, read.pattern.name):
          r.problem(c, "the name pattern \"" & read.pattern.name &
            "\" is given twice; the first counts.")
        else:
          got.add read.pattern
          later.add read.later
    elif c.kind == nkTree: rest.add c
    else: r.problem(c, "(outputPatterns) holds patterns")
  if over > 0:
    r.problem(n, "At most " & $MaxOutputPatterns & " name patterns are kept; the " &
      $over & " after the first " & $MaxOutputPatterns & " are left out.")
  d.outputPatterns = got
  d.outputPatternLater = later
  d.outputPatternsLater = rest

type TextRead = object
  ok: bool
  text: OutputText
  later: seq[NifNode]
  why: string

func textLeftOut(why, name: string): string =
  ## `why`, naming the template `name` when there is one, and saying it is left out.
  var body = why
  if name.len > 0:
    body = "the output text \"" & name & "\": " & body
  if body.endsWith('.'): body.setLen(body.len - 1)
  body & "; it is left out."

proc readText(n: NifNode): TextRead =
  ## One `(text "name" (encoding ...) (line "...") ...)`. `ok` is false, and
  ## `why` says why, when it cannot be kept.
  result.later = @[]
  result.text = OutputText(encoding: teEbcdic, lines: @[])
  if n.kids.len == 0 or n.kids[0].kind != nkString:
    result.why = "An output text needs a name."
    return
  let raw = n.kids[0].text
  if raw.len > MaxTextName * 4 + 64:
    result.why = "An output text's name is at most " & $MaxTextName & " characters long."
    return
  result.text.name = strip(raw)
  for i in 1 ..< n.kids.len:
    let k = n.kids[i]
    if k.isTree("encoding"):
      if k.kids.len >= 1 and k.kids[0].kind == nkString and k.kids[0].text == "ascii":
        result.text.encoding = teAscii
      elif k.kids.len >= 1 and k.kids[0].kind == nkString and k.kids[0].text == "ebcdic":
        result.text.encoding = teEbcdic
      else:
        let got = if k.kids.len >= 1 and k.kids[0].kind == nkString: k.kids[0].text else: ""
        result.why = "The encoding \"" & got & "\" of an output text is not \"ebcdic\" or \"ascii\"."
        return
    elif k.isTree("line"):
      if k.kids.len < 1 or k.kids[0].kind != nkString:
        result.why = "A (line) of an output text needs a string."
        return
      if result.text.lines.len >= MaxTextLines:
        result.why = "An output text has at most " & $MaxTextLines & " lines."
        return
      result.text.lines.add k.kids[0].text
    else:
      result.later.add k
  let why = textProblem(result.text)
  if why.len > 0:
    result.why = why
    return
  result.ok = true

proc outputTexts(r: var Reading; n: NifNode; d: var ProjectDoc) =
  ## `(outputTexts (text "name" (line "...") ...) ...)`. A template that is
  ## not one, or whose name is taken, is left out and said, as are those past
  ## `MaxOutputTexts`. A child this version does not know is kept.
  d.hasOutputTexts = true
  var got: seq[OutputText] = @[]
  var later: seq[seq[NifNode]] = @[]
  var rest: seq[NifNode] = @[]
  var over = 0
  for c in n.kids:
    if c.isTree("text"):
      if got.len >= MaxOutputTexts: inc over
      else:
        let read = readText(c)
        if not read.ok: r.problem(c, textLeftOut(read.why, read.text.name))
        elif got.anyIt(sameLabel(it.name, read.text.name)):
          r.problem(c, "the output text \"" & read.text.name &
            "\" is given twice; the first counts.")
        else:
          got.add read.text
          later.add read.later
    elif c.kind == nkTree: rest.add c
    else: r.problem(c, "(outputTexts) holds texts")
  if over > 0:
    r.problem(n, "At most " & $MaxOutputTexts & " output texts are kept; the " &
      $over & " after the first " & $MaxOutputTexts & " are left out.")
  d.outputTexts = got
  d.outputTextLater = later
  d.outputTextsLater = rest

type BinaryRead = object
  ok: bool
  set: OutputBinary
  later: seq[NifNode]
  why: string

func binaryLeftOut(why, name: string): string =
  ## `why`, naming the set `name` when there is one, and saying it is left out.
  var body = why
  if name.len > 0:
    body = "the binary header set \"" & name & "\": " & body
  if body.endsWith('.'): body.setLen(body.len - 1)
  body & "; it is left out."

proc readBinary(n: NifNode): BinaryRead =
  ## One `(binary "name" (field "name" "value") ...)`. `ok` is false, and
  ## `why` says why, when it cannot be kept.
  result.later = @[]
  result.set = OutputBinary(entries: @[])
  if n.kids.len == 0 or n.kids[0].kind != nkString:
    result.why = "A binary header set needs a name."
    return
  let raw = n.kids[0].text
  if raw.len > MaxBinaryName * 4 + 64:
    result.why = "A binary header set's name is at most " & $MaxBinaryName &
      " characters long."
    return
  result.set.name = strip(raw)
  for i in 1 ..< n.kids.len:
    let k = n.kids[i]
    if k.isTree("field"):
      if k.kids.len != 2 or k.kids[0].kind != nkString or k.kids[1].kind != nkString:
        result.why = "A (field) of a binary header set is a name and a value, both strings, and nothing else."
        return
      if result.set.entries.len >= BinaryFields.len:
        result.why = "A binary header set has at most " & $BinaryFields.len & " fields."
        return
      result.set.entries.add BinaryEntry(field: k.kids[0].text, value: k.kids[1].text)
    else:
      result.later.add k
  let why = binaryProblem(result.set)
  if why.len > 0:
    result.why = why
    return
  result.ok = true

proc outputBinaries(r: var Reading; n: NifNode; d: var ProjectDoc) =
  ## `(outputBinaries (binary "name" (field "name" "value") ...) ...)`. A set
  ## that is not one, or whose name is taken, is left out and said, as are
  ## those past `MaxOutputBinaries`. A child this version does not know is kept.
  d.hasOutputBinaries = true
  var got: seq[OutputBinary] = @[]
  var later: seq[seq[NifNode]] = @[]
  var rest: seq[NifNode] = @[]
  var over = 0
  for c in n.kids:
    if c.isTree("binary"):
      if got.len >= MaxOutputBinaries: inc over
      else:
        let read = readBinary(c)
        if not read.ok: r.problem(c, binaryLeftOut(read.why, read.set.name))
        elif got.anyIt(sameLabel(it.name, read.set.name)):
          r.problem(c, "the binary header set \"" & read.set.name &
            "\" is given twice; the first counts.")
        else:
          got.add read.set
          later.add read.later
    elif c.kind == nkTree: rest.add c
    else: r.problem(c, "(outputBinaries) holds sets")
  if over > 0:
    r.problem(n, "At most " & $MaxOutputBinaries & " binary header sets are kept; the " &
      $over & " after the first " & $MaxOutputBinaries & " are left out.")
  d.outputBinaries = got
  d.outputBinaryLater = later
  d.outputBinariesLater = rest

proc auxMarks(r: var Reading; n: NifNode; d: var ProjectDoc) =
  ## `(auxMarks (aux N (ms X)) ...)`. An entry that is not one, whose position is given
  ## twice, or whose shift cannot be kept is left out and said. A child this version does
  ## not know is kept.
  d.auxMarks = @[]
  d.auxMarksLater = @[]
  for c in n.kids:
    if c.isTree("aux"):
      var position = 0
      var ms = NaN
      if c.kids.len >= 1 and c.kids[0].kind == nkInt:
        position = int(clamp(c.kids[0].intVal, 0, high(int32)))
      for k in c.kids:
        if k.isTree("ms") and k.kids.len == 1 and k.kids[0].kind in {nkFloat, nkInt}:
          ms = if k.kids[0].kind == nkFloat: k.kids[0].floatVal
               else: float64(k.kids[0].intVal)
      if not auxPositionStorable(position):
        r.problem(c, "(aux) needs a position from 1 to " & $MaxAuxPosition)
      elif not shiftStorable(ms):
        r.problem(c, "(aux " & $position & ") needs a shift in ms that can be kept")
      elif d.auxMarks.anyIt(it.position == position):
        r.problem(c, "auxiliary trace " & $position & " is marked twice; the first counts.")
      else:
        d.auxMarks.add AuxMarkEntry(position: position, marked: true, ms: ms)
    elif c.kind == nkTree: d.auxMarksLater.add c
    else: r.problem(c, "(auxMarks) holds entries")
  d.auxMarks.sort(proc (a, b: AuxMarkEntry): int = cmp(a.position, b.position))

proc settleBinaryChoice(r: var Reading; d: var ProjectDoc; choice: NifNode; saw: bool) =
  ## A chosen name that names no kept set reads as none, with a sentence.
  if not saw: return
  let label = strip(d.outputBinary)
  d.outputBinary = ""
  if label.len == 0: return
  for b in d.outputBinaries:
    if sameLabel(b.name, label):
      d.outputBinary = b.name
      return
  r.problem(choice, "the binary header set \"" & label &
    "\" is not in this project; no binary header value is set")

proc settleTextChoice(r: var Reading; d: var ProjectDoc; choice: NifNode; saw: bool) =
  ## A chosen name that names no kept template reads as none, with a sentence.
  if not saw: return
  let label = strip(d.outputText)
  d.outputText = ""
  if label.len == 0: return
  for t in d.outputTexts:
    if sameLabel(t.name, label):
      d.outputText = t.name
      return
  r.problem(choice, "the output text \"" & label &
    "\" is not in this project; the writer's own text is used")

proc settleChoice(r: var Reading; d: var ProjectDoc; choice: NifNode; saw: bool) =
  ## A chosen label that names no kept pattern reads as none, with a sentence.
  ## One that is too long is said, quoting its first 20 characters.
  if not saw: return
  let label = strip(d.outputPattern)
  d.outputPattern = ""
  if label.len == 0: return
  if label.runeLen > MaxPatternName:
    r.problem(choice, chosenTooLong(label))
    return
  for p in d.outputPatterns:
    if sameLabel(p.name, label):
      d.outputPattern = p.name
      return
  r.problem(choice, "the name pattern \"" & label &
    "\" is not in this project; today's naming is used")

proc readProject*(doc: openArray[NifNode]; name: string; problems: var seq[string]): ProjectDoc =
  ## The project document `doc` (`parseNif`; `name` names it in problems).
  ## Raises `NifError` when it is not a project document.
  var r = Reading(name: name)
  result = ProjectDoc(version: 0)
  var choiceNode = NifNode(kind: nkTree, tag: "outputPattern")
  var sawChoice = false
  var textChoiceNode = NifNode(kind: nkTree, tag: "outputText")
  var sawTextChoice = false
  var binaryChoiceNode = NifNode(kind: nkTree, tag: "outputBinary")
  var sawBinaryChoice = false
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
      of "outputPatterns": r.outputPatterns(c, result)
      of "outputPattern":
        # The string is the choice. An extra child does not clear it, and is
        # not kept. A string past the cap is not copied in.
        if c.kids.len >= 1 and c.kids[0].kind == nkString and
            c.kids[0].text.len <= MaxPatternName * 4 + 64:
          result.outputPattern = c.kids[0].text
          choiceNode = c
          sawChoice = true
        elif c.kids.len >= 1 and c.kids[0].kind == nkString:
          r.problem(c, chosenTooLong(c.kids[0].text))
        else:
          r.problem(c, "(outputPattern) needs a string")
      of "outputTexts": r.outputTexts(c, result)
      of "outputText":
        if c.kids.len >= 1 and c.kids[0].kind == nkString and
            c.kids[0].text.len <= MaxTextName * 4 + 64:
          result.outputText = c.kids[0].text
          textChoiceNode = c
          sawTextChoice = true
        else:
          r.problem(c, "(outputText) needs a name that is not too long")
      of "outputBinaries": r.outputBinaries(c, result)
      of "auxMarks": r.auxMarks(c, result)
      of "outputBinary":
        if c.kids.len >= 1 and c.kids[0].kind == nkString and
            c.kids[0].text.len <= MaxBinaryName * 4 + 64:
          result.outputBinary = c.kids[0].text
          binaryChoiceNode = c
          sawBinaryChoice = true
        else:
          r.problem(c, "(outputBinary) needs a name that is not too long")
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
      of "shotLogs": r.shotLogs(c, result)
      of "lastShotMap": r.lastShotMap(c, result)
      else: result.later.add c
  r.settleChoice(result, choiceNode, sawChoice)
  r.settleTextChoice(result, textChoiceNode, sawTextChoice)
  r.settleBinaryChoice(result, binaryChoiceNode, sawBinaryChoice)
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
