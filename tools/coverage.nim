## Library coverage: the public API of parseSEG and processSEG, held against
## `docs/coverage.md` and the viewer's source.
##
## Usage, from the repository root:
##
##   nim coverage                        # rewrite the page's summary, then check the page
##   nim r tools/coverage.nim check      # check only (what tests/tcoverage.nim does)
##   nim r tools/coverage.nim exports parseSEG|processSEG|<dir> [--next] [--parseSEG:<dir>]
##                                       # a library's exported names: name, kind, module;
##                                       # then the names its docs/api.md does not mention
##
## **Exports.** The compiler's own documentation index says what each module of
## a library exports: `nim jsondoc --project` on the library's umbrella module
## (`src/<library>.nim`), as processSEG's own tests list its exports. The
## umbrella decides which of those `import parseSEG` or `import processSEG`
## gives: its `export` statements (whole modules, `except` lists, single names
## such as `traceindex.openSeismic`), and those of the modules it exports, are
## followed through their `import` statements. Names from outside the library
## (Arraymancer's tensor API, `std/options`) are left out; processSEG's
## re-export of parseSEG's `SampleType` is kept, as processSEG documents it. A
## module that only one platform compiles (`io/tape_windows`) is documented with
## `--os` set for it. Every value of an exported enum is listed, with its type.
## jsondoc leaves out the destructor and copy hooks, and so does this list.
##
## **Which commit.** Each library is read at the commit `atlas.lock` pins
## (`git archive` of `deps/<library>`, which changes nothing in that
## repository), so a library checked out on a work branch does not change the
## answer; a dependency folder without that commit is read as it is. The next
## release of a library is read when a working tree of it is linked at
## `deps/next/<library>` (its committed `HEAD`), and left out otherwise.
##
## **The page.** Its sections `## parseSEG` and `## processSEG` hold tables
## `| Capability | Library calls | Viewer feature | Status |`, grouped under
## `###` headings; the section `## In the next library release` holds the same
## tables under `### parseSEG ...` and `### processSEG ...`. A row names the
## library's names in code spans of its "Library calls" cell (`` `openSeismic` ``,
## `` `f.len` ``, `` `$` ``). Its status is one or more parts joined by `;`,
## each a status word and an optional remark: `built (join); planned (the
## rest)`, `to plan (priority 3)`, `not applicable (reason)`. The status words:
## `built`, `internal`, `planned`, `to plan`, `not applicable`.
##
## **The check** fails when:
## - a name a library exports is named in no row of its section (an enum value
##   counts as named when its type is);
## - a name the next release adds (a new value of an old enum included) is named
##   in no row of the library's sections;
## - a row whose status is only `built` and `internal` names a library name that
##   the viewer's source (`src/`, its code: not its comments or strings) never
##   names, or a row that is built in part names none of its names there; an
##   enum type is named where one of its values is, a setter (`revision=`) where
##   its name is, and operators (`$`, `[]`) always, since a text search cannot
##   tell. The search is by name, so it cannot tell a library's `len` or
##   `classify` from another's: what a row claims stays the row's to make true;
## - a row says `built` or `internal` for a distinctive name (below) the
##   viewer's source also declares itself (a proc, a type: processSEG's
##   `spreadOf` beside a `spreadOf` of the viewer's), as the search cannot
##   tell whose src/ calls: rename the viewer's, or list it in `KnownHomonyms`
##   with why (common names, `len`, `add`, stay the row's to make true);
## - a row that says `built` or `internal` (also in part) names a window
##   ("the Headers window") or a menu item ("File → Import → Survey") that the
##   toolkit code's string literals do not name (each item a label, or the
##   submenu's word and the item's together, "Import survey..."), but for a
##   window its status names in a later part ("planned (the processing
##   window)");
## - a distinctive name (8 characters or more, camelCase: `recordCompleteness`)
##   that src/ names has only rows that say `planned`, `to plan` or `not
##   applicable`, unless `KnownHomonyms` says what src/ names by it (shorter
##   and common names, `record`, `merge`, stay an advisory list);
## - a row names no name of its library, or its status cannot be read;
## - the summary between the page's summary marks is not the one the tables give.
##
## A name's status is that of the rows naming it, the most advanced first (built,
## internal, planned, to plan, not applicable). In a row built in part, a name
## the viewer's source names is built (or internal), and any other name has the
## row's next status.

import std/[algorithm, json, os, osproc, sequtils, sets, streams, strutils, tables]

type
  Status* = enum
    stBuilt = "built"
    stInternal = "internal"
    stPlanned = "planned"
    stToPlan = "to plan"
    stNotApplicable = "not applicable"

  Export* = object
    name*: string   ## As declared; an operator without its backticks.
    kind*: string   ## proc, iterator, template, macro, method, type, const, let, var,
                    ## enum value, re-export
    module*: string ## The declaring module, relative to `src/<library>/` (`model/keys`).
    owner*: string  ## An enum value's type; a re-export's library.

  Library* = object
    name*: string    ## parseSEG, processSEG
    version*: string ## From the nimble file.
    source*: string  ## Where it was read: the commit, or the folder.
    exports*: seq[Export]

  Row* = object
    line*: int     ## 1-based line on the page.
    lib*: string   ## parseSEG, processSEG
    next*: bool    ## In "In the next library release".
    group*: string ## The `###` (or `####`) heading above it.
    capability*, calls*, feature*, status*: string
    statuses*: seq[Status]
    priority*: int ## `to plan (priority N)`: N; 0 when none is given.

  Page* = object
    text*: string
    rows*: seq[Row]
    problems*: seq[string] ## What could not be read.

const
  Libraries* = ["parseSEG", "processSEG"]
  PageFile* = "docs" / "coverage.md"
  SummaryStart* = "<!-- summary: written by `nim coverage` from the tables below -->"
  SummaryEnd* = "<!-- end of summary -->"
  NextHeading = "## In the next library release"
  KnownHomonyms* = {
    "endTimeMs": "a field of parseSEG's channel-set summary the Headers window reads, " &
      "not the exported func of a channel set descriptor",
    "recordLengthMs": "a field of parseSEG's file summary the Headers window reads, not " &
      "the exported func of the general headers",
    "fieldTable": "the Headers window's own table of fields (ui/imgui/headerswindow)",
    "readSamples": "the Headers window's reader's own (core/inspector), not SEG-2's",
    "recordIndex": "a field of the viewer's `Command` (the SEG-D record a trace counts in)",
    "tracesAt": "the viewer's own `Survey.tracesAt` (core/survey)",
    "SweepSpec": "the type of a layer kind kept for the planned generated pilot " &
      "(core/panels); nothing makes one yet",
    "keysRevision": "parseSEG's is called (`file[].keysRevision`, core/surveyjobs and " &
      "core/recordqc); the viewer's `Session.keysRevision` holds what it gave",
    "isSeismic": "parseSEG's is called (`f.index.isSeismic(t)`, core/shots, core/state); " &
      "the viewer's own is `FileKind.isSeismic` (core/filekinds)",
    "cutShort": "the viewer's own: core/filejobs (the file's log has `dcTruncated`) and " &
      "core/reader (a `stat` before each read); parseSEG's is not called yet",
    "reserveRelations": "the viewer's `SurveyFileBuilder.reserveRelations` (core/survey), " &
      "which calls parseSEG's where it compiles (core/surveyjobs)"}
    ## Library names `src/` names for something of its own too (a field, its
    ## own proc), each checked by hand, with what src/ does with them: a text
    ## search cannot tell them from the library's (`check`)

