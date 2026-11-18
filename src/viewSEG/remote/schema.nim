## JSON for core's types, and the `command` tool's schema and decoder,
## both made from `Command` at compile time.
##
## - `toJson`, `schemaOf` and `decode` are generic over a field's type:
##   booleans, integers (the `distinct` ids too), numbers (NaN as `null`),
##   strings, enums by their names, sets and seqs as arrays, objects as their
##   fields. A type they do not know fails the build.
## - `decode` overlays: an object given in part changes only the fields given;
##   a seq or a set given is the whole of it. Every problem is said with
##   where it was (`display.mode: ...`); nothing raises.
## - The command's schema has one property per field of the variant (field
##   names are unique across a Nim variant's branches), and `kind` an enum of
##   the kinds offered. Their descriptions are the doc comments of `Command`
##   and `CommandKind` in `core/state`, read from its source at compile time,
##   so a new field, or a new command once it is in `Offered`, needs no glue
##   here.

import std/[json, macros, math, strutils, tables, typetraits]
import ../core/state

const
  WritesAFile* = {ckExportSettings, ckExportLayout, ckExportLog, ckSaveLayout,
    ckImportLayout, ckResetSettings, ckExportEdits, ckImportEdits, ckForgetFiles}
    ## refused: each writes a file (a reset keeps a backup of the settings;
    ## edits imported are remembered with the file; forgetting files removes
    ## what is remembered about them)
  Preferences* = {ckSettings, ckImportSettings, ckLayout, ckLoadLayout, ckProjectFolder,
    ckUpdateSurvey}
    ## refused: the user's preferences and the windows' arrangement; a
    ## project's data folders and its survey's update, which are written
    ## into the project
  Offered* = {ckOpen, ckBrowse, ckShowFile, ckShowTrace, ckClose, ckCancelJob, ckReorderJob,
    ckRemoveJob, ckGather, ckView, ckDisplay, ckHeader, ckSort, ckFilter, ckProcessing,
    ckReverseAll, ckBack,
    ckEdit, ckOwnFilter, ckUndoEdit, ckRedoEdit, ckClearEdits, ckFileMemory, ckHover, ckSelect,
    ckClearSelection, ckLoadSurvey, ckUnloadSurvey, ckMapView, ckMapBack, ckMapLayer,
    ckSelectPoints, ckHoverPoints,
    ckShowPoints, ckJoin, ckSelectUnmatched, ckSurveyUnits, ckChooseUnit, ckRetry, ckStopReading,
    ckPrepare, ckInspect, ckSpectrum, ckSpectrumDisplay, ckCloseSpectrum, ckSpectrumPanel,
    ckSpectrumCursor, ckStepTrace, ckDisplayPreset, ckTheme, ckOpenPlot, ckPlotDisplay,
    ckPlotCursor, ckClosePlot, ckNewProject, ckOpenProject,
    ckCloseProject, ckReopen, ckListReferences, ckReloadVendors, ckVendorMap, ckStoreReference,
    ckGenerateReference,
    ckPilotReference, ckPilotPreview, ckSelectReference, ckDeleteReference, ckRenameReference,
    ckCopyReference,
    ckViewReference, ckCloseRefView, ckSetCompare, ckClearCompare, ckSwapCompare,
    ckCompareDisplay, ckCompareWindow, ckSubfolders}
    ## what the `command` tool carries out: named one by one, so that a kind
    ## added to `Command` (an export, editing headers in place) is refused
    ## until it is put here, or among those refused, on purpose. The survey
    ## import is a user's in a window (File > Import > Survey) and writes nothing:
    ## it changes the keys the program holds of an open file, in memory, as
    ## loading a survey file or killing a trace changes what it holds. What
    ## the Headers window has on screen (`ckInspect`) only says what its
    ## reader reads, off the UI thread, for `state`'s `headers` to give; so
    ## does reading what survey files' headers say of their unit
    ## (`ckSurveyUnits`), the first bytes of each, for the import's window;
    ## a unit chosen for the import (`ckChooseUnit`) is a label for the
    ## session, as the window's choice is.
    ## An agent's edits (kill, reverse, undo, redo, clear) are shown for the
    ## session only, never remembered with the file; listing what is
    ## remembered (`ckFileMemory`) only reads. The spectrum windows (an FFT window opened, shown
    ## otherwise, closed; the live panel on screen; a cursor held) read off the UI thread
    ## and write nothing; how an agent shows them is for the session only. So
    ## are the display presets an agent saves, renames or deletes, and the
    ## theme it picks (`ckTheme`: the theme it draws in, not the user's
    ## preferences as a whole). An agent may make, open and close a
    ## project (`ckNewProject` writes a new folder only, never data); its
    ## trace edits and survey imports are not written into it. A file opened
    ## again with other options (`ckReopen`) is read as before, read-only, for
    ## the session; a folder for a demultiplexed copy, which would be written
    ## there, is refused. A reference (listed, stored, generated, a pilot rule stored or
    ## previewed, selected, renamed, deleted, copied into the project) is the program's own archive
    ## or the project's `references` folder, never a seismic file; selecting
    ## one is for the session when an agent asks, as a setting is

