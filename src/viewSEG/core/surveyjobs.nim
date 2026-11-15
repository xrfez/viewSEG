## The jobs that fill the survey (`core/survey`): an open file's positions,
## read from its keys, and a survey file read on its own. Both run on the
## interactive lane, report progress, stop at a cancel, and post the layer
## they made (`mkSurvey`); what is wrong in a survey file goes to the log, a
## line each for the first `MaxProblems` problems, then a count.
##
## **SPS files** are read in chunks of `SurveyChunk` bytes, each cut after
## its last line end and read with parseSEG's `parseSps` (the revision and
## the layout the first chunk shows are kept for the rest), so the text in
## memory is one chunk whatever the file's size, with progress and a cancel
## between chunks; the points and relations kept grow with the file's
## records (about 340 bytes a point: an R file of 95 MB and 1.2 million
## stations took about 410 MB). parseSEG cuts a "line" longer than 64 KiB into records and says
## so; a chunk with no line end at all is cut where it ends. A file whose
## chunks stop being SPS (`JunkChunks` in a row with binary bytes in them, or
## mostly lines that are no SPS record: a file that turns into other data)
## is read no further, and the log says from where.
##
## **SEG P1 files** are short (a record per shotpoint): one is read whole,
## up to `MaxP1Bytes`, and a larger one is refused with a message. Their
## grid coordinates are taken with no implied decimals (parseSEG's
## default); the join's own options come with it.
##
## **Text line names** (SPS 1.0, P1: "CLT4960") are made numbers as the
## import's join makes them (parseSEG's `resolveLine`): the line names the
## import maps, else, with its trailing digits on, the digits a name ends
## in; so the map's layer has the stations the join finds.
##
## **Never raises on data:** a file that is not SPS or P1 (`filekinds`), one
## that cannot be read, a named pipe, are refused with a message (the job
## fails); everything else is read as far as it goes.

import std/[options, os, strutils, times]
import parseSEG
import processSEG/qc/record
import filejobs, filekinds, filesystem, inbox, jobs, join, log, session, survey, threads

const
  SurveyChunk* = 4 * 1024 * 1024 ## bytes of an SPS file parsed at a time
  JunkChunks* = 4                ## chunks in a row with no SPS record end the read of a file
  MaxP1Bytes* = 64 * 1024 * 1024 ## a SEG P1 file larger than this is not read
  MaxProblems* = 20              ## problems of one file logged one by one; the rest are counted
  KeysChunk = 65_536             ## traces whose keys are copied at a time
  Card = 80                      ## bytes of a fixed card without a line end

type Problems = object
  ## A file's problems, posted as they come: the first `MaxProblems`, then
  ## a count.
  to: Poster
  job: JobId
  name: string
  told, more: int

proc note(p: var Problems; severity: Severity; text: string; loc = Location()) =
  if p.told < MaxProblems:
    inc p.told
    p.to.post Msg(job: p.job, kind: mkLog, entry: LogEntry(time: getTime(),
      severity: severity, source: p.name, text: text, loc: loc))
  else: inc p.more

proc say(p: Problems; severity: Severity; text: string) =
  ## Posts `text`, past the cap.
  p.to.post Msg(job: p.job, kind: mkLog, entry: LogEntry(time: getTime(), severity: severity,
    source: p.name, text: text))

proc take(p: var Problems; diags: DiagLog; lineBase = -1) =
  ## parseSEG's problems with a part of a file whose first line is line
  ## `lineBase` (from 0) of the file: told by line, counted from 1. With no
  ## `lineBase`, the place parseSEG gives is not a line, and is left out.
  for d in diags:
    var loc = d.loc
    var text = d.msg
    if loc.record >= 0 and lineBase >= 0:
      text = "line " & $(loc.record + lineBase + 1) & ": " & text
    loc.record = -1
    p.note(d.severity, text, loc)

proc append(s: var string; part: openArray[char]) =
  let at = s.len
  s.setLen at + part.len
  if part.len > 0: copyMem(addr s[at], addr part[0], part.len)