# ------------------------------------------------------------------ names --

func normName*(s: string): string =
  ## Nim's identifier equality: the first character as it is, the rest without
  ## case and underscores. An operator is kept as it is.
  if s.len == 0 or s[0] notin IdentStartChars: return s
  result = $s[0]
  for c in s.toOpenArray(1, s.high):
    if c != '_': result.add c.toLowerAscii

func isOperator*(name: string): bool =
  name.len > 0 and name[0] notin IdentStartChars

func identsIn(text: string): seq[string] =
  ## The identifiers of `text`.
  var i = 0
  while i < text.len:
    if text[i] in IdentStartChars:
      let start = i
      while i < text.len and text[i] in IdentChars: inc i
      result.add text[start ..< i]
    elif text[i] in Digits:
      while i < text.len and text[i] in IdentChars: inc i
    else:
      inc i

func codeSpans*(text: string): seq[string] =
  ## The contents of the Markdown code spans of `text` (a run of backticks
  ## closed by a run of the same length).
  var i = 0
  while i < text.len:
    if text[i] == '`':
      var n = 0
      while i < text.len and text[i] == '`':
        inc n
        inc i
      let fence = repeat('`', n)
      var j = text.find(fence, i)
      while j >= 0 and j + n < text.len and text[j + n] == '`':
        j = text.find(fence, j + n + 1)
      if j < 0:
        i = text.len
      else:
        result.add text[i ..< j].strip
        i = j + n
    else:
      inc i

func spanNames*(cell: string): seq[string] =
  ## The names a "Library calls" cell gives: the identifiers of its code spans,
  ## and the spans that are an operator alone (`` `$` ``, `` `[]=` ``).
  for span in codeSpans(cell):
    let ids = identsIn(span)
    if ids.len == 0 and span.len > 0: result.add span
    else: result.add ids

func codeNames*(s: string): HashSet[string] =
  ## The identifiers the Nim code `s` uses (comments, doc comments and string
  ## and character literals left out), normalized.
  result = initHashSet[string]()
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '#':
      if i + 1 < s.len and s[i + 1] == '[' or i + 2 < s.len and s[i + 1] == '#' and
          s[i + 2] == '[':
        var depth = 0
        while i < s.len:
          if s.continuesWith("#[", i):
            inc depth
            i += 2
          elif s.continuesWith("]#", i):
            dec depth
            i += 2
            if depth == 0: break
          else: inc i
      else:
        while i < s.len and s[i] != '\n': inc i
    elif s.continuesWith("\"\"\"", i):
      i += 3
      while i < s.len and not s.continuesWith("\"\"\"", i): inc i
      i += 3
      while i < s.len and s[i] == '"': inc i
    elif c == '"':
      let raw = i > 0 and s[i - 1] in IdentChars
      inc i
      while i < s.len and s[i] != '"' and s[i] != '\n':
        if s[i] == '\\' and not raw: inc i
        inc i
      inc i
    elif c == '\'':
      if i > 0 and s[i - 1] in IdentChars:
        inc i # a literal's type suffix: 1'u8
      else:
        inc i
        if i < s.len and s[i] == '\\': inc i
        while i < s.len and s[i] != '\'' and s[i] != '\n': inc i
        inc i
    elif c == '`':
      let e = s.find('`', i + 1)
      if e < 0: i = s.len
      else:
        result.incl normName(s[i + 1 ..< e])
        i = e + 1
    elif c in IdentStartChars:
      let start = i
      while i < s.len and s[i] in IdentChars: inc i
      result.incl normName(s[start ..< i])
    elif c in Digits:
      while i < s.len and s[i] in IdentChars: inc i
    else:
      inc i

proc sourceNames*(dir: string): HashSet[string] =
  ## `codeNames` of every `.nim` file under `dir`.
  result = initHashSet[string]()
  for path in walkDirRec(dir):
    if path.endsWith(".nim"): result.incl codeNames(readFile(path))

func codeOnly(line: string): string =
  ## `line` up to its comment (a `#` outside a string literal).
  var inString = false
  for i, c in line:
    if c == '"': inString = not inString
    elif c == '#' and not inString: return line[0 ..< i]
  line

func declaredNames*(s: string): HashSet[string] =
  ## The names the Nim code `s` declares itself, normalized: its procs,
  ## funcs, iterators, templates, macros, methods and converters, and the
  ## types of its type sections (fields, variables and enum values are not
  ## looked for).
  result = initHashSet[string]()
  var inType = false
  for raw in s.splitLines:
    let line = raw.codeOnly
    let t = line.strip
    if t.len > 0:
      if line[0] != ' ': inType = t == "type" or t.startsWith("type ")
      var rest = t
      if rest.startsWith("type "): rest = rest[5 .. ^1].strip
      var routine = false
      for kw in ["proc ", "func ", "iterator ", "template ", "macro ", "method ", "converter "]:
        if rest.startsWith(kw):
          rest = rest[kw.len .. ^1].strip
          routine = true
      let typed = inType and rest.len > 0 and rest[0] in {'A' .. 'Z'} and
        (" = " in rest or "* =" in rest or rest.endsWith("="))
      if routine or typed:
        if rest.startsWith("`"):
          let e = rest.find('`', 1)
          if e > 1: result.incl normName(rest[1 ..< e])
        else:
          var i = 0
          while i < rest.len and rest[i] in IdentChars: inc i
          if i > 0 and rest[0] in IdentStartChars: result.incl normName(rest[0 ..< i])

proc sourceDeclared*(dir: string): HashSet[string] =
  ## `declaredNames` of every `.nim` file under `dir`.
  result = initHashSet[string]()
  for path in walkDirRec(dir):
    if path.endsWith(".nim"): result.incl declaredNames(readFile(path))

