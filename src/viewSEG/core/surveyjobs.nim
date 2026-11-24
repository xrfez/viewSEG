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

import std/[cpuinfo, locks, options, os, strutils, times]
import parseSEG
import processSEG/qc/record
import filejobs, filekinds, filesystem, inbox, jobs, join, log, session, signatures, stationmoves,
  survey, threads

const
  SurveyChunk* = 4 * 1024 * 1024 ## bytes of an SPS file parsed at a time
  ParseAtOnce* = 8
    ## at most this many workers parse an SPS file's chunks, each on a thread
    ## (one fewer than the cores, at least one)
  JunkChunks* = 4 ## chunks in a row with no SPS record end the read of a file
  MaxP1Bytes* = 64 * 1024 * 1024 ## a SEG P1 file larger than this is not read
  MaxProblems* = 20 ## problems of one file logged one by one; the rest are counted
  KeysChunk = 65_536 ## traces whose keys are copied at a time
  Card = 80 ## bytes of a fixed card without a line end

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

func relationsIn(size: int64): int {.inline.} =
  ## About how many records an SPS file of `size` bytes holds (80 columns
  ## and a line end).
  int(size div 81)

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

type
  Chunk = object
    ## A chunk of an SPS file and its records, parsed on a thread of its own.
    text, path: string
    opts: SpsOptions
    card: int      ## 80 for cards without line ends, else 0 (`blankBinary`)
    until: int64   ## the file's bytes read up to the end of this chunk
    part: SpsFile
    blanked, blankedBytes: int
    failed: string ## why it could not be parsed; "" when it was

  ChunkReader = object
    ## Cuts an SPS file into chunks after their last line ends.
    path: string
    f: File
    buf, carry: string
    read: int64
    layout: TextLayout
    eof, first: bool

proc parseChunk(c: ptr Chunk) {.thread.} =
  ## Blanks the binary lines of chunk `c` and parses it (on a thread of its
  ## own, or the job's).
  try:
    {.cast(gcsafe).}:
      c.blanked = c.text.blankBinary(c.card, c.blankedBytes)
      c.part = parseSps(c.text, c.path, c.opts)
  except CatchableError as e:
    c.failed = e.msg
  clearCycleRoots()

type
  ParserState = enum
    psIdle   ## waiting for a chunk
    psParse  ## given one
    psParsed ## done: the reader takes it
    psTaken  ## the reader has it
    psQuit   ## to end

  Parser = object
    ## A worker that parses the chunks it is given, one at a time.
    lock: Lock
    cond: Cond
    state: ParserState
    chunk: Chunk

proc parse(w: ptr Parser) {.thread.} =
  ## A worker's loop: parses each chunk it is given, in its place, until it
  ## is told to end. It lives as long as the read and frees the records it
  ## made itself, before it parses the next chunk: memory freed by another
  ## thread than the one that took it (a thread per chunk, or the reader
  ## freeing the records) stayed with the program, which held three times
  ## what it read.
  while true:
    withLock w.lock:
      while w.state notin {psParse, psQuit}: w.cond.wait(w.lock)
      if w.state == psQuit:
        w.chunk.part = SpsFile()
        return
    (w.chunk.part, w.chunk.failed) = (SpsFile(), "")
    parseChunk(addr w.chunk)
    withLock w.lock:
      if w.state == psQuit: # (told meanwhile: the reader stopped)
        w.chunk.part = SpsFile()
        return
      w.state = psParsed
      w.cond.signal()

proc next(r: var ChunkReader; opts: SpsOptions; c: var Chunk): bool =
  ## The next chunk of the file, cut after its last line end (whole cards);
  ## false at the end of the file.
  if r.eof: return false
  let got = fs.readBuffer(r.f, r.path, addr r.buf[0], SurveyChunk)
  r.read += got
  r.eof = got < SurveyChunk
  var text = move r.carry
  text.append r.buf.toOpenArray(0, got - 1)
  if r.first and text.len > 0:
    r.layout = detectLayout(text.toOpenArray(0, min(text.high, 4095)))
    r.first = false
  let cut = if r.eof: text.len else: cutAt(text, r.layout)
  r.carry = text[cut .. ^1]
  text.setLen cut
  c = Chunk(text: move text, path: r.path, opts: opts, until: r.read - int64(r.carry.len),
    card: (if r.layout == tlLines: 0 else: Card))
  true