proc finish(p: var Problems) =
  if p.more > 0:
    p.say(sevInfo, $p.more & " more problems in " & p.name & " are not listed.")

func roleOf(k: SpsPointKind): PointRole {.inline.} =
  if k == pkSource: prSource else: prReceiver

func pointIndex(i: int): int16 {.inline.} =
  int16(clamp(i, int(low(int16)), int(high(int16))))

proc checkedOpen(path: string; f: var File): FileInfo =
  ## Opens regular file `path` to read; raises `IOError` for anything else
  ## (a named pipe is never opened: it would wait for a writer).
  result = fs.getFileInfo(path)
  if result.kind notin {pcFile, pcLinkToFile} or result.isSpecial:
    raise newException(IOError, "it is not a regular file (a named pipe, a device)")
  if not fs.open(f, path, fmRead): raise newException(IOError, "it cannot be read")

proc blankBinary(text: var string; card: int; bytes: var int): int =
  ## Blanks every line of `text` (every `card` bytes, for cards without line
  ## ends; 0 for lines) that holds a byte no text holds (a NUL, a control
  ## character) or is more than a quarter bytes above 127: binary data is
  ## not read as records. The number of lines blanked; `bytes`, of bytes.
  bytes = 0
  var lo = 0
  while lo < text.len:
    var hi = lo
    var (control, high) = (false, 0)
    let last = if card > 0: min(lo + card, text.len) else: text.len
    while hi < last and (card > 0 or text[hi] notin {'\n', '\r'}):
      let c = text[hi]
      if (c < ' ' and c notin {'\t', '\f'}) or c == '\x7F': control = true
      elif c >= '\x80': inc high
      inc hi
    if control or high * 4 > hi - lo:
      for i in lo ..< hi: text[i] = ' '
      inc result
      bytes += hi - lo
    lo = if card > 0: hi else: hi + 1

func cutAt(text: string; layout: TextLayout): int =
  ## Where a chunk of a file is cut: after its last line end (a whole number
  ## of 80-byte cards for fixed cards); the whole chunk when it has none.
  if layout in {tlFixed80, tlEbcdic80}: return text.len - text.len mod Card
  result = text.rfind('\n')
  if result < 0: result = text.rfind('\r')
  result = if result < 0: text.len else: result + 1