func stringLiterals*(s: string): seq[string] =
  ## The contents of the ordinary string literals of the Nim code `s`
  ## (escapes left as written), comments left out.
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '#':
      while i < s.len and s[i] != '\n': inc i
    elif s.continuesWith("\"\"\"", i):
      let e = s.find("\"\"\"", i + 3)
      if e < 0: break
      result.add s[i + 3 ..< e]
      i = e + 3
    elif c == '"':
      var j = i + 1
      while j < s.len and s[j] != '"' and s[j] != '\n':
        if s[j] == '\\': inc j
        inc j
      result.add s[i + 1 ..< min(j, s.len)]
      i = j + 1
    elif c == '\'' and not (i > 0 and s[i - 1] in IdentChars):
      i += (if i + 1 < s.len and s[i + 1] == '\\': 4 else: 3)
    else: inc i

type UiNames* = object
  ## What the viewer's windows and menus are called, from the string
  ## literals of its toolkit code (`src/viewSEG/ui`).
  windows*: HashSet[string] ## window titles ("Headers" of "  Headers###headers") and names
  labels*: HashSet[string] ## every literal, trimmed and without a closing "..."

func trimmedLabel(s: string): string =
  result = s.strip
  for tail in ["...", "…"]:
    if result.endsWith(tail): result = result[0 ..< result.len - tail.len].strip

proc uiNames*(dir: string): UiNames =
  ## The window and menu names of the toolkit code under `dir`.
  result = UiNames(windows: initHashSet[string](), labels: initHashSet[string]())
  for path in walkDirRec(dir):
    if path.endsWith(".nim"):
      for l in stringLiterals(readFile(path)):
        let label = trimmedLabel(l)
        if label.len > 0:
          result.labels.incl label
          result.windows.incl label
        let k = l.find("###")
        if k > 0 and l[0 ..< k].strip.len > 0: result.windows.incl l[0 ..< k].strip

func windowsNamed*(feature: string): seq[string] =
  ## The windows a "Viewer feature" cell names: "Headers" of "the Headers
  ## window", "Import survey" of "the Import survey window" (a name starts
  ## with a capital; "the processing window" names none).
  var words: seq[string]
  for w in feature.splitWhitespace: words.add w.strip(chars = {',', ';', ':', '(', ')', '"'})
  for i in 1 ..< words.len:
    if words[i] in ["window", "window's", "windows"]:
      let w1 = words[i - 1]
      if w1.len > 0 and w1[0] in {'A' .. 'Z'} and w1.allCharsInSet(Letters):
        result.add w1
      elif i >= 2 and w1.len > 0 and w1.allCharsInSet({'a' .. 'z'}) and
          words[i - 2].len > 0 and words[i - 2][0] in {'A' .. 'Z'} and
          words[i - 2].allCharsInSet(Letters):
        result.add words[i - 2] & " " & w1

func menuPaths*(feature: string): seq[seq[string]] =
  ## The menu paths a "Viewer feature" cell names: "File → Import → Survey"
  ## as its items, the first the word before the first arrow, the last the
  ## text after the last up to a comma, a semicolon, a colon or a bracket.
  let parts = feature.split("→")
  var i = 0
  while i < parts.len - 1:
    var path: seq[string]
    let before = parts[i].strip.splitWhitespace
    if before.len > 0: path.add before[^1]
    var j = i + 1
    while true:
      # An item ends the path where its text stops, or at the last arrow.
      let part = parts[j]
      var cut = part.len
      for stop in [',', ';', ':', '(', ')']:
        let k = part.find(stop)
        if k >= 0: cut = min(cut, k)
      if cut < part.len or j == parts.high:
        path.add part[0 ..< cut].strip
        break
      path.add part.strip
      inc j
    result.add path
    i = j

func menuPathKnown(path: openArray[string]; ui: UiNames): string =
  ## "" when each item of `path` is a label of the viewer's menus (or the
  ## submenu's word and the item's make one, "Import" and "Survey" of
  ## "Import survey..."); else the first item that is not.
  func isLabel(it, before: string; first: bool): bool =
    let it = trimmedLabel(it)
    result = it in ui.labels
    if not result and not first and it.len > 0:
      result = trimmedLabel(before) & " " & it[0].toLowerAscii & it[1 .. ^1] in ui.labels
  for k, item in path:
    var known = false
    if k == path.high:
      # The last runs on into the cell's words: its leading words that name one.
      let words = item.splitWhitespace
      for n in countdown(words.len, 1):
        if not known: known = isLabel(words[0 ..< n].join(" "), path[max(k - 1, 0)], k == 0)
    else: known = isLabel(item, path[max(k - 1, 0)], k == 0)
    if not known: return item
  ""

# --------------------------------------------------------------- exports --

type
  Module = object
    locals: Table[string, string] ## Import name → module path ("" outside the library).
    internal: seq[string]         ## The library modules it imports.
    exports: seq[string]          ## Its `export` statements, without the keyword.

  Graph = object
    lib, srcDir: string
    other: Table[string, string]     ## The other library's names (processSEG's parseSEG).
    docs: Table[string, seq[Export]] ## Module path → its own exports (jsondoc).
    memo: Table[string, seq[Export]]
    missing: HashSet[string]         ## Exported modules jsondoc did not document.

func stripComment(line: string): string =
  let i = line.find('#')
  if i < 0: line else: line[0 ..< i]

func joinPathSpaces(s: string): string =
  ## `std / os` as `std/os`.
  result = s
  while " /" in result or "/ " in result:
    result = result.replace(" /", "/").replace("/ ", "/")

iterator statements(source: string): string =
  ## Each `import`, `from` and `export` statement of `source` with its
  ## continuation lines, at any indentation (`when` branches too).
  let lines = source.splitLines
  var i = 0
  while i < lines.len:
    var s = stripComment(lines[i]).strip
    if s.startsWith("import ") or s.startsWith("from ") or s.startsWith("export "):
      while (s.endsWith(",") or s.count('[') > s.count(']')) and i + 1 < lines.len:
        inc i
        s.add " " & stripComment(lines[i]).strip
      yield joinPathSpaces(s)
    inc i

func splitTop(s: string): seq[string] =
  ## `s` split at the commas outside brackets.
  var depth = 0
  var cur = ""
  for c in s:
    case c
    of '[': inc depth
    of ']': dec depth
    else: discard
    if c == ',' and depth == 0:
      result.add cur.strip
      cur = ""
    else:
      cur.add c
  if cur.strip.len > 0: result.add cur.strip

func withAlias(item: string): (string, string) =
  ## `path as alias` → (path, alias); `a/b` → (`a/b`, `b`).
  let it = item.strip.strip(chars = {'"'})
  let a = it.find(" as ")
  if a >= 0: (it[0 ..< a].strip, it[a + 4 .. ^1].strip)
  else: (it, it[it.rfind('/') + 1 .. ^1])