proc eachSpsPart(path: string; f: File; size: int64; ctx: JobContext; p: var Problems;
    onPart: proc (part: var SpsFile)) =
  ## Reads the SPS file `path` (open as `f`, `size` bytes) a chunk at a time
  ## and hands each chunk's records to `onPart`, in the file's order, as
  ## parseSEG's `parseSps` reads them (the first chunk's revision and layout
  ## kept for the rest; the text of numeric line and point fields left out,
  ## where parseSEG can); its problems go to `p` by line. The chunks after
  ## the first are parsed by `ParseAtOnce` workers while those before them
  ## are handed on: the parse is most of a read.
  var opts = SpsOptions(keepRaw: false)
  when compiles(SpsOptions(keepNames: false)): opts.keepNames = false
  var r = ChunkReader(path: path, f: f, buf: newString(SurveyChunk), first: true)
  var (lineBase, junk, binary) = (0, 0, 0)
  var stopped = -1'i64
  proc take(c: var Chunk; ctx: JobContext; p: var Problems): bool =
    # Hands chunk `c` on; false once the file turns into other data.
    if c.failed.len > 0: raise newException(IOError, "it cannot be read (" & c.failed & ")")
    result = true
    if c.text.len > 0:
      binary += c.blanked
      onPart(c.part)
      p.take(c.part.log, lineBase)
      lineBase += c.part.order.len
      # Mostly binary lines (or bytes: a chunk of binary data with no line
      # end is one line, but many records to parseSEG), or lines that are no
      # SPS record: not SPS.
      var unknown = 0
      for o in c.part.others:
        if not o.isEmptyOrWhitespace: inc unknown
      if (c.blanked + unknown) * 2 > c.part.order.len or c.blankedBytes * 2 > c.text.len:
        inc junk
      else: junk = 0
      if junk >= JunkChunks:
        stopped = c.until
        result = false
    if not ctx.progress(c.until, max(size, c.until)):
      raise newException(JobCancelledError, "cancelled")
  # The first chunk alone: its revision and layout are read for the rest.
  var c: Chunk
  var going = r.next(opts, c)
  if going:
    parseChunk(addr c)
    if c.text.len > 0:
      (opts.revision, opts.forceLayout, opts.layout) = (c.part.revision, true, c.part.layout)
    going = c.take(ctx, p)
    c = Chunk()
  # Then each next chunk parsed by one of the workers while those before it
  # are handed on, in order: chunk i by worker i mod `parsers`.
  let parsers = clamp(countProcessors() - 1, 1, ParseAtOnce)
  var workers: array[ParseAtOnce, Parser]
  var threads: array[ParseAtOnce, Thread[ptr Parser]]
  var started = 0
  try:
    for w in workers.mitems:
      initLock w.lock
      initCond w.cond
    var given = 0 # chunks given to the workers
    proc give(w: var Parser): bool =
      # The next chunk's text to worker `w` (the text is this thread's to
      # free, the records the worker's).
      var c: Chunk
      result = r.next(opts, c)
      if result:
        withLock w.lock:
          (w.chunk.text, w.chunk.until, w.chunk.card) = (move c.text, c.until, c.card)
          if w.chunk.path.len == 0: (w.chunk.path, w.chunk.opts) = (c.path, c.opts)
          w.state = psParse
          w.cond.signal()
        inc given
    while started < parsers and going and workers[started].give():
      createThread(threads[started], parse, addr workers[started])
      inc started
    var taken = 0
    while going and taken < given:
      let k = taken mod parsers
      template w: untyped = workers[k]
      withLock w.lock:
        while w.state != psParsed: w.cond.wait(w.lock)
        w.state = psTaken
      inc taken
      going = w.chunk.take(ctx, p) # read where it is: its records stay the worker's
      w.chunk.text = ""
      if going: discard w.give()
  finally:
    for i in 0 ..< started:
      withLock workers[i].lock:
        workers[i].state = psQuit
        workers[i].cond.signal()
    for i in 0 ..< started: joinThread(threads[i])
    for w in workers.mitems:
      deinitCond w.cond
      deinitLock w.lock
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
  var first = true
  try:
    eachSpsPart(path, f, info.size, ctx, p, proc (part: var SpsFile) =
      if first:
        first = false
        if part.relations.len * 2 > part.order.len: # an X file: room for its records
          b.reserveRelations(relationsIn(info.size), relationDomainOf(path))
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

proc p1Layer(path: string; kind: FileKind; info: FileInfo; file: P1File;
    lines: JoinOptions): SurveyLayer =
  ## The layer of SEG P1 file `path`, read as `file`.
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

proc readP1Layer(path: string; kind: FileKind; ctx: JobContext; p: var Problems;
    lines: JoinOptions): SurveyLayer =
  let (info, text) = readWhole(path, ctx, "SEG P1 files")
  let file = parseP1(text, path)
  p.take(file.log, 0)
  p1Layer(path, kind, info, file, lines)

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
    cacheBudget = DefaultIndexCacheBudget; whole = false; lines = JoinOptions();
    choice = OpenChoice(); pair = SignaturePair()): JobWork =
  ## The work of a job that opens what the user named: a survey file is
  ## loaded into the survey (`mkSurvey`, its line names as `lines` says), a
  ## vibrator controller's signature file decoded in memory (`signatures`:
  ## nothing is written, no cache), anything else opened as a seismic file
  ## (`openWork`, `mkOpened`) with the options `choice`. A file no kind claims
  ## that has words of its own (empty, a `.vib` of another kind) is refused
  ## in them.
  let open = openWork(path, to, cache, cacheBudget, whole, choice)
  let load = surveyWork(path, to, lines)
  let signature = openSignatureWork(path, to, choice.signature, pair)
  result = proc (ctx: JobContext) {.gcsafe.} =
    let kind = sniff(path)
    if kind in SignatureFileKinds:
      signature(ctx) # (whatever the choice says: a signature file is not read as SEG-Y or SEG-D)
    elif choice.standard != scDetect:
      open(ctx)
    elif kind.isSurvey: load(ctx)
    elif kind == fkUnknown:
      let why = refusalOf(path)
      if why.len > 0: raise newException(SignatureError, why)
      open(ctx)
    else: open(ctx)

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
            # an X record matched by file number alone, of another source than the
            # header's, is no basis for a check
            if c.xpsRecord >= 0 and not (recordMatch == rmAuto and
                c.recordMatch == rmFieldRecord and c.hasSource and c.sourceMismatch):
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