# ------------------------------------------------------------ to JSON --

proc toJson*[E](x: seq[E]): JsonNode
proc toJson*[E](x: set[E]): JsonNode
proc toJson*[T](x: T): JsonNode

proc toJson*[E](x: seq[E]): JsonNode =
  result = newJArray()
  for e in x: result.add toJson(e)

proc toJson*[E](x: set[E]): JsonNode =
  result = newJArray()
  for e in x: result.add toJson(e)

proc toJson*[T](x: T): JsonNode =
  ## `x` as JSON: see the module's documentation.
  when T is bool: newJBool(x)
  elif T is enum: newJString($x)
  elif T is distinct: toJson(distinctBase(T)(x))
  elif T is SomeFloat:
    if x.classify in {fcNan, fcInf, fcNegInf}: newJNull() else: newJFloat(float(x))
  elif T is SomeInteger: newJInt(BiggestInt(x))
  elif T is string: newJString(x)
  elif T is array:
    result = newJArray()
    for e in x: result.add toJson(e)
  elif T is object or T is tuple:
    result = newJObject()
    for name, f in fieldPairs(x): result[name] = toJson(f)
  else:
    {.error: "no JSON form for " & $T.}

# ------------------------------------------------------------- schema --

proc schemaOf*[E](t: typedesc[seq[E]]): JsonNode
proc schemaOf*[E](t: typedesc[set[E]]): JsonNode
proc schemaOf*[T](t: typedesc[T]): JsonNode

proc schemaOf*[E](t: typedesc[seq[E]]): JsonNode =
  %*{"type": "array", "items": schemaOf(E)}

proc schemaOf*[E](t: typedesc[set[E]]): JsonNode =
  %*{"type": "array", "items": schemaOf(E), "uniqueItems": true}

proc schemaOf*[T](t: typedesc[T]): JsonNode =
  ## The JSON Schema of `T`'s JSON form.
  when T is bool: %*{"type": "boolean"}
  elif T is enum:
    result = %*{"type": "string", "enum": []}
    for v in T: result["enum"].add newJString($v)
  elif T is distinct: schemaOf(distinctBase(T))
  elif T is SomeFloat: %*{"type": "number", "description": "null: not a number"}
  elif T is SomeInteger:
    result = %*{"type": "integer"}
    when sizeof(T) < 8 or T is SomeUnsignedInt:
      result["minimum"] = newJInt(BiggestInt(low(T)))
      when sizeof(T) < 8: result["maximum"] = newJInt(BiggestInt(high(T)))
  elif T is string: %*{"type": "string"}
  elif T is object or T is tuple:
    result = %*{"type": "object", "properties": {}, "additionalProperties": false}
    var x = default(T)
    for name, f in fieldPairs(x): result["properties"][name] = schemaOf(typeof(f))
  else:
    {.error: "no JSON Schema for " & $T.}

