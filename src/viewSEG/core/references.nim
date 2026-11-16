## A reference archive: named traces kept so a plot that needs a pilot can
## use one the file does not hold, or another than the file's.
##
## One archive is a folder of one-trace SEG-Y files (IEEE float, the sample
## interval in the trace header, the name in the textual header) and an
## index document, `index.nif`, in the format of the program's other
## documents. The folder is the project's `references` when a project is
## open, and the program's own (beside the file memory) otherwise. This
## module holds the document and the files. It reads and writes them, so
## a caller on the UI thread does not call the procs that do: a job does
## (`core/referencejobs`). What a dialog shows of an open file's index
## (`indexedSpan`) is already in memory.

import std/[math, os, strutils, times]
import parseSEG
import processSEG/vibroseis/[sweep, taper]
import filesystem, nif, threads

const
  ReferencesFolder* = "references"
  ReferenceIndexName* = "index.nif"
  ReferenceVersion* = 1
  MaxReferenceName* = 120

type
  ReferenceLaw* = enum
    ## A sweep processSEG can make, as the Generate dialog offers it. A
    ## table sweep is not here: it needs a list of points, not two
    ## frequencies.
    rlLinear = "linear"
    rlExponential = "exponential"
    rlDbPerOctave = "dB/octave"
    rlDbPerHz = "dB/Hz"

  ReferenceOrigin* = object
    ## Where a reference's samples came from.
    case generated*: bool
    of false:
      fileName*: string ## the seismic file's name, not its path
      record*: float64  ## the record number; NaN when the headers name none
      trace*: int       ## the trace, from 1, as the plot names it
      fromMs*, toMs*: float64
    of true:
      law*: ReferenceLaw
      f1Hz*, f2Hz*: float64
      durationMs*, dtMs*: float64
      taperStartMs*, taperEndMs*: float64
      amplitude*: float64
      boostDb*: float64

  ReferenceEntry* = object
    ## One reference, as the index holds it. `missing` is not written: it
    ## is set when the SEG-Y file is not in the folder.
    id*: string
    name*: string
    intervalUs*: float64
    samples*: int
    origin*: ReferenceOrigin
    date*: string ## when it was stored, UTC, `yyyy-MM-ddTHH:mm:ssZ`
    file*: string ## its SEG-Y file's name in the folder
    missing*: bool
    later*: seq[NifNode]

  ReferenceIndex* = object
    ## The archive's index. `problems` says what could not be used;
    ## `damaged` means the file was not a document (it is left as it was
    ## until a write moves it aside); `newer` means a later viewSEG wrote
    ## it (it is not overwritten).
    version*: int
    entries*: seq[ReferenceEntry]
    problems*: seq[string]
    damaged*: bool
    newer*: bool
    later*: seq[NifNode]

  StoredReference* = object
    ## What `store reference` names: a trace, a window of it, a name.
    name*: string
    trace*: int      ## a survey-wide trace id
    fromMs*: float64 ## the window's start; 0 the trace's start
    toMs*: float64   ## its end; below 0: the trace's end

  GeneratedReference* = object
    ## What `generate reference` names. `dtMs` 0: the file on show.
    ## `amplitude` 0: 1.
    name*: string
    law*: ReferenceLaw
    f1Hz*, f2Hz*: float64
    durationMs*, dtMs*: float64
    taperStartMs*, taperEndMs*: float64
    amplitude*: float64
    boostDb*: float64

  RefAct* = enum
    raListed = "listed"
    raStored = "stored"
    raGenerated = "generated"
    raRenamed = "renamed"
    raDeleted = "deleted"
    raCopied = "copied"
    raFailed = "failed"

  ReferenceNews* = object
    ## What a reference job posts.
    home*: string ## the archive folder it acted on
    main*: bool   ## the program's own archive, listed beside a project's
    index*: ReferenceIndex
    act*: RefAct
    failure*: string
    id*: string
    name*: string

func referencesFolder*(home: string): string {.inline.} =
  ## The archive folder of a config folder or a project folder.
  home / ReferencesFolder

func indexPath*(folder: string): string {.inline.} =
  ## The index document of an archive folder.
  folder / ReferenceIndexName

func segyPath*(folder, file: string): string {.inline.} =
  folder / file

func findId*(index: ReferenceIndex; id: string): int =
  ## The entry named `id`, or -1.
  result = -1
  for i, e in index.entries:
    if e.id == id: return i