func headOf(text: string): string {.inline.} =
  ## The start of a file's text read whole: what its headers are read from.
  text[0 ..< min(text.len, HeadBytes)]

proc newRelations(opts: JoinOptions): ref SurveyGeometry =
  ## An empty geometry for the relation records of an import's files, with
  ## its line names, trailing digits and components.
  result = new SurveyGeometry
  {.cast(gcsafe).}:
    result[] = initSurveyGeometry()
    result.trailingDigits = opts.trailingDigits
    result.multiComponent = opts.multiComponent
    for ln in opts.lineNames: result[].mapLine(ln.name, ln.line)

proc reserveIn(g: var SurveyGeometry; records: int; domain: RelationDomain) {.inline.} =
  ## Room for `records` more relation records in `g`, where parseSEG can.
  when compiles(g.reserveRelations(records, domain)): g.reserveRelations(records, domain)

proc relationsOnly(g: var SurveyGeometry; part: var SpsFile; domain: RelationDomain) =
  ## `addSps` of `part`'s relation records alone (its points are out of it
  ## meanwhile, not copied).
  var points = move part.points
  try: g.addSps(part, domain)
  finally: part.points = move points

proc pointsOnly(g: var SurveyGeometry; part: var SpsFile) =
  ## `addSps` of `part`'s points (and headers) alone.
  var relations = move part.relations
  try: g.addSps(part)
  finally: part.relations = move relations

proc noteHeaders(part: SpsFile; path: string; role: CsvRole; heads: var seq[SurveyHead];
    notes: var seq[string]) =
  ## What the header records of an SPS file (its first chunk, `part`) say of
  ## its unit, and of the survey's datum and projection.
  heads.add SurveyHead(file: JoinFile(path: path, kind: jkSps, role: role), done: true,
    head: headUnitOf(part.gridUnit))
  for h in part.headers:
    let data = h.data.strip.strip(leading = false, chars = {';'}).strip
    if h.code in NotedHeaders and data.len > 0 and data != "N/A":
      let note = "H" & h.code & " " & h.description.strip & ": " & data
      if note notin notes: notes.add note # (every file of a survey says it)