proc eachSpsPart(path: string; f: File; size: int64; ctx: JobContext; p: var Problems;
    onPart: proc (part: SpsFile)) =
  ## Reads the SPS file `path` (open as `f`, `size` bytes) a chunk at a time
  ## and hands each chunk's records to `onPart`, as parseSEG's `parseSps` reads
  ## them (the first chunk's revision and layout kept for the rest); its
  ## problems go to `p` by line.
  var opts = SpsOptions(keepRaw: false)
  var buf = newString(SurveyChunk)
  var carry = ""
  var (read, lineBase, junk, binary) = (0'i64, 0, 0, 0)
  var layout = tlLines
  var first = true
  var stopped = -1'i64
  while true:
    let got = fs.readBuffer(f, path, addr buf[0], SurveyChunk)
    read += got
    let eof = got < SurveyChunk
    var text = move carry
    text.append buf.toOpenArray(0, got - 1)
    if first and text.len > 0:
      layout = detectLayout(text.toOpenArray(0, min(text.high, 4095)))
    let cut = if eof: text.len else: cutAt(text, layout)
    carry = text[cut .. ^1]
    text.setLen cut
    if text.len > 0:
      var blankedBytes = 0
      let blanked = text.blankBinary(if layout == tlLines: 0 else: Card, blankedBytes)
      binary += blanked
      let part = parseSps(text, path, opts)
      if first:
        (opts.revision, opts.forceLayout, opts.layout) = (part.revision, true, part.layout)
        first = false
      onPart(part)
      p.take(part.log, lineBase)
      lineBase += part.order.len
      # Mostly binary lines (or bytes: a chunk of binary data with no line
      # end is one line, but many records to parseSEG), or lines that are no
      # SPS record: not SPS.
      var unknown = 0
      for o in part.others:
        if not o.isEmptyOrWhitespace: inc unknown
      if (blanked + unknown) * 2 > part.order.len or blankedBytes * 2 > text.len: inc junk
      else: junk = 0
      if junk >= JunkChunks:
        stopped = read - int64(carry.len)
        break
    if not ctx.progress(read, max(size, read)):
      raise newException(JobCancelledError, "cancelled")
    if eof: break
  # Said whatever was said before: the reader needs to know why the
  # numbers are what they are.
  if binary > 0:
    p.say(sevWarning, (if binary == 1: "1 line of " & p.name & " holds" else: $binary &
      " lines of " & p.name & " hold") & " binary data (bytes no text holds), passed by.")
  if stopped >= 0:
    p.say(sevWarning, p.name & " turns into other data (" &
      $(JunkChunks * SurveyChunk div (1024 * 1024)) & " MiB with no SPS records), so it " &
      "was read up to byte " & $stopped & " only.")

func lineNaming*(opts: JoinOptions): seq[(string, float64)] =
  ## The import's line names, as a survey file's layer is read with them.
  for ln in opts.lineNames: result.add (ln.name, ln.line)

proc builderFor(path: string; kind: FileKind; info: FileInfo;
    lines: JoinOptions): SurveyFileBuilder =
  initSurveyFileBuilder(path, kind, info.size, info.lastWriteTime, lines.lineNaming,
    lines.trailingDigits)

proc readSpsLayer(path: string; kind: FileKind; ctx: JobContext; p: var Problems;
    lines: JoinOptions): SurveyLayer =
  var f: File
  let info = checkedOpen(path, f)
  var b = builderFor(path, kind, info, lines)
  try:
    eachSpsPart(path, f, info.size, ctx, p, proc (part: SpsFile) =
      for q in part.points:
        b.addPoint(roleOf(q.kind), b.lineOf(q.lineName, q.line), q.point,
          pointIndex(q.index), q.easting, q.northing, q.elevation)
      b.addRelations(part))
  finally:
    close(f)
  p.take(b.relationsLog)
  result = b.finish()

proc readWhole(path: string; ctx: JobContext; what: string): (FileInfo, string) =
  ## The text of the file at `path`, read whole up to `MaxP1Bytes` (a SEG P1
  ## file, a CSV table: `what`), with progress and a cancel between pieces.
  var f: File
  let info = checkedOpen(path, f)
  var text: string
  try:
    if info.size > MaxP1Bytes:
      raise newException(IOError, "it is " & $(info.size div (1024 * 1024)) & " MiB, and " &
        what & " of more than " & $(MaxP1Bytes div (1024 * 1024)) & " MiB are not read")
    var piece = newString(1024 * 1024)
    while true:
      let got = fs.readBuffer(f, path, addr piece[0], piece.len)
      text.append piece.toOpenArray(0, got - 1)
      if text.len > MaxP1Bytes: raise newException(IOError, "it grew past " &
        $(MaxP1Bytes div (1024 * 1024)) & " MiB while it was read")
      if not ctx.progress(text.len, max(info.size, text.len)):
        raise newException(JobCancelledError, "cancelled")
      if got < piece.len: break
  finally:
    close(f)
  (info, text)

func p1Number(lineName: string): float64 =
  ## A P1 record's line field as a number; NaN for a text name.
  result = NaN
  if lineName.strip.len > 0:
    try: result = parseFloat(lineName.strip)
    except ValueError: discard

proc readP1Layer(path: string; kind: FileKind; ctx: JobContext; p: var Problems;
    lines: JoinOptions): SurveyLayer =
  let (info, text) = readWhole(path, ctx, "SEG P1 files")
  let file = parseP1(text, path)
  p.take(file.log, 0)
  var b = builderFor(path, kind, info, lines)
  for lf in file.files:
    if lf.format == pfP1:
      for r in lf.records:
        if r.lineName.len > 0 or not r.point.isNaN: # (else a record kept raw)
          # As parseSEG's join: a text line name mapped, or its trailing digits.
          let line = b.lineOf(r.lineName, p1Number(r.lineName))
          # As parseSEG's join: a reshoot code is the point index (blank: any).
          let index = if r.reshoot in {'A' .. 'Z'}: int16(ord(r.reshoot) - ord('A') + 2)
                      else: 0'i16
          b.addPoint(prSource, line, r.point, index, r.easting, r.northing, NaN)
  result = b.finish()

proc readSurveyFile*(path: string; ctx: JobContext; to: Poster;
    lines = JoinOptions()): SurveyLayer =
  ## The layer of survey file `path` (SPS or SEG P1, told from its first
  ## bytes), read on a job, its text line names made numbers with `lines`'
  ## line names and trailing digits (as the import's join makes them); its
  ## problems are posted to the log as they come. Raises `IOError` for a
  ## file that is not a survey file or cannot be read, `JobCancelledError`
  ## at a cancel. Worker-only.
  assertWorkerThread()
  var info: FileInfo
  try: info = fs.getFileInfo(path)
  except OSError: raise newException(IOError, "there is no such file")
  if info.kind notin {pcFile, pcLinkToFile} or info.isSpecial:
    raise newException(IOError, "it is not a regular file (a named pipe, a device)")
  let kind = sniff(path)
  if not kind.isSurvey:
    raise newException(IOError, "it is not an SPS or SEG P1 file")
  var p = Problems(to: to, job: ctx.id, name: path.extractFilename)
  ctx.setPhase "reading the survey file"
  {.cast(gcsafe).}:
    result = if kind == fkP1: readP1Layer(path, kind, ctx, p, lines)
             else: readSpsLayer(path, kind, ctx, p, lines)
  p.finish()

proc surveyWork*(path: string; to: Poster; lines = JoinOptions()): JobWork =
  ## The work of a job that loads survey file `path` (`readSurveyFile`, its
  ## line names as `lines` says) and posts its layer (`mkSurvey`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    var layer = readSurveyFile(path, ctx, to, lines)
    ctx.setPhase "preparing the map"
    layer.withLevels()
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkSurvey, layer: move layer)