func importItems(body: string): seq[(string, string)] =
  ## The (path, name) pairs of an import list.
  var b = body
  let ex = b.find(" except ")
  if ex >= 0: b = b[0 ..< ex]
  for item in splitTop(b):
    let open = item.find('[')
    if open >= 0:
      let prefix = item[0 ..< open]
      for sub in item[open + 1 ..< item.rfind(']')].split(','):
        if sub.strip.len > 0:
          let (path, name) = withAlias(sub)
          result.add (prefix & path, name)
    elif item.len > 0:
      result.add withAlias(item)

proc resolveImport(path, fromFile, srcDir: string): string =
  ## The library module `path` names in `fromFile`, or "" (stdlib, another package).
  if path.startsWith("std/") or path.startsWith("system/") or path.startsWith("pkg/"):
    return ""
  for base in [fromFile.parentDir, srcDir]:
    let p = normalizedPath(base / path & ".nim")
    if fileExists(p): return p
  ""

proc readModule(path, srcDir: string): Module =
  for st in statements(readFile(path)):
    if st.startsWith("export "):
      result.exports.add st["export ".len .. ^1]
    else:
      let body =
        if st.startsWith("from "):
          let i = st.find(" import ")
          if i < 0: "" else: st["from ".len ..< i]
        else: st["import ".len .. ^1]
      for (p, name) in importItems(body):
        let r = resolveImport(p, path, srcDir)
        result.locals[name] = r
        if r.len > 0 and r notin result.internal: result.internal.add r

proc moduleName(g: Graph; path: string): string =
  let rel = path.relativePath(g.srcDir).changeFileExt("")
  if rel.startsWith(g.lib & "/"): rel[g.lib.len + 1 .. ^1] else: rel

proc exportsOf(g: var Graph; path: string): seq[Export] =
  ## What `import <path>` gives of the library.
  if path in g.memo: return g.memo[path]
  g.memo[path] = @[] # a cycle sees nothing
  if path notin g.docs and path.splitFile.name != g.lib: g.missing.incl path
  result = g.docs.getOrDefault(path)
  let m = readModule(path, g.srcDir)
  for body in m.exports:
    let ex = body.find(" except ")
    if ex >= 0:
      let target = m.locals.getOrDefault(body[0 ..< ex].strip)
      var left: seq[string]
      for n in body[ex + " except ".len .. ^1].split(','): left.add n.strip.strip(chars = {'`'})
      if target.len > 0:
        for e in g.exportsOf(target):
          if e.name notin left: result.add e
    else:
      for raw in body.split(','):
        let item = raw.strip
        let dot = item.find('.')
        if item.len == 0: discard
        elif dot > 0:
          let target = m.locals.getOrDefault(item[0 ..< dot])
          let name = item[dot + 1 .. ^1].strip(chars = {'`'})
          if target.len > 0:
            for e in g.exportsOf(target):
              if e.name == name or e.kind == "enum value" and e.owner == name: result.add e
        elif item in m.locals:
          if m.locals[item].len > 0: result.add g.exportsOf(m.locals[item])
        else:
          var found = false
          for imp in m.internal:
            for e in g.exportsOf(imp):
              if e.name == item or e.kind == "enum value" and e.owner == item:
                result.add e
                found = true
          if not found and item in g.other:
            result.add Export(name: item, kind: "re-export", module: g.moduleName(path),
              owner: g.other[item])
  g.memo[path] = result

func kindOf(jsonKind: string): string =
  ## `skProc` → `proc` (jsondoc gives `func`s as procs).
  jsonKind[2 .. ^1].toLowerAscii

func enumValues(code: string): seq[string] =
  ## The values of an enum declaration as jsondoc prints it.
  let body = code[code.find("enum") + 4 .. ^1]
  for line in body.splitLines:
    for part in line.split("##")[0].split(','):
      let v = part.split('=')[0].strip.strip(chars = {'`'})
      if v.len > 0 and v.validIdentifier: result.add v

proc readDocs(g: var Graph; outDir: string) =
  ## The entries of every module jsondoc wrote into `outDir`.
  for path in walkDirRec(outDir):
    if path.endsWith(".json") and path.extractFilename != "theindex.json":
      let doc = parseFile(path)
      let module = expandFilename(doc["orig"].getStr)
      var list: seq[Export]
      for e in doc["entries"]:
        # jsondoc gives an operator in backticks, HTML-escaped: `&lt;=`.
        let name = e["name"].getStr.strip(chars = {'`'}).multiReplace(("&lt;", "<"),
          ("&gt;", ">"), ("&quot;", "\""), ("&amp;", "&"))
        let kind = kindOf(e["type"].getStr)
        if not name.startsWith("="):
          list.add Export(name: name, kind: kind, module: g.moduleName(module))
          if kind == "type" and "= enum" in e{"code"}.getStr:
            for v in enumValues(e["code"].getStr):
              list.add Export(name: v, kind: "enum value", module: g.moduleName(module),
                owner: name)
      g.docs[module] = list

proc nimCfgPaths*(root: string): seq[string] =
  ## The `--path:` entries of the repository's nim.cfg, absolute, apart from
  ## the two libraries (given separately).
  for line in readFile(root / "nim.cfg").splitLines:
    let s = line.strip
    if s.startsWith("--path:"):
      let p = s["--path:".len .. ^1].strip(chars = {'"'})
      if not (p.endsWith("parseSEG/src") or p.endsWith("processSEG/src")):
        result.add root / p

proc jsondoc(file, outDir, cache: string; paths: seq[string]; project: bool;
    os = ""): Process =
  var args = @["jsondoc", "--doccmd:skip", "--hints:off", "--warnings:off", "--skipProjCfg",
    "--skipParentCfg", "--skipUserCfg", "--noNimblePath", "--nimcache:" & cache,
    "--outdir:" & outDir]
  if project: args.add "--project"
  if os.len > 0: args.add "--os:" & os
  for p in paths: args.add "--path:" & p
  args.add file
  startProcess(getCurrentCompilerExe(), args = args,
    options = {poStdErrToStdOut, poUsePath})

proc finish(p: Process; what: string) =
  let output = p.outputStream.readAll
  let code = p.waitForExit
  p.close
  if code != 0:
    raise newException(IOError, "nim jsondoc failed for " & what & ":\n" & output)

proc nimbleVersion(root, lib: string): string =
  let path = root / lib & ".nimble"
  if fileExists(path):
    for line in readFile(path).splitLines:
      let s = line.strip
      if s.startsWith("version") and '"' in s:
        return s[s.find('"') + 1 ..< s.rfind('"')]
  "?"

type LibSource* = object
  name*: string      ## parseSEG, processSEG
  root*: string      ## A folder holding `src/<name>.nim` (and the nimble file, docs/api.md).
  source*: string    ## What it is: the commit, or the folder.
  parseRoot*: string ## For a processSEG: the parseSEG it is documented against.
  next*: bool        ## A next release.