func findName*(index: ReferenceIndex; name: string): int =
  ## The entry whose name is `name`, or -1. Names are compared as given.
  result = -1
  for i, e in index.entries:
    if e.name == name: return i

func lawTitle*(law: ReferenceLaw): string =
  ## The sweep type as a name starts: "Linear", "dB/octave".
  case law
  of rlLinear: "Linear"
  of rlExponential: "Exponential"
  of rlDbPerOctave: "dB/octave"
  of rlDbPerHz: "dB/Hz"

func numberText*(x: float64): string =
  ## `x` without a trailing fraction when it is a whole number.
  if x.isNaN: "none"
  elif abs(x - round(x)) < 1e-6 * max(1.0, abs(x)) and abs(x) < 1e9:
    $int(round(x))
  else:
    var s = formatFloat(x, ffDecimal, 3)
    while s.len > 1 and s[^1] == '0': s.setLen s.len - 1
    if s[^1] == '.': s.setLen s.len - 1
    s

func msWords*(ms: float64): string {.inline.} =
  ## A sample interval in the sentence a plot says when it refuses one.
  numberText(ms)

func intervalRefusal*(refMs, fileMs: float64): string =
  ## What a plot says instead of drawing, when the reference's sample
  ## interval is not the file's. Nothing is resampled.
  "the reference is " & msWords(refMs) & " ms, this file is " & msWords(fileMs) & " ms"

func lengthRule*(refLen, traceLen: int): string =
  ## How a plot uses a reference whose length is not the trace's: the same
  ## rule as a file's own pilot (the longer side sets the length, the
  ## shorter is zero-padded; a longer reference is not cut). "" when they
  ## match.
  if refLen > traceLen:
    "the reference is longer than the trace and is not cut (the same rule as a " &
      "file's own pilot: the shorter side is zero-padded)"
  elif refLen < traceLen:
    "the reference is shorter than the trace: it is zero-padded (the same rule " &
      "as a file's own pilot)"
  else:
    ""

func defaultGenerateName*(g: GeneratedReference): string =
  ## "Linear 8-80 Hz 8 s", from the parameters.
  lawTitle(g.law) & " " & numberText(g.f1Hz) & "-" & numberText(g.f2Hz) & " Hz " &
    numberText(g.durationMs / 1000) & " s"

func frequencyText*(e: ReferenceEntry): string =
  ## The frequency range, for a generated reference; "" for a stored trace.
  if e.origin.generated:
    numberText(e.origin.f1Hz) & "-" & numberText(e.origin.f2Hz) & " Hz"
  else:
    ""

func sourceText*(e: ReferenceEntry): string =
  ## Where the row's samples came from, in one line.
  if e.origin.generated:
    "generated, " & lawTitle(e.origin.law)
  else:
    let rec = if e.origin.record.isNaN: "none" else: numberText(e.origin.record)
    e.origin.fileName & " rec " & rec & " tr " & $e.origin.trace

func lengthText*(e: ReferenceEntry): string =
  ## The length in time, and the sample count.
  let ms = if e.intervalUs > 0 and e.samples > 0:
             float64(e.samples - 1) * e.intervalUs / 1000
           else:
             0.0
  numberText(ms) & " ms (" & $e.samples & ")"

func intervalText*(e: ReferenceEntry): string =
  if e.intervalUs > 0: numberText(e.intervalUs / 1000) & " ms" else: "none"

proc nameProblem*(index: ReferenceIndex; name: string): string =
  ## Why `name` cannot be a new reference's; "" when it can.
  let n = name.strip
  if n.len == 0: "a reference needs a name"
  elif n.len > MaxReferenceName: "a reference's name is at most " & $MaxReferenceName &
    " characters"
  elif index.findName(n) >= 0: "a reference named \"" & n & "\" is already in the archive"
  else: ""

func indexedSpan*(f: ptr SeismicFile; trace: int): tuple[samples: int; intervalUs,
    sweepMs: float64] =
  ## What the store dialog shows of trace `trace`, from the index already in
  ## memory: the sample count, the sample interval (0 when the keys were not
  ## read), and the SEG-Y binary header's sweep length in ms (0 when the
  ## headers do not give one). Touches no file.
  if f == nil or trace notin 0 ..< f[].index.entries.len: return
  result.samples = int(f[].index.entries[trace].numSamples)
  if trace < f[].index.keys.len: result.intervalUs = f[].index.keys[trace].intervalUs
  if f[].index.kind == skSegy and f[].index.segy.binary.sweepLength > 0:
    result.sweepMs = float64(f[].index.segy.binary.sweepLength)