proc surveyHeadWork*(file: JoinFile; to: Poster): JobWork =
  ## The work of a job that reads what survey file `file`'s headers say of
  ## its coordinates' unit, from its first `HeadBytes` only (`headUnitOf`),
  ## and posts it (`mkSurveyHead`): an SPS or SEG P1 file told from those
  ## bytes, a CSV table by its kind. A file that cannot be read is posted
  ## with the reason; nothing raises.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var h = SurveyHead(file: file, done: true)
    var f: File
    try:
      let info = checkedOpen(file.path, f)
      var head = newString(int(min(info.size, HeadBytes)))
      var got = 0
      try:
        if head.len > 0: got = fs.readBuffer(f, file.path, addr head[0], head.len)
      finally:
        close(f)
      head.setLen got
      if file.kind != jkCsv:
        let kind = surveyKind(head, file.path.extractFilename, whole = got >= info.size)
        if kind == fkP1: h.file.kind = jkP1
        elif kind.isSurvey: h.file.kind = jkSps
      {.cast(gcsafe).}:
        h.head = headUnitOf(head, h.file.kind, whole = got >= info.size)
    except CatchableError as e:
      h.problem = "its headers cannot be read (" & e.msg.splitLines()[0] & ")"
    discard ctx.progress(1, 1)
    to.post Msg(job: ctx.id, kind: mkSurveyHead, surveyHead: h)

proc openFileWork*(path: string; to: Poster; cache = "";
    cacheBudget = DefaultIndexCacheBudget; whole = false; lines = JoinOptions()): JobWork =
  ## The work of a job that opens what the user named: a survey file is
  ## loaded into the survey (`mkSurvey`, its line names as `lines` says),
  ## anything else opened as a seismic file (`openWork`, `mkOpened`).
  let open = openWork(path, to, cache, cacheBudget, whole)
  let load = surveyWork(path, to, lines)
  result = proc (ctx: JobContext) {.gcsafe.} =
    if sniff(path).isSurvey: load(ctx) else: open(ctx)