# ------------------------------------------------------------- decode --

func describe(n: JsonNode): string =
  case n.kind
  of JNull: "null"
  of JBool: "a boolean"
  of JInt, JFloat: "a number"
  of JString: "a string"
  of JArray: "an array"
  of JObject: "an object"

proc decode*[E](n: JsonNode; x: var seq[E]; path: string; problems: var seq[string])
proc decode*[E](n: JsonNode; x: var set[E]; path: string; problems: var seq[string])
proc decode*[T](n: JsonNode; x: var T; path: string; problems: var seq[string])

proc decode*[E](n: JsonNode; x: var seq[E]; path: string; problems: var seq[string]) =
  if n.kind != JArray:
    problems.add path & ": an array, not " & describe(n)
  else:
    var s = newSeq[E](n.len)
    for i, e in n.elems:
      decode(e, s[i], path & "[" & $i & "]", problems)
    x = move s

proc decode*[E](n: JsonNode; x: var set[E]; path: string; problems: var seq[string]) =
  if n.kind != JArray:
    problems.add path & ": an array, not " & describe(n)
  else:
    var s: set[E] = {}
    for i, e in n.elems:
      var v: E
      decode(e, v, path & "[" & $i & "]", problems)
      s.incl v
    x = s

proc decode*[T](n: JsonNode; x: var T; path: string; problems: var seq[string]) =
  ## Overlays JSON `n` on `x`: see the module's documentation. Each problem
  ## is added to `problems`, and `x` keeps what could not be read.
  template wrong(what: string) =
    problems.add path & ": " & what & ", not " & describe(n)
  when T is bool:
    if n.kind == JBool: x = n.bval else: wrong("true or false")
  elif T is enum:
    if n.kind != JString:
      wrong("a name")
    else:
      var found = false
      for v in T:
        if not found and cmpIgnoreCase($v, n.str) == 0:
          x = v
          found = true
      if not found:
        var names: seq[string]
        for v in T: names.add escapeJson($v)
        problems.add path & ": " & escapeJson(n.str.substr(0, 79)) & " is not one of " &
          names.join(", ")
  elif T is distinct:
    var base = distinctBase(T)(x)
    decode(n, base, path, problems)
    x = T(base)
  elif T is SomeFloat:
    case n.kind
    of JFloat: x = T(n.fnum)
    of JInt: x = T(n.num)
    of JNull: x = T(NaN)
    else: wrong("a number")
  elif T is SomeInteger:
    if n.kind != JInt:
      wrong("an integer")
    elif n.num < BiggestInt(low(T)) or (sizeof(T) < 8 and n.num > BiggestInt(high(T))):
      problems.add path & ": " & $n.num & " is out of range"
    else:
      x = T(n.num)
  elif T is string:
    if n.kind == JString: x = n.str else: wrong("a string")
  elif T is object or T is tuple:
    if n.kind != JObject:
      wrong("an object")
    else:
      for key, v in n.pairs:
        var found = false
        for name, f in fieldPairs(x):
          if name == key:
            found = true
            decode(v, f, path & "." & name, problems)
        if not found:
          when T is AnalysisParams:
            # A window saved before the correlation's own reference went: the
            # field is ignored, the chosen reference is the only one.
            if key == "reference": found = true
          if not found:
            problems.add path & ": no field " & escapeJson(key.substr(0, 79))
  else:
    {.error: "no JSON form for " & $T.}

# --------------------------------------------------- the command's docs --

