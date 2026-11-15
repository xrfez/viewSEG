## The project document (`project.nif`) and the note of who has a project
## open (`owner.nif`), as NIF text a person can read:
##
## ```
## (.nif27)
## (.vendor "viewSEG")
## (project
##  (version 1)
##  (name "Morgantown 2026")
##  (created "2026-11-15T21:40:00Z")
##  (data (folder (path "../field/day1") (absolute "/mnt/field/day1")))
##  (survey
##   (file (kind sps) (role column) (copy "survey/files/morgantown.sps")
##    (path "../survey/morgantown.sps") (absolute "/mnt/survey/morgantown.sps")
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

import std/[strutils, times]
import displaypresets, identity, join, nif, processing, project, settingsnif

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

proc choice(w: var NifWriter; tag, name: string) =
  w.open tag
  w.ident name
  w.close

proc place(w: var NifWriter; p: ProjectPath) =
  if p.path.len > 0: w.value("path", p.path)
  if p.absolute.len > 0: w.value("absolute", p.absolute)

proc modified(w: var NifWriter; t: Time) =
  w.open "modified"
  w.add t.toUnix
  w.add int64(t.nanosecond)
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
  if d.hasSurvey:
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
  if d.hasProcessing: w.writeProcessing(d.processing)
  if d.hasPresets: w.writeDisplayPresets(d.displayPresets)
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
      else: discard
  if f.copy.len == 0: r.problem(n, "a survey file names no copy; it is left out")
  else: d.survey.add f

proc units(r: var Reading; n: NifNode; u: var JoinUnits) =
  for k in n.kids:
    if k.isTree("survey"): r.choice(k, UnitNames, u.survey)
    elif k.isTree("file"): r.choice(k, UnitNames, u.file)
    elif k.isTree("surveyFromHeaders"): r.flag(k, u.surveyFromHeaders)
    elif k.isTree("fileFromHeaders"): r.flag(k, u.fileFromHeaders)

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
      of "processing":
        result.processing = readProcessing(c, name, Processing(), r.problems)
        result.hasProcessing = true
      of "displayPresets":
        result.displayPresets = readDisplayPresets(c, name, r.problems)
        result.hasPresets = true
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