proc checkWork*(file: ptr SeismicFile; session: SessionId; gathers: seq[Slice[int]];
    relations: ptr SurveyGeometry; against: string; layer: SurveyLayerId;
    to: Poster; recordMatch = rmAuto; traceMatch = tmAuto): JobWork =
  ## The work of a job that checks each of `gathers` of open file `session`
  ## (`file`) against the X records of a loaded relation file, or of the
  ## survey files it was joined with (`relations`, of layer `layer`,
  ## `NoSurveyLayer` for a join's; named `against`): processSEG's
  ## `recordCompleteness`, from the keys alone, matching records and traces as
  ## `recordMatch` and `traceMatch` say, posted as the stations each record's
  ## X record plans, those with no trace in it, the traces at stations it
  ## does not list and the stations recorded twice (`mkChecked`). Submitted
  ## with the file in `reads`; `relations` is read where it is, never copied,
  ## and the caller keeps it alive and unchanged until the job has finished.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "checking the records"
    var planned, missing, unlisted, duplicates = newSeq[int](gathers.len)
    var revision = 0
    {.cast(gcsafe).}:
      revision = file[].keysRevision
      for i, g in gathers:
        (planned[i], missing[i], unlisted[i], duplicates[i]) = (-1, -1, -1, -1)
        if g.len > 0:
          try:
            let c = relations[].recordCompleteness(file[].rowsOf(g), recordMatch, traceMatch)
            if c.xpsRecord >= 0:
              (planned[i], missing[i], unlisted[i], duplicates[i]) = (c.expected, c.missing,
                c.unlisted, c.duplicates)
          except ValueError:
            discard # no keys: nothing to check against
        if i mod 64 == 0 and not ctx.progress(i, gathers.len):
          raise newException(JobCancelledError, "cancelled")
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkChecked, checkedSession: session, against: against,
      againstLayer: layer, keysRevision: revision, planned: planned, plannedMissing: missing,
      unlisted: unlisted, duplicates: duplicates)

proc positionsWork*(file: ptr SeismicFile; path: string; kind: FileKind; session: SessionId;
    base: int; to: Poster): JobWork =
  ## The work of a job that reads the source and receiver positions of open
  ## file `session` (`file`, at `path`) from its keys and posts its traces
  ## layer (`mkSurvey`). Submitted with the file in `reads`, so the file
  ## stays open while it runs.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the positions"
    let n = file[].len
    var b = initTraceLayerBuilder(path, kind, session, base, n, file[].keysRevision)
    var keys = newSeq[TraceKeys](min(n, KeysChunk))
    var t = 0
    while t < n:
      let m = min(keys.len, n - t)
      {.cast(gcsafe).}:
        file[].traceKeysInto(t ..< t + m, keys.toOpenArray(0, m - 1))
      b.add(keys.toOpenArray(0, m - 1))
      t += m
      if not ctx.progress(t, n): raise newException(JobCancelledError, "cancelled")
    ctx.setPhase "indexing the positions"
    var layer = b.finish()
    ctx.setPhase "preparing the map"
    layer.withLevels()
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkSurvey, layer: move layer)

# ------------------------------------------------------------------ join --

proc lineNamesOf(part: SpsFile; g: SurveyGeometry; names: var seq[string];
    records: var int) =
  ## The line names of `part` that are not numbers and that `g` cannot make
  ## numbers (no mapping, no trailing digits): the first few, and how many
  ## records name one.
  template check(name: string; value: float64) =
    if value.isNaN and name.strip.len > 0 and g.resolveLine(name, NaN).isNone:
      inc records
      if names.len < 5 and name.strip notin names: names.add name.strip
  for q in part.points: check(q.lineName, q.line)
  for r in part.relations:
    check(r.srcLineName, r.srcLine)
    check(r.rcvLineName, r.rcvLine)