type
  CommandDocs* = object
    ## The doc comments of `CommandKind`'s values and of `Command`'s fields.
    names*: Table[string, string]  ## a kind's identifier (`ckOpen`) -> its name (`open`)
    kinds*: Table[string, string]  ## a kind's name -> its doc comment
    fields*: Table[string, string] ## a field's name -> its doc comment
    fieldKinds*: Table[string, seq[string]]
      ## a field's name -> the names of the kinds its doc comment says use it
      ## ("ckShowFile, ckShowTrace: the file to show", "ckA: ...; ckB: ...");
      ## none: every kind of its branch

func identBefore(line: string; at: int): string =
  ## The identifier that ends just before `at` in `line`.
  var i = at
  while i > 0 and line[i - 1] in IdentChars: dec i
  line.substr(i, at - 1)

func addDoc(t: var Table[string, string]; key, text: string) =
  t[key] = (t.getOrDefault(key) & " " & text).strip

func renameKinds(t: var Table[string, string]; names: Table[string, string]) =
  ## "ckBrowse: ..." becomes "\"browse\": ...".
  for key, text in t.mpairs:
    var words = text.split(' ')
    for w in words.mitems:
      let core = w.strip(chars = {',', ':', '.', ';', ')', '('})
      if core.len > 2 and core.startsWith("ck") and core in names:
        w = w.replace(core, escapeJson(names[core]))
    text = words.join(" ")

func commandDocs*(source: string): CommandDocs =
  ## Reads `core/state`'s source: the `CommandKind` enum's values with their
  ## names and doc comments, and `Command`'s fields with theirs (a doc
  ## comment on the lines after a field belongs to it). Doc comments name
  ## kinds by their identifiers; those become the names an agent uses.
  result = CommandDocs()
  var section = 0 # 1: the enum, 2: the object
  var last = ""
  for raw in source.splitLines:
    let line = raw.strip
    let indent = raw.len - raw.strip(trailing = false).len
    if raw.contains("CommandKind* = enum"):
      section = 1
      last = ""
    elif raw.contains("Command* = object"):
      section = 2
      last = ""
    elif section > 0 and line.len > 0 and indent <= 2:
      section = 0
    elif section > 0 and line.startsWith("##"):
      if last.len > 0 and section == 1: result.kinds.addDoc(last, line.substr(2).strip)
      elif last.len > 0: result.fields.addDoc(last, line.substr(2).strip)
    elif section == 1 and line.startsWith("ck") and '=' in line:
      let ident = line.substr(0, line.find('=') - 1).strip
      let q1 = line.find('"')
      let q2 = line.find('"', q1 + 1)
      if q1 > 0 and q2 > q1:
        last = line.substr(q1 + 1, q2 - 1)
        result.names[ident] = last
        let doc = line.find("##")
        result.kinds[last] = if doc > 0: line.substr(doc + 2).strip else: ""
    elif section == 2:
      let star = line.find("*:")
      if star > 0:
        last = identBefore(line, star)
        let doc = line.find("##")
        result.fields[last] = if doc > 0: line.substr(doc + 2).strip else: ""
  # "ckA, ckB: ...; ckC: ...": the kinds that use the field
  for field, doc in result.fields:
    var users: seq[string]
    for segment in doc.split(';'):
      let colon = segment.find(':')
      if colon > 0:
        let words = segment.substr(0, colon - 1).split(',')
        var named: seq[string]
        for w in words:
          if w.strip in result.names: named.add result.names[w.strip]
        if named.len == words.len: users.add named
    if users.len > 0: result.fieldKinds[field] = users
  result.kinds.renameKinds(result.names)
  result.fields.renameKinds(result.names)

const Docs* = commandDocs(staticRead("../core/state.nim"))
  ## what `core/state` says of each command and field

func docAllows*(field: string; kind: CommandKind): bool =
  ## Whether `field` belongs to commands of `kind` by its doc comment (a
  ## variant's branch is shared by several kinds; each uses some of its fields).
  let users = Docs.fieldKinds.getOrDefault(field)
  users.len == 0 or $kind in users

