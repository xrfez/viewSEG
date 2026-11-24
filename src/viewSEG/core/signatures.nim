## A vibrator controller's signature files, opened from memory: the `.dat` (`core/sigdat`)
## and the `.vib` (`core/sigvib`) go through one seam.
##
## The open job reads the file's bytes through `fs` (at most `MaxSignatureBytes`),
## decodes them, writes the decoded shot as SEG-Y Rev 2.1 into a byte buffer with
## parseSEG's memory writer, and opens that buffer with `openSeismicBytes`. **No file is
## written** on this path: no index cache, no temporary file. The `Session`'s path is the
## signature file's own: the memory file's name is the user's, so messages, holds, edits and
## the watch name the file the user knows, and what is remembered about it follows it
## through renames, as for any file.
##
## Neither library's path procs are called from here or anywhere under `src/viewSEG/`
## (`tests/tfilesystem` greps for them): their std IO would go past `fs`.

import std/[math, os, strutils, times]
import parseSEG
import parseSEG/model/traceindex # (`mindex`: the one place a key's status is set, below)
import filesystem, inbox, jobs, openchoice, session, sigdat, sigtypes, sigvib, threads,
  vendormaps

export sigtypes

const
  MaxSignatureBytes* = 64 shl 20 ## larger files are refused before they are read
  SignatureHeadBytes = 4096

func signatureKindOf*(head: openArray[byte]): SignatureKind =
  ## Which signature file the file whose first bytes are `head` is, by content, never by its
  ## extension. A SEG-Y, SEG-D or SEG-2 file is told first (`filekinds.fileKindOf`).
  result = datKind(head)
  if result == sgNone: result = vibKindOf(head)

func signatureRefusal*(head: openArray[byte]; size: int64; name: string): string =
  ## Why a file that no kind claims is refused with words of its own, else "": empty, or a
  ## `.vib` of another kind.
  if size == 0:
    result = name & " is empty: not opened."
  elif isOtherVib(head) or isBrokenVib(head):
    result = name & " could not be opened as a vibrator .vib file: " & vibRefusal(head, size)

proc readHead*(path: string; head: var seq[byte]): int64 =
  ## The file's first bytes into `head` and its size; -1 when it cannot be read.
  result = -1
  var f: File
  if not fs.open(f, path, fmRead): return
  try:
    head.setLen SignatureHeadBytes
    head.setLen fs.readBuffer(f, path, addr head[0], SignatureHeadBytes)
    result = fs.getFileSize(path)
  except IOError, OSError:
    discard
  finally:
    close(f)

proc refusalOf*(path: string): string =
  ## `signatureRefusal` of the file at `path`; "" when it has none (or cannot be read).
  var head: seq[byte] = @[]
  let size = readHead(path, head)
  if size >= 0: signatureRefusal(head, size, path.extractFilename) else: ""

proc readBytes(path: string; size: int64): seq[byte] =
  ## The whole file, `size` bytes, through `fs`. Raises `IOError` in plain words.
  let name = path.extractFilename
  var f: File
  if not fs.open(f, path, fmRead):
    raise newException(IOError, name & " cannot be read now (it cannot be opened).")
  try:
    result = newSeq[byte](size)
    if size > 0 and fs.readBuffer(f, path, addr result[0], size) != int(size):
      raise newException(IOError, name & " cannot be read now (it changed while it was read).")
  except IOError as e:
    if e.msg.startsWith(name): raise
    raise newException(IOError, name & " cannot be read now (" & e.msg & ").")
  finally:
    close(f)

proc decodeToSession*(bytes: openArray[byte]; path: string; modified: Time;
    choice = SignatureChoice(); log: var DiagLog; pair = SignaturePair()): Session =
  ## Decodes `bytes`, the file at `path`, in memory and makes its session. Raises
  ## `SignatureError`. Worker-only, as `filejobs.openSession`: it makes the file's objects.
  let name = path.extractFilename
  let kind = signatureKindOf(bytes)
  var segy: seq[byte] = @[]
  var facts = SignatureFacts()
  case kind
  of sgDat:
    {.cast(gcsafe).}: # (parseSEG's memory writer: nothing global is touched, as for its file one)
      (segy, facts) = sigdat.decode(bytes, name, path, choice, log)
  of sgVib:
    {.cast(gcsafe).}:
      (segy, facts) = sigvib.decode(bytes, name, path, choice, log, pair)
  of sgNone:
    let why = signatureRefusal(bytes.toOpenArray(0, min(bytes.len, SignatureHeadBytes) - 1),
      int64(bytes.len), name)
    raise newException(SignatureError, if why.len > 0: why else:
      name & " is not a vibrator signature file.")
  for d in log: facts.warnings.add name & ": " & d.msg
  var opened: SeismicFile
  try:
    {.cast(gcsafe).}:
      opened = openSeismicBytes(move segy, path, keys = true,
        opts = openOptions(OpenChoice(), "", currentVendors()))
  except ValueError as e:
    raise newException(SignatureError, name & " could not be opened as a " & $kind &
      " file: " & e.msg)
  # Every trace of a signature file is auxiliary to viewSEG. A `.vib`'s codes above 22 read back
  # with status unknown, which parseSEG counts as seismic data: set at the source, before any
  # reader, record row or layer is made from the keys, so every check agrees.
  {.cast(gcsafe).}:
    for k in opened.mindex.keys.mitems: k.status = tsAuxiliary
  result = newSession(path, move opened, int64(bytes.len), modified, OpenChoice(), facts)