proc graphOf(l: LibSource; docDirs: openArray[string]; other: Library): Graph =
  result = Graph(lib: l.name, srcDir: expandFilename(l.root / "src"))
  for e in other.exports: result.other[e.name] = other.name
  for d in docDirs: result.readDocs(d)

proc readLibraries*(libs: openArray[LibSource]; paths: seq[string];
    work: string): seq[Library] =
  ## The exports of each library, read by `nim jsondoc` runs side by side.
  proc docPaths(l: LibSource): seq[string] =
    result = @[l.root / "src"]
    if l.parseRoot.len > 0: result.add l.parseRoot / "src"
    result.add paths
  var procs: seq[(Process, string)]
  for i, l in libs:
    procs.add (jsondoc(l.root / "src" / l.name & ".nim", work / "doc" & $i, work / "cache" & $i,
      docPaths(l), project = true), l.name)
  for (p, what) in procs: p.finish(what)
  result.setLen libs.len
  # parseSEG first: a processSEG keeps the names it re-exports from it.
  for pass in ["parseSEG", "processSEG"]:
    for i, l in libs:
      if l.name == pass:
        var other: Library
        for j, x in libs:
          if x.name == "parseSEG" and l.parseRoot.len > 0 and x.root == l.parseRoot:
            other = result[j]
        var dirs = @[work / "doc" & $i]
        var g = graphOf(l, dirs, other)
        let umbrella = g.srcDir / l.name & ".nim"
        discard g.exportsOf(umbrella)
        if g.missing.len > 0:
          # Modules only another platform compiles, each documented for it.
          var platform: seq[(Process, string)]
          var n = 0
          for m in g.missing:
            let os = if m.splitFile.name.endsWith("_windows"): "windows" else: "linux"
            let dir = work / "platform" & $i & "_" & $n
            platform.add (jsondoc(m, dir, dir / "cache", docPaths(l), project = false, os), m)
            dirs.add dir
            inc n
          for (p, what) in platform: p.finish(what)
          g = graphOf(l, dirs, other)
        var seen = initHashSet[string]()
        var lib = Library(name: l.name, version: nimbleVersion(l.root, l.name),
          source: l.source)
        for e in g.exportsOf(umbrella):
          let key = e.name & "\t" & e.kind & "\t" & e.module & "\t" & e.owner
          if key notin seen:
            seen.incl key
            lib.exports.add e
        lib.exports.sort(proc (a, b: Export): int =
          cmp((a.module, a.name, a.kind), (b.module, b.name, b.kind)))
        result[i] = lib

func names*(lib: Library): seq[string] =
  ## The distinct exported names, enum values left out.
  var seen = initHashSet[string]()
  for e in lib.exports:
    if e.kind != "enum value" and e.name notin seen:
      seen.incl e.name
      result.add e.name

func enumValueOwners*(lib: Library): Table[string, string] =
  for e in lib.exports:
    if e.kind == "enum value": result[e.name] = e.owner

# ------------------------------------------------------------ the sources --

proc lockedCommit(root, lib: string): string =
  let lock = parseFile(root / "atlas.lock")
  lock["items"]{lib}{"commit"}.getStr

proc gitArchive(repo, rev, dest, lib: string): bool =
  ## The files of `rev` of the repository at `repo` that this tool reads, in
  ## `dest`; false when git cannot give them.
  when defined(posix):
    createDir(dest)
    let cmd = "git -C " & quoteShell(repo) & " archive --format=tar " & quoteShell(rev) &
      " src docs/api.md " & lib & ".nimble | tar -x -C " & quoteShell(dest)
    execCmdEx(cmd).exitCode == 0 and fileExists(dest / "src" / lib & ".nim")
  else:
    false

proc gitHead(repo: string): string =
  let (o, code) = execCmdEx("git -C " & quoteShell(repo) & " rev-parse HEAD")
  if code == 0: o.strip else: ""

proc librarySources*(root, work: string): seq[LibSource] =
  ## Each library at the commit atlas.lock pins (or its folder as it is),
  ## then the next releases linked at `deps/next/<library>`, at their `HEAD`.
  ## A next processSEG is documented against the next parseSEG when there is
  ## one.
  for next in [false, true]:
    for lib in Libraries:
      let repo = if next: root / "deps" / "next" / lib else: root / "deps" / lib
      if fileExists(repo / "src" / lib & ".nim"):
        let rev = if next: gitHead(repo) else: lockedCommit(root, lib)
        let dest = work / (if next: "next" else: "locked") / lib
        var s = LibSource(name: lib, root: repo, source: repo, next: next)
        if rev.len > 0 and gitArchive(repo, rev, dest, lib):
          s.root = dest
          s.source = "commit " & rev[0 ..< 7]
        if lib == "processSEG":
          for x in result:
            if x.name == "parseSEG": s.parseRoot = x.root # the next one replaces the locked
        result.add s

# --------------------------------------------------------------- the page --

func cells(line: string): seq[string] =
  ## The cells of a table row, split at the pipes that are not escaped.
  var cur = ""
  var i = 0
  let s = line.strip
  let last = if s.endsWith("|") and not s.endsWith("\\|"): s.len - 1 else: s.len
  i = if s.startsWith("|"): 1 else: 0
  while i < last:
    if s[i] == '\\' and i + 1 < last and s[i + 1] == '|':
      cur.add '|'
      i += 2
    elif s[i] == '|':
      result.add cur.strip
      cur = ""
      inc i
    else:
      cur.add s[i]
      inc i
  result.add cur.strip

func statusParts(cell: string): seq[string] =
  ## `cell` split at the semicolons outside parentheses.
  var depth = 0
  var cur = ""
  for c in cell:
    if c == '(': inc depth
    elif c == ')': dec depth
    if c == ';' and depth <= 0:
      result.add cur
      cur = ""
    else:
      cur.add c
  result.add cur

func parseStatus*(cell: string; statuses: var seq[Status]; priority: var int): bool =
  ## The status words of a status cell, in order; false when a part has none.
  statuses = @[]
  priority = 0
  result = cell.strip.len > 0
  for part in statusParts(cell):
    let p = part.strip
    var found = false
    for s in Status:
      let w = $s
      if not found and p.startsWith(w) and (p.len == w.len or p[w.len] in {' ', '(', ':', ','}):
        found = true
        statuses.add s
        let at = p.find("priority ")
        if s == stToPlan and at >= 0:
          var n = 0
          var j = at + "priority ".len
          while j < p.len and p[j] in Digits:
            n = n * 10 + ord(p[j]) - ord('0')
            inc j
          priority = n
    if not found: result = false