proc readHead(path: string): SpsFile =
  ## The records of the first `HeadBytes` of SPS file `path` (its header
  ## records), up to its last line end there.
  var f: File
  let info = checkedOpen(path, f)
  var head = newString(int(min(info.size, HeadBytes)))
  var got = 0
  try:
    if head.len > 0: got = fs.readBuffer(f, path, addr head[0], head.len)
  finally:
    close(f)
  head.setLen got
  if got < info.size: head.setLen cutAt(head, tlLines)
  {.cast(gcsafe).}:
    result = parseSps(head, path, SpsOptions(keepRaw: false))

proc postLayer(layer: sink SurveyLayer; ctx: JobContext; to: Poster) =
  ## A survey file's layer made by the import, with its map's levels, posted.
  var l = layer
  l.withLevels()
  clearCycleRoots()
  to.post Msg(job: ctx.id, kind: mkSurvey, layer: move l)

proc joinReadWork*(file: ptr SeismicFile; session: SessionId; files: seq[JoinFile];
    opts: JoinOptions; to: Poster; layers: seq[bool] = @[];
    reuse: seq[ptr SurveyGeometry] = @[]): JobWork =
  ## The work of the first job of a join: reads `files` (SPS with parseSEG's
  ## `addSps` a chunk at a time, SEG P1 with `addP1`, CSV tables with
  ## `addCsv`) into one geometry with `opts`' line names, trailing digits and
  ## components, saying each file's problems in the log; then works out what
  ## joining it to open file `session` (`file`) does (`planJoin`), and posts
  ## both (`mkJoining`). It reads the file's keys only: submitted with the
  ## file in `reads`, while readers go on reading it. Progress and a cancel
  ## between chunks.
  ##
  ## **Each survey file is read once.** The file whose `layers` entry is
  ## true has its map layer made from the same records and posted
  ## (`mkSurvey`) as soon as it is read, so the map shows the points while
  ## the rest is read. With `SharedRelations` (and one component a station)
  ## the relation records are kept apart from the stations: those of a
  ## relation file the map has loaded already (`reuse`, its layer's, read
  ## where they are and kept alive by the caller until the join ends) are
  ## not read again, and those read here are its new layer's own, posted
  ## with the plan (`mkJoining.relations`, after the layer): one copy in
  ## memory, which the map and the join share. Two relation files are read
  ## once more into one geometry for the join.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var g = new SurveyGeometry
    var names, unresolved, notes: seq[string] = @[]
    var heads: seq[SurveyHead] = @[] # what each file says of its unit, read here
    var (unresolvedRecords, rows, skipped) = (0, 0, 0)
    var plan: JoinPlan
    let share = SharedRelations and not opts.multiComponent
    # Where the relation records are, per file that has some (with `share`):
    # a loaded layer's (`held`), or those read here (`own`, the new layer's
    # when it makes one: `layer` is then its index in `kept`).
    type Source = tuple[file: int; held: ptr SurveyGeometry; own: ref SurveyGeometry;
      layer: int]
    var sources: seq[Source] = @[]
    var kept: seq[SurveyLayer] = @[] # layers whose relations may be the join's: posted last
    var keptFor: seq[int] = @[]
    var rel: ref SurveyGeometry = nil # the join's relation records, when kept apart
    var relHeld: ptr SurveyGeometry = nil
    var reusedAt = -1
    {.cast(gcsafe).}:
      g[] = initSurveyGeometry()
      g.trailingDigits = opts.trailingDigits
      g.multiComponent = opts.multiComponent
      for ln in opts.lineNames: g[].mapLine(ln.name, ln.line)
      var taken = 0 # of `g.log`: what parseSEG's join said, file by file
      template sayJoin(p: var Problems; said: DiagLog; start: int) =
        # parseSEG's join's own words, but for the text line names, said once
        # for all (`whyUnmatched`)
        var told: DiagLog
        for k in start ..< said.len:
          if "has no mapping" notin said[k].msg: told.add said[k]
        p.take(told)
      for i, jf in files:
        let name = jf.path.extractFilename
        names.add name
        let wantLayer = i < layers.len and layers[i]
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
        var sniffed = fkUnknown
        if kind != jkCsv:
          sniffed = sniff(jf.path)
          kind = if sniffed == fkP1: jkP1
                 elif sniffed.isSurvey: jkSps
                 else: raise newException(IOError, name & " is not an SPS or SEG P1 file")
        case kind
        of jkSps:
          if share and i < reuse.len and not reuse[i].isNil:
            # On the map already, as it is now: its relations are used where
            # they are, its headers read for their unit.
            readHead(jf.path).noteHeaders(jf.path, jf.role, heads, notes)
            sources.add (i, reuse[i], nil, -1)
          else:
            var f: File
            let info = checkedOpen(jf.path, f)
            let domain = relationDomainOf(jf.path)
            var b = builderFor(jf.path, sniffed, info, opts)
            var own: ref SurveyGeometry = nil # the relations read here, with `share`
            var first = true
            try:
              eachSpsPart(jf.path, f, info.size, ctx, p, proc (part: var SpsFile) =
                if first:
                  first = false
                  part.noteHeaders(jf.path, jf.role, heads, notes)
                  if part.relations.len * 2 > part.order.len: # an X file: room for its records
                    let n = relationsIn(info.size)
                    if wantLayer: b.reserveRelations(n, domain)
                    if not share: g[].reserveIn(n, domain)
                    elif not wantLayer:
                      own = newRelations(opts)
                      own[].reserveIn(n, domain)
                lineNamesOf(part, g[], unresolved, unresolvedRecords)
                if wantLayer:
                  for q in part.points:
                    b.addPoint(roleOf(q.kind), b.lineOf(q.lineName, q.line), q.point,
                      pointIndex(q.index), q.easting, q.northing, q.elevation)
                if not share:
                  if wantLayer: b.addRelations(part)
                  g[].addSps(part, domain)
                else:
                  g[].pointsOnly(part)
                  if part.relations.len > 0:
                    if wantLayer: b.addRelations(part)
                    else:
                      if own.isNil: own = newRelations(opts)
                      own[].relationsOnly(part, domain))
            finally:
              close(f)
            if wantLayer:
              p.sayJoin(b.relationsLog, 0)
              var layer = b.finish()
              if share and layer.relationRuns > 0:
                sources.add (i, nil, layer.relations, kept.len)
                kept.add move layer
                keptFor.add i
              else:
                ctx.setPhase "preparing the map: " & name
                postLayer(move layer, ctx, to)
            elif not own.isNil:
              p.sayJoin(own[].log, 0)
              sources.add (i, nil, own, -1)
        of jkP1:
          let (info, text) = readWhole(jf.path, ctx, "SEG P1 files")
          heads.add SurveyHead(file: JoinFile(path: jf.path, kind: jkP1), done: true,
            head: headUnitOf(text.headOf, jkP1, whole = text.len <= HeadBytes))
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
          if wantLayer:
            ctx.setPhase "preparing the map: " & name
            postLayer(p1Layer(jf.path, sniffed, info, pf, opts), ctx, to)
        of jkCsv:
          let (_, text) = readWhole(jf.path, ctx, "CSV tables")
          heads.add SurveyHead(file: jf, done: true,
            head: headUnitOf(text.headOf, jkCsv, whole = text.len <= HeadBytes))
          var problems: seq[string] = @[]
          rows += g[].addCsv(text, name, jf.role, problems, skipped)
          for t in problems: p.note(sevWarning, t)
        p.sayJoin(g[].log, taken)
        taken = g[].log.len
        p.finish()
      # The join's relations: the one file's where they are, or every
      # relation file's read once more into one geometry.
      if sources.len == 1:
        if sources[0].held.isNil: rel = sources[0].own
        else: (relHeld, reusedAt) = (sources[0].held, sources[0].file)
      elif sources.len > 1:
        rel = newRelations(opts)
        for s in sources:
          let path = files[s.file].path
          ctx.setPhase "reading the relations of " & path.extractFilename & " again"
          var f: File
          let info = checkedOpen(path, f)
          var quiet = Problems(to: to, job: ctx.id, name: path.extractFilename,
            told: MaxProblems) # (said already)
          try:
            eachSpsPart(path, f, info.size, ctx, quiet, proc (part: var SpsFile) =
              rel[].relationsOnly(part, relationDomainOf(path)))
          finally:
            close(f)
      let relations = if not relHeld.isNil: relHeld elif not rel.isNil: addr rel[] else: addr g[]
      ctx.setPhase "matching the traces"
      plan = planJoin(file, g[], relations[], opts, proc (done, total: int): bool =
        ctx.progress(done, total))
    if plan.traces != file[].len: raise newException(JobCancelledError, "cancelled")
    var survey = if relHeld.isNil and rel.isNil: surveyOf(g[], names)
                 elif relHeld.isNil: surveyOf(g[], names, addr rel[])
                 else: surveyOf(g[], names, relHeld)
    (survey.unresolved, survey.unresolvedRecords, survey.notes) =
      (unresolved, unresolvedRecords, notes)
    (survey.csvRows, survey.csvSkipped) = (rows, skipped)
    survey.heads = move heads
    # The layers that hold the join's relations go with it, the last thing
    # this job does with them (the UI thread shares them from here on).
    for k in 0 ..< kept.len:
      ctx.setPhase "preparing the map: " & files[keptFor[k]].path.extractFilename
      postLayer(move kept[k], ctx, to)
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkJoining, planSession: session, geometry: move g,
      relations: move rel, reusedAt: reusedAt, plan: move plan, joinSurvey: move survey)