# -------------------------------------------------- the command's codec --

type
  CommandField* = object
    ## One field of `Command`, as the schema shows it.
    name*: string
    kinds*: set[CommandKind] ## the kinds offered that take it
    schema*: JsonNode

func fieldName(n: NimNode): string =
  if n.kind == nnkPostfix: $n[1] else: $n

proc branchFields(body: NimNode): seq[NimNode] =
  ## The `nnkIdentDefs` of a variant branch's body.
  case body.kind
  of nnkIdentDefs: result = @[body]
  of nnkRecList:
    for f in body: result.add branchFields(f)
  else: discard

macro commandCodec(offered: static[set[CommandKind]]): untyped =
  ## Makes `newCommand`, `decodeFields` and `variantFields` from `Command`'s
  ## definition: a branch none of whose kinds is in `offered` decodes
  ## nothing, and its fields' types are never looked at.
  let def = bindSym("Command").getImpl
  var recCase: NimNode = nil
  for n in def[2][2]:
    if n.kind == nnkRecCase: recCase = n
  if recCase == nil: error("Command is not a variant")
  let c = ident"c"
  let key = ident"key"
  let v = ident"v"
  let problems = ident"problems"
  let k = ident"k"
  var newCases = nnkCaseStmt.newTree(k)
  var decodeCases = nnkCaseStmt.newTree(newDotExpr(c, ident"kind"))
  var fieldsBody = newStmtList()
  proc unknown(): NimNode =
    quote do:
      `problems`.add "\"" & $`c`.kind & "\" takes no field " &
        escapeJson(`key`.substr(0, 79))
  for i in 1 ..< recCase.len:
    let branch = recCase[i]
    if branch.kind != nnkOfBranch: error("Command has an else branch", branch)
    var names: seq[string]
    for j in 0 ..< branch.len - 1:
      names.add $branch[j]
      newCases.add nnkOfBranch.newTree(ident(names[^1]), nnkObjConstr.newTree(
        ident"Command", nnkExprColonExpr.newTree(ident"kind", ident(names[^1]))))
    # A fresh node at each use: a NimNode belongs to one place in the tree.
    proc taken(): NimNode =
      result = nnkInfix.newTree(ident"*", nnkCurly.newTree(), newLit(offered))
      for n in names: result[1].add ident(n)
    let first = ident(names[0])
    var keyCase = nnkCaseStmt.newTree(key)
    for f in branchFields(branch[^1]):
      for j in 0 ..< f.len - 2:
        let name = fieldName(f[j])
        let field = ident(name)
        keyCase.add nnkOfBranch.newTree(newLit(name), quote do:
          decode(`v`, `c`.`field`, `name`, `problems`))
        let (t1, t2) = (taken(), taken())
        fieldsBody.add quote do:
          when `t1` != {}:
            result.add CommandField(name: `name`, kinds: `t2`,
              schema: schemaOf(typeof(Command(kind: `first`).`field`)))
    keyCase.add nnkElse.newTree(unknown())
    let branchBody = if keyCase.len > 1: keyCase else: unknown()
    var decodeBranch = nnkOfBranch.newTree()
    for n in names: decodeBranch.add ident(n)
    let (t3, other) = (taken(), unknown())
    decodeBranch.add quote do:
      when `t3` != {}: `branchBody`
      else: `other`
    decodeCases.add decodeBranch
  let unknownTop = unknown()
  result = quote do:
    proc newCommand*(`k`: CommandKind): Command =
      ## A command of kind `k`, its fields at their defaults.
      `newCases`

    proc decodeFields*(n: JsonNode; `c`: var Command; `problems`: var seq[string]) =
      ## Overlays the fields JSON object `n` gives (but `kind`) on `c`, of
      ## the kind `c` is; each problem is added to `problems`.
      for `key`, `v` in n.pairs:
        if `key` == "kind": discard
        elif not docAllows(`key`, `c`.kind): `unknownTop`
        else: `decodeCases`

    proc variantFields(): seq[CommandField] =
      ## The fields of the variant's branches of the kinds offered.
      `fieldsBody`