const NotedHeaders = ["12", "13", "14", "17", "18", "19", "20", "201"]
  ## the SPS header records said for the join: datum, projection, units

proc joinReadWork*(file: ptr SeismicFile; session: SessionId; files: seq[JoinFile];
    opts: JoinOptions; to: Poster): JobWork =
  ## The work of the first job of a join: reads `files` (SPS with parseSEG's
  ## `addSps` a chunk at a time, SEG P1 with `addP1`, CSV tables with
  ## `addCsv`) into one geometry with `opts`' line names, trailing digits and
  ## components, saying each file's problems in the log; then works out what
  ## joining it to open file `session` (`file`) does (`planJoin`), and posts
  ## both (`mkJoining`). It reads the file's keys only: submitted with the
  ## file in `reads`, while readers go on reading it. Progress and a cancel
  ## between chunks.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var g = new SurveyGeometry
    var names, unresolved, notes: seq[string]
    var (unresolvedRecords, rows, skipped) = (0, 0, 0)
    var plan: JoinPlan
    {.cast(gcsafe).}:
      g[] = initSurveyGeometry()
      g.trailingDigits = opts.trailingDigits
      g.multiComponent = opts.multiComponent
      for ln in opts.lineNames: g[].mapLine(ln.name, ln.line)
      var taken = 0 # of `g.log`: what parseSEG's join said, file by file
      for i, jf in files:
        let name = jf.path.extractFilename
        names.add name
        var p = Problems(to: to, job: ctx.id, name: name)
        ctx.setPhase "reading " & name & (if files.len > 1: " (" & $(i + 1) & " of " &
          $files.len & ")" else: "")
        # What it is, by its first bytes: the dialog's guess (by the name) may be wrong.
        var kind = jf.kind
        var info: FileInfo
        try: info = fs.getFileInfo(jf.path)
        except OSError: raise newException(IOError, "there is no file " & jf.path)
        if info.kind notin {pcFile, pcLinkToFile} or info.isSpecial:
          raise newException(IOError, name & " is not a regular file (a named pipe, a device)")
        if kind != jkCsv:
          let sniffed = sniff(jf.path)
          kind = if sniffed == fkP1: jkP1
                 elif sniffed.isSurvey: jkSps
                 else: raise newException(IOError, name & " is not an SPS or SEG P1 file")
        case kind
        of jkSps:
          var f: File
          let info = checkedOpen(jf.path, f)
          let domain = relationDomainOf(jf.path)
          var first = true
          try:
            eachSpsPart(jf.path, f, info.size, ctx, p, proc (part: SpsFile) =
              if first:
                first = false
                for h in part.headers:
                  let data = h.data.strip.strip(leading = false, chars = {';'}).strip
                  if h.code in NotedHeaders and data.len > 0 and data != "N/A":
                    let note = "H" & h.code & " " & h.description.strip & ": " & data
                    if note notin notes: notes.add note # (every file of a survey says it)
              lineNamesOf(part, g[], unresolved, unresolvedRecords)
              g[].addSps(part, domain))
          finally:
            close(f)
        of jkP1:
          let (_, text) = readWhole(jf.path, ctx, "SEG P1 files")
          let pf = parseP1(text, jf.path)
          p.take(pf.log, 0)
          for lf in pf.files:
            for r in lf.records:
              let numeric = p1Number(r.lineName)
              if r.lineName.strip.len > 0 and numeric.isNaN and
                  g[].resolveLine(r.lineName, NaN).isNone:
                inc unresolvedRecords
                if unresolved.len < 5 and r.lineName.strip notin unresolved:
                  unresolved.add r.lineName.strip
          g[].addP1(pf)
        of jkCsv:
          let (_, text) = readWhole(jf.path, ctx, "CSV tables")
          var problems: seq[string]
          rows += g[].addCsv(text, name, jf.role, problems, skipped)
          for t in problems: p.note(sevWarning, t)
        # parseSEG's join's own words, but for the text line names, said once
        # for all (`whyUnmatched`)
        var told: DiagLog
        template said: untyped = g[].log
        for k in taken ..< said.len:
          if "has no mapping" notin said[k].msg: told.add said[k]
        taken = said.len
        p.take(told)
        p.finish()
      ctx.setPhase "matching the traces"
      plan = planJoin(file, g[], opts, proc (done, total: int): bool =
        ctx.progress(done, total))
    if plan.traces != file[].len: raise newException(JobCancelledError, "cancelled")
    var survey = surveyOf(g[], names)
    (survey.unresolved, survey.unresolvedRecords, survey.notes) =
      (unresolved, unresolvedRecords, notes)
    (survey.csvRows, survey.csvSkipped) = (rows, skipped)
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkJoining, planSession: session, geometry: move g,
      plan: move plan, joinSurvey: move survey)