proc joinApplyWork*(file: ptr SeismicFile; path: string; session: SessionId;
    g: ptr SurveyGeometry; replace, tableOnly: bool; holds: HoldRelease; to: Poster;
    relations: ptr SurveyGeometry = nil; moves: StationMoves = StationMoves();
    bases: seq[ReceiverBase] = @[]): JobWork =
  ## The work of the second job of a join: joins `g` (its relation records
  ## those of `relations` when given: `SharedRelations`) to open file
  ## `session` (`file`, at `path`) in memory (parseSEG's `applySurvey`, or
  ## `applyGeometry` of `g`'s table alone when no SPS or P1 file is in it),
  ## replacing the headers' coordinates when `replace`, then applies `moves`
  ## over that (`applyFileMoves`), and posts what it did (`mkJoined`).
  ## `bases` are receiver fields a previous move replaced; they are put back
  ## before the survey is applied, so the survey writes over the header
  ## position and the moves win after it. Submitted with the file in
  ## `exclusive`, so it starts only once no job reads the file and no reader
  ## holds it; it says how many holds it found (none), and refuses to join
  ## when there are any. A cancel that comes before it joins stops it; the
  ## join itself is one step, which no cancel stops (`commit`): it reads no
  ## file, and a join abandoned halfway would be said cancelled while it
  ## still changed the keys.
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
    var moveChanged = 0
    var postedBases: seq[ReceiverBase] = @[]
    {.cast(gcsafe).}:
      if bases.len > 0:
        var scratch: seq[ReceiverBase] = bases
        moveChanged = file[].applyFileMoves(StationMoves(), scratch)
      changed = if tableOnly: file[].applyGeometry(g[].table, replace)
                 elif relations.isNil: file[].applySurvey(g[], stats, replace)
                 else:
                   when SharedRelations: file[].applySurvey(g[], relations[], stats, replace)
                   else: file[].applySurvey(g[], stats, replace)
      if moves.len > 0:
        var next: seq[ReceiverBase] = @[]
        moveChanged = file[].applyFileMoves(moves, next)
        postedBases = next
      revision = file[].keysRevision
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkJoined, joinedSession: session, stats: stats,
      changed: changed, joinedRevision: revision, heldAtJoin: held, joinedBases: postedBases,
      joinedMoves: moveChanged)