proc cutSamples*(samples: openArray[float32]; intervalUs, fromMs, toMs: float64): seq[float32] =
  ## The samples whose time is in `fromMs` .. `toMs` (both ends kept when
  ## they fall on a sample). `toMs` below 0 keeps through the last sample.
  ## `intervalUs` must be positive; otherwise the samples are returned whole.
  if samples.len == 0: return
  if not (intervalUs > 0 and intervalUs < Inf):
    result = newSeq[float32](samples.len)
    for i, v in samples: result[i] = v
    return
  let dt = intervalUs / 1000
  let i0 = clamp(int(round(fromMs / dt)), 0, samples.len)
  let i1 = if toMs < 0: samples.len
           else: clamp(int(round(toMs / dt)) + 1, i0, samples.len)
  result = newSeq[float32](i1 - i0)
  for i in 0 ..< result.len: result[i] = samples[i0 + i]

proc generateSamples*(g: GeneratedReference): seq[float32] {.gcsafe.} =
  ## The sweep `g` names, from processSEG. Raises `ValueError` as that
  ## library does (a frequency past the anti-alias limit, a length that is
  ## not a whole number of samples, tapers that overlap). No file is read:
  ## a dialog may call it for a preview.
  let amp = if g.amplitude > 0 and g.amplitude < Inf: g.amplitude else: 1.0
  let taper = if g.taperStartMs <= 0 and g.taperEndMs <= 0: noTaper()
              else: initSweepTaper(max(g.taperStartMs, 0.0), max(g.taperEndMs, 0.0))
  let spec = case g.law
    of rlLinear:
      linearSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs, taper, amplitude = amp)
    of rlExponential:
      exponentialSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs, taper, amplitude = amp)
    of rlDbPerOctave:
      dbPerOctaveSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs, g.boostDb, taper, amplitude = amp)
    of rlDbPerHz:
      dbPerHzSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs, g.boostDb, taper, amplitude = amp)
  spec.sweepSamples(float32)

# ----------------------------------------------------------------- document --