proc parsePage*(text: string): Page =
  result.text = text
  var lib = ""
  var next = false
  var group = ""
  var n = 0
  for line in text.splitLines:
    inc n
    if line.startsWith("## "):
      group = ""
      next = line.strip == NextHeading
      lib = if line.strip in ["## parseSEG", "## processSEG"]: line[3 .. ^1].strip else: ""
    elif line.startsWith("### ") or line.startsWith("#### "):
      let h = line.strip(chars = {'#', ' '})
      if next and line.startsWith("### "):
        lib = ""
        for l in Libraries:
          if h == l or h.startsWith(l & " "): lib = l
        group = ""
      else:
        group = h
    elif lib.len > 0 and line.startsWith("|"):
      let c = cells(line)
      let isRule = c.len > 0 and c[0].len > 0 and c[0].strip(chars = {'-', ':'}).len == 0
      if c.len > 0 and (c[0] == "Capability" or isRule):
        discard
      elif c.len != 4:
        result.problems.add "line " & $n & ": a row of " & $c.len & " cells, not 4"
      else:
        var r = Row(line: n, lib: lib, next: next, group: group, capability: c[0], calls: c[1],
          feature: c[2], status: c[3])
        if not parseStatus(c[3], r.statuses, r.priority):
          result.problems.add "line " & $n & ": status \"" & c[3] &
            "\" (built, internal, planned, to plan, not applicable; parts joined by ';')"
        result.rows.add r

# -------------------------------------------------------------- the check --

type
  Coverage* = object
    ## What the check found, and what the summary counts.
    problems*: seq[string]
    nameStatus*: array[2, Table[string, Status]] ## Per library: name → status.

func libIndex(name: string): int = (if name == "parseSEG": 0 else: 1)

func namedIn(row: Row; normNames: Table[string, string]): seq[string] =
  ## The library names `row` names, as the library spells them, once each.
  ## A name also names its setter (`revision` names `revision=`).
  for n in spanNames(row.calls):
    let k = normName(n)
    for key in [k, k & "="]:
      if key in normNames and normNames[key] notin result: result.add normNames[key]

func usedBySource(name: string; src: HashSet[string]): bool =
  ## Whether the viewer's source names `name` (a setter `x=` by `x`; an enum
  ## type by any of its values, which `check` adds to `src`).
  isOperator(name) or normName(name.strip(leading = false, chars = {'='})) in src

func rowNameStatus(row: Row; name: string; src: HashSet[string]): Status =
  ## The status `row` gives `name` (the module's doc says how).
  if row.statuses.len == 1: return row.statuses[0]
  let shown = row.statuses.filterIt(it in {stBuilt, stInternal})
  let rest = row.statuses.filterIt(it notin {stBuilt, stInternal})
  if shown.len > 0 and (usedBySource(name, src) or rest.len == 0): shown[0]
  else: rest[0]

func distinctive*(name: string): bool =
  ## A name no common word is: 8 characters or more, a capital after its
  ## first (`recordCompleteness`, `SweepSpec`; not `record`, `merge`).
  if name.len < 8 or isOperator(name): return false
  for c in name.toOpenArray(1, name.high):
    if c in {'A' .. 'Z'}: return true
  false

proc check*(page: Page; libs, next: openArray[Library]; src: HashSet[string];
    declared = initHashSet[string](); ui = UiNames()): Coverage =
  ## Holds `page` against the libraries' exports (`libs`: the locked
  ## releases; `next`: the next ones found, maybe none), the viewer's source
  ## names `src` and the names it declares itself `declared` (normalized),
  ## and its windows' and menus' names `ui` (none: not checked).
  result.problems = page.problems
  var known = initHashSet[string]()
  for (name, _) in KnownHomonyms: known.incl normName(name)
  for lib in libs:
    let li = libIndex(lib.name)
    var norm: Table[string, string]
    for n in lib.names: norm[normName(n)] = n
    for v, _ in lib.enumValueOwners: norm[normName(v)] = v
    var named = initHashSet[string]()
    var nextLib: Library
    var hasNext = false
    for x in next:
      if x.name == lib.name:
        nextLib = x
        hasNext = true
    var nextNorm = norm
    if hasNext:
      for n in nextLib.names: nextNorm[normName(n)] = n
      for v, _ in nextLib.enumValueOwners: nextNorm[normName(v)] = v
    var nextNamed = initHashSet[string]()
    # An enum type is used where one of its values is.
    var used = src
    for x in [lib, nextLib]:
      for v, owner in x.enumValueOwners:
        if normName(v) in src: used.incl normName(owner)
    for row in page.rows:
      if row.lib == lib.name:
        let names = row.namedIn(if row.next: nextNorm else: norm)
        let where = "line " & $row.line & " (" & lib.name & ", " & row.capability & ")"
        if names.len == 0 and (not row.next or hasNext):
          result.problems.add where & ": names no exported name of " & lib.name &
            (if row.next: "'s next release" else: "")
        for n in names:
          if row.next: nextNamed.incl n
          else:
            named.incl n
            nextNamed.incl n
        if row.statuses.len > 0 and names.len > 0:
          let claims = row.statuses.filterIt(it in {stBuilt, stInternal})
          if claims.len == row.statuses.len:
            var unused: seq[string]
            for n in names:
              if not usedBySource(n, used): unused.add n
            if unused.len > 0:
              result.problems.add where & ": says " & row.status & ", but src/ never names " &
                unused.join(", ")
          elif claims.len > 0:
            var any = false
            for n in names:
              if usedBySource(n, used): any = true
            if not any:
              result.problems.add where & ": says " & $claims[0] &
                " in part, but src/ names none of " & names.join(", ")
          if claims.len > 0:
            # A name src/ declares too: the search cannot tell whose it calls.
            for n in names:
              if distinctive(n) and usedBySource(n, used) and normName(n) in declared and
                  normName(n) notin known:
                result.problems.add where & ": says " & $claims[0] & " for `" & n &
                  "`, but src/ declares a `" & n & "` of its own, so a text search cannot " &
                  "tell which src/ calls (rename the viewer's, or say why in KnownHomonyms)"
          if claims.len > 0 and not row.next and ui.labels.len > 0:
            # The windows and menu items a built row names exist (but for
            # those its status says are planned, "planned (the processing window)").
            for w in windowsNamed(row.feature):
              if w notin ui.windows and (w & " window").toLowerAscii notin
                  row.status.toLowerAscii:
                result.problems.add where & ": says " & row.status & " and names the " & w &
                  " window, which src/ has not"
            for path in menuPaths(row.feature):
              let bad = menuPathKnown(path, ui)
              if bad.len > 0:
                result.problems.add where & ": says " & row.status & " and names the menu " &
                  "item \"" & path.join(" → ") & "\", but src/ has no \"" & bad & "\""
          if not row.next:
            for n in names:
              let s = rowNameStatus(row, n, used)
              if n notin result.nameStatus[li] or s < result.nameStatus[li][n]:
                result.nameStatus[li][n] = s
    # A distinctive name src/ calls whose rows say it is not built.
    for n, st in result.nameStatus[li]:
      if st > stInternal and distinctive(n) and normName(n) in src and normName(n) notin known:
        result.problems.add lib.name & ": `" & n & "` is named in src/, but its rows say " &
          $st & " (make a row built or internal, or say in KnownHomonyms what src/ names by it)"
    var missing: seq[string]
    for e in lib.exports:
      let covered = e.name in named or e.kind == "enum value" and e.owner in named
      if not covered and e.name notin missing:
        missing.add e.name
        result.problems.add lib.name & ": " & e.kind & " `" & e.name & "` (" & e.module &
          (if e.owner.len > 0: ", " & e.owner else: "") & ") is named in no row"
    if hasNext:
      var old = initHashSet[string]()
      for e in lib.exports: old.incl e.name
      var reported = initHashSet[string]()
      for e in nextLib.exports:
        if e.name notin old and e.name notin reported:
          let covered = e.name in nextNamed or
            e.kind == "enum value" and e.owner in nextNamed and e.owner notin old
          if not covered:
            reported.incl e.name
            result.problems.add lib.name & "'s next release (" & nextLib.source & "): new " &
              e.kind & " `" & e.name & "` (" & e.module &
              (if e.owner.len > 0: ", " & e.owner else: "") & ") is named in no row"