proc movesApplyWork*(file: ptr SeismicFile; path: string; session: SessionId;
    moves: StationMoves; bases: seq[ReceiverBase]; holds: HoldRelease; to: Poster): JobWork =
  ## Applies `moves` to open file `session` (`file`, at `path`) in memory and
  ## posts what changed (`mkMoves`). `bases` are the receiver fields a
  ## previous apply replaced; they are put back first, so a move taken out of
  ## the list restores the header position. Submitted with the file in
  ## `exclusive`. Never writes the file. A cancel before it applies stops it;
  ## once committed, the apply is one step.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    let held = holds.held(path)
    if held > 0:
      raise newException(IOError, "a reader still reads the file, so its station moves were not " &
        "applied")
    if not ctx.commit(): raise newException(JobCancelledError, "cancelled")
    ctx.setPhase "applying station moves"
    var changed = 0
    var revision = 0
    var posted: seq[ReceiverBase] = @[]
    {.cast(gcsafe).}:
      var kept: seq[ReceiverBase] = bases
      changed = file[].applyFileMoves(moves, kept)
      revision = file[].keysRevision
      posted = kept
    discard ctx.progress(1, 1)
    to.post Msg(job: ctx.id, kind: mkMoves, movedSession: session, movedCount: changed,
      movedRevision: revision, movedBases: posted)

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
          eachSpsPart(path, f, info.size, ctx, p, proc (part: var SpsFile) =
            g[].addSps(part, domain))
        finally:
          close(f)
      else:
        raise newException(IOError, p.name & " is no longer an SPS or SEG P1 file")