proc openSignature*(path: string; choice = SignatureChoice();
    pair = SignaturePair()): Session =
  ## The signature file at `path` as a session, decoded in memory. The default
  ## `choice` is used when none is given. Worker-only. Raises `SignatureError`,
  ## `IOError` or `OSError`. Nothing is written. The one place a signature path
  ## becomes a session.
  assertWorkerThread()
  let name = path.extractFilename
  if not fs.fileExists(path):
    raise newException(IOError, "there is no such file")
  let size = fs.getFileSize(path)
  if size == 0:
    raise newException(SignatureError, name & " is empty: not opened.")
  if size > MaxSignatureBytes:
    var head: seq[byte] = @[]
    discard readHead(path, head)
    let kind = signatureKindOf(head)
    raise newException(SignatureError, name & " is larger than any " &
      (if kind == sgVib: ".vib" else: ".dat") & " signature file (" &
      $(MaxSignatureBytes shr 20) & " MiB): not opened")
  # The time before the read: a file that changes while it is read keeps the older stamp, so
  # the watch sees the change and opens it again (one retry when it moved meanwhile).
  var modified = fs.getLastModificationTime(path)
  var bytes = readBytes(path, size)
  if fs.getLastModificationTime(path) != modified:
    modified = fs.getLastModificationTime(path)
    bytes = readBytes(path, fs.getFileSize(path))
  var log: DiagLog
  result = decodeToSession(bytes, path, modified, choice, log, pair)

proc openSignatureWork*(path: string; to: Poster; choice = SignatureChoice();
    pair = SignaturePair()): JobWork =
  ## The work of a job that opens the signature file at `path` and posts its session
  ## (`mkOpened`). It raises nothing but `SignatureError`, `IOError`, `OSError` and
  ## `JobCancelledError`. The file is read once and nothing is written.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "decoding"
    ctx.checkCancelled()
    var s: Session = nil
    {.cast(gcsafe).}:
      s = openSignature(path, choice, pair)
    ctx.checkCancelled() # the file closes here, on the thread that made it
    clearCycleRoots() # the UI thread may release the file's objects at once
    to.post Msg(job: ctx.id, kind: mkOpened, session: move s)

func signatureOpened*(name: string; f: SignatureFacts; traces: int): string =
  ## The Message log's line for an open signature file.
  let interval = formatFloat(f.choice.intervalUs / 1000, ffDecimal, 1).replace(".0", "")
  case f.kind
  of sgDat:
    "Opened " & name & ": vibrator .dat signature file of controller " &
      intToStr(int(f.info.controller), 4) &
      (if f.info.vibrator > 0: ", vibrator " & $f.info.vibrator else: "") & ", " &
      $traces & " traces (the reference, the reaction-mass and baseplate forces, and " &
      "the controller's ground force, their sum), decoded in memory."
  of sgVib:
    let t = f.trigger
    let trig = if t.source == trEstimated and t.timeZero == "trigger":
        "trigger at frame " & formatFloat(t.frame, ffDecimal, 2) &
        " estimated from the reference (+- " & formatFloat(t.sigmaFrames, ffDecimal, 3) &
        " frames)"
      else: "no trigger used: t = 0 is the first frame"
    "Opened " & name & ": vibrator .vib signature record, " & $traces & " traces at " &
      interval & " ms (assumed), recording began " &
      timeText(f.info.triggerNs, 0) & " UTC, " & trig & ", decoded in memory."
  of sgNone: "Opened " & name & "."

func signatureForceNote*(f: SignatureFacts): string =
  ## What the Vibrator window says of a signature file's ground force: trace 4 is it, and no
  ## typed mass is applied.
  case f.kind
  of sgDat:
    "M and B are forces already (the controller's mass-weighted channels): no masses are applied"
  of sgVib:
    "M and B are accelerations of set B (counts); the ground force (trace 4) is computed from " &
      "them with the file's weights (baseplate " & $int64(round(f.masses.baseplateLb)) &
      " lb, reaction mass " & $int64(round(f.masses.massLb)) &
      " lb): no typed masses are applied"
  of sgNone: ""