# ------------------------------------------------------------ the summary --

func toPlanRemark(status: string): string =
  ## What the `to plan` part of `status` says, its priority left out: "a
  ## selection per outcome" of `to plan (priority 9: a selection per outcome)`.
  for part in statusParts(status):
    let p = part.strip
    if p.startsWith($stToPlan) and '(' in p and p.endsWith(")"):
      var r = p[p.find('(') + 1 .. ^2].strip
      if r.startsWith("priority "):
        var j = "priority ".len
        while j < r.len and r[j] in Digits: inc j
        r = r[j .. ^1].strip(chars = {' ', ':', ','})
      return r

proc summary*(page: Page; libs: openArray[Library]; cov: Coverage): string =
  ## The page's summary: counts per library, then what is still to plan.
  var counts: array[2, array[Status, int]] # names
  var caps: array[2, array[Status, int]] # capabilities
  var partly: array[2, int]
  var nextCaps: array[2, array[Status, int]]
  var versions: array[2, string]
  var total: array[2, int]
  for lib in libs:
    let li = libIndex(lib.name)
    versions[li] = lib.version
    for n in lib.names:
      inc total[li]
      if n in cov.nameStatus[li]: inc counts[li][cov.nameStatus[li][n]]
  for row in page.rows:
    if row.statuses.len > 0:
      let li = libIndex(row.lib)
      if row.next:
        inc nextCaps[li][row.statuses[0]]
      else:
        inc caps[li][row.statuses[0]]
        if row.statuses[0] == stBuilt and
            row.statuses.anyIt(it in {stPlanned, stToPlan}): inc partly[li]
  var t = "| Status | parseSEG " & versions[0] & ": capabilities | names | processSEG " &
    versions[1] & ": capabilities | names |\n|---|---:|---:|---:|---:|\n"
  for s in Status:
    var c0 = $caps[0][s]
    var c1 = $caps[1][s]
    if s == stBuilt:
      c0.add " (" & $partly[0] & " in part)"
      c1.add " (" & $partly[1] & " in part)"
    t.add "| `" & $s & "` | " & c0 & " | " & $counts[0][s] & " | " & c1 & " | " &
      $counts[1][s] & " |\n"
  var capTotal: array[2, int]
  for li in 0 .. 1:
    for s in Status: capTotal[li] += caps[li][s]
  t.add "| all | " & $capTotal[0] & " | " & $total[0] & " | " & $capTotal[1] & " | " &
    $total[1] & " |\n"
  result = SummaryStart & "\n\nCapabilities are the rows below, each counted by the first part " &
    "of its status (\"in part\": built, with a part still planned or to plan). Names are the " &
    "names each library exports, enum values not counted, each at the most advanced status " &
    "of the rows that name it.\n\n" & t & "\n"
  var nextLine = ""
  for li in 0 .. 1:
    var all = 0
    var parts: seq[string]
    for s in Status:
      all += nextCaps[li][s]
      if nextCaps[li][s] > 0: parts.add $nextCaps[li][s] & " " & $s
    if all > 0:
      if nextLine.len > 0: nextLine.add "; "
      nextLine.add Libraries[li] & ": " & $all & " capabilities (" & parts.join(", ") & ")"
  if nextLine.len > 0:
    result.add "In the next library release (below): " & nextLine & ".\n\n"
  var todo: seq[Row]
  for row in page.rows:
    if stToPlan in row.statuses: todo.add row
  todo.sort(proc (a, b: Row): int =
    cmp((a.priority == 0, a.priority, a.line), (b.priority == 0, b.priority, b.line)))
  result.add "**Still to plan, most useful to field QC first** (the rows whose status says " &
    "`to plan`, by their priority):\n\n"
  var i = 0
  for row in todo:
    inc i
    let what = toPlanRemark(row.status)
    result.add $i & ". **" & row.capability & "** (" & row.lib &
      (if row.next: ", next release" else: "") & (if row.group.len > 0: ", " & row.group else: "") &
      "): " & (if what.len > 0: what else: row.feature) & "\n"
  if todo.len == 0: result.add "Nothing.\n"
  result.add "\n" & SummaryEnd

func currentSummary*(text: string): string =
  ## The summary the page holds, marks included; "" when it has none.
  let a = text.find(SummaryStart)
  let b = text.find(SummaryEnd)
  if a < 0 or b < a: "" else: text[a ..< b + SummaryEnd.len]

func withSummary*(text, summary: string): string =
  let a = text.find(SummaryStart)
  let b = text.find(SummaryEnd)
  if a < 0 or b < a: text
  else: text[0 ..< a] & summary & text[b + SummaryEnd.len .. ^1]

# --------------------------------------------------------------- together --

type Result* = object
  libs*, next*: seq[Library]
  page*: Page
  coverage*: Coverage
  summary*: string ## What the page's summary must be.
  calledNotBuilt*: seq[string]
    ## "library: name (status)" for each name the viewer's source names whose
    ## rows say planned, to plan or not applicable: a row that may be stale (or
    ## a name the viewer uses of its own, a text search cannot tell).