commandCodec(Offered)

proc commandFields*(): seq[CommandField] =
  ## The fields of the kinds offered, in `Command`'s order, each with the
  ## kinds that use it.
  for f in variantFields():
    var kinds: set[CommandKind] = {}
    for k in f.kinds:
      if docAllows(f.name, k): kinds.incl k
    if kinds != {}: result.add CommandField(name: f.name, kinds: kinds, schema: f.schema)

proc takes*(kind: CommandKind): seq[string] =
  ## The fields a command of `kind` uses.
  for f in commandFields():
    if kind in f.kinds: result.add f.name

proc kindOf*(n: JsonNode; kind: var CommandKind): string =
  ## The kind JSON object `n` names, in `kind`; "" when it names one that is
  ## offered, else why not.
  let k = if n.kind == JObject: n.getOrDefault("kind") else: nil
  if n.kind != JObject:
    return "a command is an object with its \"kind\""
  if k == nil or k.kind != JString:
    return "a command needs its \"kind\", a name"
  for v in CommandKind:
    if cmpIgnoreCase($v, k.str) == 0:
      kind = v
      if v in WritesAFile:
        return "\"" & $v & "\" writes a file, which an agent may not do; the user can, " &
          "from the windows"
      if v in Preferences:
        return "\"" & $v & "\" changes the user's preferences or the windows' " &
          "arrangement, which an agent may not do"
      if v notin Offered:
        return "\"" & $v & "\" is not offered to agents"
      return ""
  var names: seq[string]
  for v in Offered: names.add escapeJson($v)
  "no command " & escapeJson(k.str.substr(0, 79)) & "; the commands are " & names.join(", ")

proc commandSchema*(): JsonNode =
  ## The `command` tool's input schema: `kind`, then every field of the
  ## kinds offered, each described from `core/state`'s doc comments and the
  ## kinds that take it.
  var kindText = "What to do. One of:"
  for k in Offered:
    var takes: seq[string]
    for f in commandFields():
      if k in f.kinds: takes.add f.name
    kindText.add "\n- \"" & $k & "\"" & (if takes.len > 0: " (" & takes.join(", ") & ")"
      else: "") & (if Docs.kinds.getOrDefault($k).len > 0: ": " & Docs.kinds[$k] else: "")
  var kinds = newJArray()
  for k in Offered: kinds.add newJString($k)
  var props = newJObject()
  props["kind"] = %*{"type": "string", "enum": kinds, "description": kindText}
  for f in commandFields():
    var s = f.schema
    var used: seq[string]
    for k in f.kinds: used.add "\"" & $k & "\""
    let doc = Docs.fields.getOrDefault(f.name)
    s["description"] = newJString((if doc.len > 0: doc & " " else: "") & "Used by " &
      used.join(", ") & "." & (if s.hasKey("description"): " " & s["description"].str else: ""))
    props[f.name] = s
  # what `core` keeps a value within, stated
  if props.hasKey("display"):
    template bound(field: string; lo, hi: float64) =
      props["display"]["properties"][field]["minimum"] = newJFloat(lo)
      props["display"]["properties"][field]["maximum"] = newJFloat(hi)
    bound("gainDb", -MaxGainDb, MaxGainDb)
    bound("overlap", MinOverlap, MaxOverlap)
    bound("untilMs", MinUntilMs, MaxUntilMs)
    bound("agcWindowMs", MinAgcWindowMs, MaxAgcWindowMs)
    bound("dbPerS", -MaxDbPerS, MaxDbPerS)
    bound("power", -MaxPower, MaxPower)
    bound("clipPercentile", MinClipPercentile, 100.0)
  %*{"type": "object", "properties": props, "required": ["kind"],
    "additionalProperties": false}