proc joinApplyWork*(file: ptr SeismicFile; path: string; session: SessionId;
    g: ptr SurveyGeometry; replace, tableOnly: bool; holds: HoldRelease; to: Poster): JobWork =
  ## The work of the second job of a join: joins `g` to open file `session`
  ## (`file`, at `path`) in memory (parseSEG's `applySurvey`, or
  ## `applyGeometry` of `g`'s table alone when no SPS or P1 file is in it),
  ## replacing the headers' coordinates when `replace`, and posts what it
  ## did (`mkJoined`). Submitted with the file in `exclusive`, so it starts
  ## only once no job reads the file and no reader holds it; it says how many
  ## holds it found (none), and refuses to join when there are any. A cancel
  ## that comes before it joins stops it; the join itself is one step, which
  ## no cancel stops (`commit`): it reads no file, and a join abandoned
  ## halfway would be said cancelled while it still changed the keys.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    let held = holds.held(path)
    if held > 0:
      raise newException(IOError, "a reader still reads the file, so its traces were not " &
        "matched")
    if not ctx.commit(): raise newException(JobCancelledError, "cancelled")
    ctx.setPhase "matching" # the step: `g` and the file's keys are read and changed from here
    var stats: JoinStats
    var (changed, revision) = (0, 0)
    {.cast(gcsafe).}:
      changed = if tableOnly: file[].applyGeometry(g[].table, replace)
                else: file[].applySurvey(g[], stats, replace)
      revision = file[].keysRevision
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkJoined, joinedSession: session, stats: stats,
      changed: changed, joinedRevision: revision, heldAtJoin: held)

proc readGeometry*(paths: openArray[string]; ctx: JobContext; to: Poster): SurveyGeometry =
  ## The survey files `paths` read again into one parseSEG geometry, on a
  ## job (SPS a chunk at a time with `addSps`, each file's X records in the
  ## domain its name gives; SEG P1 whole with `addP1`), quietly: they were
  ## loaded, and what is wrong with them was said then. A file that is no
  ## longer a survey file, or cannot be read, raises `IOError`;
  ## `JobCancelledError` at a cancel. Worker-only.
  assertWorkerThread()
  result = initSurveyGeometry()
  for path in paths:
    # Quiet: told as many problems as are told, so none is posted again.
    var p = Problems(to: to, job: ctx.id, name: path.extractFilename, told: MaxProblems)
    ctx.setPhase "reading " & p.name
    let kind = sniff(path)
    {.cast(gcsafe).}:
      if kind == fkP1:
        let (_, text) = readWhole(path, ctx, "SEG P1 files")
        result.addP1(parseP1(text, path))
      elif kind.isSurvey:
        var f: File
        let info = checkedOpen(path, f)
        let domain = relationDomainOf(path)
        var g = addr result
        try:
          eachSpsPart(path, f, info.size, ctx, p, proc (part: SpsFile) =
            g[].addSps(part, domain))
        finally:
          close(f)
      else:
        raise newException(IOError, p.name & " is no longer an SPS or SEG P1 file")