proc run*(root: string; work = ""): Result =
  ## Reads the libraries, the page and the viewer's source of the repository
  ## at `root`, and checks the page. `work` is a scratch folder (made, then
  ## removed; a temporary one by default).
  let dir = if work.len > 0: work else: getTempDir() / "viewseg-coverage-" & $getCurrentProcessId()
  removeDir(dir)
  createDir(dir)
  try:
    let srcs = librarySources(root, dir)
    let libs = readLibraries(srcs, nimCfgPaths(root), dir / "doc")
    for i, s in srcs:
      if s.next: result.next.add libs[i] else: result.libs.add libs[i]
    result.page = parsePage(readFile(root / PageFile))
    let src = sourceNames(root / "src")
    result.coverage = check(result.page, result.libs, result.next, src,
      sourceDeclared(root / "src"), uiNames(root / "src" / "viewSEG" / "ui"))
    for (name, _) in KnownHomonyms:
      if normName(name) notin src:
        result.coverage.problems.add "tools/coverage.nim: KnownHomonyms lists `" & name &
          "`, which src/ no longer names"
    for lib in result.libs:
      for name, st in result.coverage.nameStatus[libIndex(lib.name)]:
        if st > stInternal and not isOperator(name) and normName(name) in src:
          result.calledNotBuilt.add lib.name & ": " & name & " (" & $st & ")"
    result.calledNotBuilt.sort()
    result.summary = summary(result.page, result.libs, result.coverage)
    if currentSummary(result.page.text) != result.summary:
      result.coverage.problems.add PageFile & ": the summary is not the tables' (run `nim coverage`)"
  finally:
    removeDir(dir)

when isMainModule:
  import std/parseopt

  proc apiMissing(root: string; lib: Library): seq[string] =
    ## The exported names `docs/api.md` does not mention as a whole word.
    let path = root / "docs" / "api.md"
    if fileExists(path):
      let words = toHashSet(identsIn(readFile(path)))
      let text = readFile(path)
      for e in lib.exports:
        let found = if isOperator(e.name): e.name in text else: e.name in words
        if not found and e.name notin result: result.add e.name

  proc main() =
    var cmd = ""
    var target = ""
    var useNext = false
    var parseDir = ""
    let root = getCurrentDir()
    for kind, key, val in getopt():
      case kind
      of cmdArgument:
        if cmd.len == 0: cmd = key else: target = key
      of cmdLongOption, cmdShortOption:
        case key
        of "next": useNext = true
        of "parseSEG": parseDir = val
        else: quit "coverage: unknown option --" & key
      of cmdEnd: discard
    case cmd
    of "check", "write":
      let r = run(root)
      for l in r.libs:
        echo "coverage: ", l.name, " ", l.version, " (", l.source, "): ", l.names.len,
          " exported names, ", l.enumValueOwners.len, " enum values"
      for l in r.next:
        echo "coverage: next ", l.name, " ", l.version, " (", l.source, "): ", l.names.len,
          " exported names"
      var problems = r.coverage.problems
      if cmd == "write" and currentSummary(r.page.text).len > 0:
        writeFile(root / PageFile, withSummary(r.page.text, r.summary))
        echo "coverage: summary written"
        problems = problems.filterIt(not it.endsWith("(run `nim coverage`)"))
      elif cmd == "write":
        problems.add PageFile & ": no summary marks (" & SummaryStart & ")"
      if r.calledNotBuilt.len > 0:
        echo "coverage: named in src/ but not built or internal on the page (check these rows): ",
          r.calledNotBuilt.join(", ")
      for p in problems: echo "coverage: ", p
      if problems.len > 0:
        quit "coverage: " & $problems.len & " problems", 1
      echo "coverage: ", PageFile, " is complete and true"
    of "exports":
      let dir = getTempDir() / "viewseg-coverage-" & $getCurrentProcessId()
      removeDir(dir)
      createDir(dir)
      try:
        # The library last; a processSEG after the parseSEG it re-exports from.
        var srcs: seq[LibSource]
        if target in Libraries:
          let all = librarySources(root, dir)
          for s in all:
            if s.name == target and s.next == useNext:
              for p in all:
                if p.name == "parseSEG" and p.root == s.parseRoot: srcs.add p
              srcs.add s
          if srcs.len == 0: quit "coverage: no " & target & (if useNext: " in deps/next" else: "")
        elif target.len > 0 and dirExists(target):
          var name = ""
          for f in walkFiles(target / "*.nimble"): name = f.splitFile.name
          if name notin Libraries: quit "coverage: no parseSEG or processSEG in " & target
          var s = LibSource(name: name, root: target, source: target)
          if name == "processSEG":
            s.parseRoot = if parseDir.len > 0: parseDir else: root / "deps" / "parseSEG"
            srcs.add LibSource(name: "parseSEG", root: s.parseRoot, source: s.parseRoot)
          srcs.add s
        else:
          quit "coverage: exports parseSEG|processSEG|<dir>"
        let lib = readLibraries(srcs, nimCfgPaths(root), dir / "doc")[^1]
        echo "# ", lib.name, " ", lib.version, " (", lib.source, "): ", lib.names.len,
          " names, ", lib.enumValueOwners.len, " enum values"
        echo "# name\tkind\tmodule\towner"
        for e in lib.exports:
          echo e.name, "\t", e.kind, "\t", e.module, "\t", e.owner
        let src = srcs[^1].root
        let missing = apiMissing(src, lib)
        echo "# not in docs/api.md: ", missing.len
        for n in missing: echo "#   ", n
      finally:
        removeDir(dir)
    of "uses":
      # Each exported name the viewer's code names, with the files that do.
      let dir = getTempDir() / "viewseg-coverage-" & $getCurrentProcessId()
      removeDir(dir)
      createDir(dir)
      try:
        var srcs: seq[LibSource]
        for s in librarySources(root, dir):
          if not s.next: srcs.add s
        var files: seq[(string, HashSet[string])]
        for path in walkDirRec(root / "src"):
          if path.endsWith(".nim"):
            files.add (path.relativePath(root), codeNames(readFile(path)))
        for lib in readLibraries(srcs, nimCfgPaths(root), dir / "doc"):
          var kinds: Table[string, seq[string]]
          for e in lib.exports:
            if e.name notin kinds: kinds[e.name] = @[]
            if e.kind notin kinds[e.name]: kinds[e.name].add e.kind
          for name, ks in kinds:
            var where: seq[string]
            for (f, names) in files:
              if normName(name) in names: where.add f
            if where.len > 0 or isOperator(name):
              echo lib.name, "\t", name, "\t", ks.join(","), "\t", where.join(" ")
      finally:
        removeDir(dir)
    else:
      quit "coverage: check | write | uses | exports parseSEG|processSEG|<dir> [--next]"

  main()