proc nowText(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc newId(index: ReferenceIndex): string =
  let base = "r" & $getTime().toUnix
  var n = index.entries.len + 1
  result = base & "-" & $n
  while index.findId(result) >= 0:
    inc n
    result = base & "-" & $n

proc value(w: var NifWriter; tag, s: string) =
  w.open tag
  w.add s
  w.close

proc value(w: var NifWriter; tag: string; x: float64) =
  w.open tag
  w.add x
  w.close

proc value(w: var NifWriter; tag: string; i: int64) =
  w.open tag
  w.add i
  w.close

proc value(w: var NifWriter; tag: string; i: int) =
  w.open tag
  w.add int64(i)
  w.close

proc value(w: var NifWriter; tag: string; b: bool) =
  w.open tag
  w.add b
  w.close

proc writeOrigin(w: var NifWriter; o: ReferenceOrigin) =
  w.open "source"
  w.value("generated", o.generated)
  if o.generated:
    w.value("law", $o.law)
    w.value("f1Hz", o.f1Hz)
    w.value("f2Hz", o.f2Hz)
    w.value("durationMs", o.durationMs)
    w.value("dtMs", o.dtMs)
    w.value("taperStartMs", o.taperStartMs)
    w.value("taperEndMs", o.taperEndMs)
    w.value("amplitude", o.amplitude)
    w.value("boostDb", o.boostDb)
  else:
    w.value("fileName", o.fileName)
    if not o.record.isNaN: w.value("record", o.record)
    w.value("trace", o.trace)
    w.value("fromMs", o.fromMs)
    w.value("toMs", o.toMs)
  w.close

proc writeEntry(w: var NifWriter; e: ReferenceEntry) =
  w.open "entry"
  w.value("id", e.id)
  w.value("name", e.name)
  w.value("intervalUs", e.intervalUs)
  w.value("samples", e.samples)
  w.value("date", e.date)
  w.value("file", e.file)
  w.writeOrigin e.origin
  for n in e.later: w.add n
  w.close

proc indexDocument(index: ReferenceIndex): string =
  var w = initNifWriter()
  w.open "references"
  w.value("version", int64(ReferenceVersion))
  for e in index.entries: w.writeEntry e
  for n in index.later: w.add n
  w.close
  w.finish

proc kidString(n: NifNode): string =
  if n.kids.len >= 1 and n.kids[0].kind == nkString: n.kids[0].text else: ""

proc kidNumber(n: NifNode): float64 =
  if n.kids.len >= 1:
    case n.kids[0].kind
    of nkFloat: n.kids[0].floatVal
    of nkInt: float64(n.kids[0].intVal)
    else: NaN
  else: NaN

proc kidInt(n: NifNode): int =
  if n.kids.len >= 1 and n.kids[0].kind == nkInt: int(n.kids[0].intVal) else: 0

proc kidBool(n: NifNode): bool =
  n.kids.len >= 1 and n.kids[0].kind == nkIdent and n.kids[0].text == "true"

proc readOrigin(n: NifNode; problems: var seq[string]): ReferenceOrigin =
  var generated = false
  var law = rlLinear
  var f1, f2, durationMs, dt, t0, t1, amp, boost, record, fromMs, toMs = NaN
  var fileName = ""
  var trace = 0
  var sawGenerated = false
  for c in n.kids:
    if c.kind != nkTree: continue
    case c.tag
    of "generated":
      generated = kidBool(c)
      sawGenerated = true
    of "law":
      let s = kidString(c)
      var found = false
      for v in ReferenceLaw:
        if $v == s:
          law = v
          found = true
      if not found and s.len > 0:
        problems.add "a sweep type \"" & s & "\" is not one this version makes: kept as linear"
    of "f1Hz": f1 = kidNumber(c)
    of "f2Hz": f2 = kidNumber(c)
    of "durationMs": durationMs = kidNumber(c)
    of "dtMs": dt = kidNumber(c)
    of "taperStartMs": t0 = kidNumber(c)
    of "taperEndMs": t1 = kidNumber(c)
    of "amplitude": amp = kidNumber(c)
    of "boostDb": boost = kidNumber(c)
    of "fileName": fileName = kidString(c)
    of "record": record = kidNumber(c)
    of "trace": trace = kidInt(c)
    of "fromMs": fromMs = kidNumber(c)
    of "toMs": toMs = kidNumber(c)
    else: discard
  if not sawGenerated: generated = f1 == f1 # a frequency was given
  if generated:
    ReferenceOrigin(generated: true, law: law, f1Hz: f1, f2Hz: f2, durationMs: durationMs,
      dtMs: dt, taperStartMs: t0, taperEndMs: t1,
      amplitude: (if amp == amp: amp else: 1.0), boostDb: (if boost == boost: boost else: 0.0))
  else:
    ReferenceOrigin(generated: false, fileName: fileName, record: record, trace: trace,
      fromMs: (if fromMs == fromMs: fromMs else: 0.0), toMs: toMs)

proc readEntry(n: NifNode; problems: var seq[string]): ReferenceEntry =
  for c in n.kids:
    if c.kind != nkTree:
      continue
    case c.tag
    of "id": result.id = kidString(c)
    of "name": result.name = kidString(c)
    of "intervalUs": result.intervalUs = kidNumber(c)
    of "samples": result.samples = kidInt(c)
    of "date": result.date = kidString(c)
    of "file": result.file = kidString(c)
    of "source": result.origin = readOrigin(c, problems)
    else: result.later.add c
  if result.id.len == 0 or result.name.len == 0:
    problems.add "an entry with no id or no name was left out"

proc readIndexDoc(text, name: string): ReferenceIndex =
  var doc: seq[NifNode]
  try:
    doc = parseNif(text, name)
  except NifError as e:
    return ReferenceIndex(damaged: true, problems: @[e.msg])
  var root = -1
  for i, n in doc:
    if n.kind == nkTree and n.tag.startsWith("."): discard
    elif root < 0 and n.isTree("references"): root = i
  if root < 0:
    return ReferenceIndex(damaged: true,
      problems: @[name & " holds no reference index"])
  result.version = ReferenceVersion
  for c in doc[root].kids:
    if c.kind != nkTree: continue
    case c.tag
    of "version":
      result.version = kidInt(c)
    of "entry":
      var problems: seq[string]
      let e = readEntry(c, problems)
      result.problems.add problems
      if e.id.len > 0 and e.name.len > 0: result.entries.add e
    else: result.later.add c
  if result.version > ReferenceVersion:
    result.newer = true
    result.problems.add name & " was written by a newer viewSEG (version " &
      $result.version & "): it is not changed"

proc markMissing(folder: string; index: var ReferenceIndex) =
  for e in index.entries.mitems:
    e.missing = e.file.len == 0 or not fs.fileExists(folder / e.file)

proc loadIndex*(folder: string): ReferenceIndex {.gcsafe.} =
  ## The archive in `folder`. A missing folder is an empty archive. A
  ## document that is not one is `damaged` (the file is left as it was) and
  ## its problem is said; an entry that cannot be used is left out and said.
  ## A SEG-Y file that is not there marks its entry `missing`.
  assertWorkerThread()
  let path = indexPath(folder)
  if not fs.fileExists(path): return ReferenceIndex(version: ReferenceVersion)
  try:
    result = readIndexDoc(fs.readFile(path), path)
  except IOError as e:
    return ReferenceIndex(problems: @[path & " cannot be read: " & e.msg])
  markMissing(folder, result)

proc writeAtomic(path, text: string) =
  ## `text` written to `path`: a temporary file beside it, flushed, then
  ## renamed over it. A reader sees the old file or the new one.
  let tmp = path & "." & $getCurrentProcessId() & ".tmp"
  var f: File
  if not fs.open(f, tmp, fmWrite):
    raise newException(IOError, "cannot write " & tmp)
  try:
    if text.len > 0 and fs.writeBuffer(f, tmp, unsafeAddr text[0], text.len) != text.len:
      raise newException(IOError, "the disk did not take " & tmp)
    flushFile(f)
  finally:
    close(f)
  fs.moveFile(tmp, path)

proc writeIndex*(folder: string; index: ReferenceIndex) {.gcsafe.} =
  ## Writes `index` atomically. A damaged file already there is moved aside
  ## (`index.nif.damaged`) first, so a write does not destroy what could not
  ## be read. A newer version's file is left alone (`ValueError`).
  assertWorkerThread()
  if index.newer:
    raise newException(ValueError, "the reference index was written by a newer viewSEG: " &
      "it is not changed")
  fs.createDir(folder)
  let path = indexPath(folder)
  if fs.fileExists(path):
    var prior = ReferenceIndex()
    try:
      prior = readIndexDoc(fs.readFile(path), path)
    except IOError:
      prior.damaged = true
    if prior.damaged:
      let aside = path & ".damaged"
      if fs.fileExists(aside): discard fs.tryRemoveFile(aside)
      fs.moveFile(path, aside)
    elif prior.newer:
      raise newException(ValueError, "the reference index was written by a newer viewSEG: " &
        "it is not changed")
  writeAtomic(path, indexDocument(index))

proc writeReferenceFile*(path, name: string; intervalUs: float64; samples: openArray[float32];
    origin: ReferenceOrigin) {.gcsafe.} =
  ## One-trace IEEE-float SEG-Y at `path`: the name in the textual header,
  ## the sample interval in the trace header, a sweep's trace code. The
  ## writer's own close renames its temporary file over `path`.
  assertWorkerThread()
  var lines = @["viewSEG reference: " & name]
  if origin.generated:
    lines.add "generated " & lawTitle(origin.law) & " " & numberText(origin.f1Hz) & "-" &
      numberText(origin.f2Hz) & " Hz, " & numberText(origin.durationMs) & " ms, " &
      numberText(origin.dtMs) & " ms"
  elif origin.fileName.len > 0:
    lines.add "stored from " & origin.fileName & ", trace " & $origin.trace &
      ", " & numberText(origin.fromMs) & " to " & numberText(origin.toMs) & " ms"
  var problems: seq[string] = @[]
  {.cast(gcsafe).}:
    var w = openSeismicWriter(path, SegyOutputOptions(text: lines))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, 1.0, 0.0, intervalUs)
    (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    w.writeTrace(k, samples)
    let said = w.close()
    for d in said: problems.add d.msg
  if problems.len > 0:
    raise newException(IOError, problems.join("; "))

proc copyRow[T](samples: T; row: int): seq[float32] =
  result = newSeq[float32](samples.shape[1])
  for i in 0 ..< result.len:
    result[i] = float32(samples[row, i])
    if not (abs(result[i]) < Inf): result[i] = 0

proc readReferenceFile*(path: string): tuple[samples: seq[float32];
    intervalUs: float64] {.gcsafe.} =
  ## The one trace of a reference's SEG-Y, and its sample interval. Raises
  ## `IOError` when the file cannot be read, and `ValueError` when it holds
  ## no trace.
  assertWorkerThread()
  if not fs.fileExists(path):
    raise newException(IOError, "the reference file is missing")
  var rows: seq[float32] = @[]
  var us = 0.0
  {.cast(gcsafe).}:
    var f = openSeismic(path, keys = true)
    if f.len < 1:
      f.close()
      raise newException(ValueError, "the reference file has no trace")
    us = f.sampleIntervalUs(0)
    fs.mappedRead(path)
    rows = copyRow(f.readTraces(0 .. 0), 0)
    f.close()
  clearCycleRoots()
  (rows, us)

proc readRawTrace*(file: ptr SeismicFile; path: string; trace: int): seq[float32] {.gcsafe.} =
  ## Trace `trace` of an open file, decoded, with no filter, gain or
  ## polarity. A sample that is not a number becomes 0, as the plot draws
  ## one. Empty when the trace cannot be decoded.
  assertWorkerThread()
  fs.mappedRead(path)
  {.cast(gcsafe).}:
    result = copyRow(file[].readTraces(trace .. trace), 0)
  clearCycleRoots()

proc addEntry(index: var ReferenceIndex; name: string; intervalUs: float64;
    samples: openArray[float32]; origin: ReferenceOrigin): ReferenceEntry =
  ## An entry for samples about to be written. Raises `ValueError` for a
  ## name already used or empty. Does not write.
  let problem = index.nameProblem(name)
  if problem.len > 0: raise newException(ValueError, problem)
  let id = newId(index)
  result = ReferenceEntry(id: id, name: name.strip, intervalUs: intervalUs,
    samples: samples.len, origin: origin, date: nowText(), file: id & ".sgy")

proc storeSamples*(folder, name: string; intervalUs: float64; samples: openArray[float32];
    origin: ReferenceOrigin): string {.gcsafe.} =
  ## Writes a reference and returns its id. A name already used raises
  ## `ValueError` and writes nothing. The SEG-Y is written first, then the
  ## index, so a failure leaves no index entry for a file that is not there.
  assertWorkerThread()
  var index = loadIndex(folder)
  if index.newer:
    raise newException(ValueError, index.problems.join("; "))
  # A damaged index is moved aside by the save; what could be read is kept.
  index.damaged = false
  let e = addEntry(index, name, intervalUs, samples, origin)
  fs.createDir(folder)
  writeReferenceFile(folder / e.file, e.name, intervalUs, samples, origin)
  index.entries.add e
  writeIndex(folder, index)
  e.id

proc renameIn*(folder, id, name: string) {.gcsafe.} =
  ## Renames the reference `id`. A name already used, or no such reference,
  ## raises `ValueError`. The SEG-Y is written again so its textual header
  ## carries the new name.
  assertWorkerThread()
  var index = loadIndex(folder)
  if index.damaged or index.newer:
    raise newException(ValueError, index.problems.join("; "))
  let i = index.findId(id)
  if i < 0: raise newException(ValueError, "there is no reference \"" & id & "\"")
  let problem = index.nameProblem(name)
  if problem.len > 0 and index.findName(name.strip) != i:
    raise newException(ValueError, problem)
  if index.entries[i].missing:
    raise newException(ValueError, "the reference \"" & index.entries[i].name &
      "\" has no file: it cannot be renamed")
  let path = folder / index.entries[i].file
  let (samples, us) = readReferenceFile(path)
  index.entries[i].name = name.strip
  writeReferenceFile(path, name.strip, us, samples, index.entries[i].origin)
  writeIndex(folder, index)

proc deleteIn*(folder, id: string): string {.gcsafe.} =
  ## Removes the reference `id` and its SEG-Y. Returns its name. No such
  ## reference raises `ValueError`.
  assertWorkerThread()
  var index = loadIndex(folder)
  if index.damaged or index.newer:
    raise newException(ValueError, index.problems.join("; "))
  let i = index.findId(id)
  if i < 0: raise newException(ValueError, "there is no reference \"" & id & "\"")
  result = index.entries[i].name
  if index.entries[i].file.len > 0:
    discard fs.tryRemoveFile(folder / index.entries[i].file)
  index.entries.delete i
  writeIndex(folder, index)

proc copyInto*(fromFolder, toFolder, id: string): string {.gcsafe.} =
  ## Copies reference `id` from one archive into the other (a new id, the
  ## same name and samples). Returns the new id. A name already in the
  ## destination raises `ValueError` and copies nothing.
  assertWorkerThread()
  let src = loadIndex(fromFolder)
  let i = src.findId(id)
  if i < 0: raise newException(ValueError, "there is no reference \"" & id & "\" in the main archive")
  if src.entries[i].missing:
    raise newException(ValueError, "the reference \"" & src.entries[i].name &
      "\" has no file: it was not copied")
  let (samples, us) = readReferenceFile(fromFolder / src.entries[i].file)
  storeSamples(toFolder, src.entries[i].name, us, samples, src.entries[i].origin)
