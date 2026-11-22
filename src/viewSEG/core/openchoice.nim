## How a file is opened when its own headers mislead the detection: the
## options "Reopen with options" offers (`OpenChoice`), what parseSEG is
## given for them (`openOptions`), and what an open did, in plain words
## (`OpenFacts`, read on the open job's thread with the file's other facts).
##
## The defaults are parseSEG's: the standard detected from the first bytes,
## a fixed-length SEG-Y file indexed from a sample of its headers, mantissas
## as the standards define them, and a file on a network share read unmapped
## (`faAuto`). A choice that changes how the index is made (a standard
## named, every header checked, two's-complement mantissas) neither reads
## nor writes the index cache: the cache is the default reading's, and a
## later open with the defaults must not get this one's.

import std/strutils
import parseSEG

type
  StandardChoice* = enum
    ## The standard a file is read as.
    scDetect = "detect" ## from its first bytes (the default)
    scSegy = "SEG-Y"
    scSegd = "SEG-D"
    scSeg2 = "SEG-2"

  AccessChoice* = enum
    ## How a file's bytes are reached (parseSEG's `FileAccess`).
    acAuto = "auto"         ## unmapped on a network share, else mapped (the default)
    acMapped = "mapped"     ## mapped: the fastest on a local disk
    acUnmapped = "unmapped" ## read into parseSEG's own cache: a failed read fails only that read

  SignatureChoice* = object
    ## What the decoding of a vibrator controller's signature file may be asked for. Neither
    ## kind states its sample interval.
    intervalUs*: float64 = 0 ## 0: the kind's default (1000 for a .dat, 500 for a .vib)
    swapForces*: bool ## .dat: the force channels wired the other way round
    fromFirstFrame*: bool ## .vib: t = 0 at the first frame, not at the trigger

  OpenChoice* = object
    ## The options a file is opened with; the defaults detect everything.
    standard*: StandardChoice ## the standard; `scDetect` detects it
    verifyAll*: bool
      ## every trace header read and checked at the open (slower), not a
      ## sample of a fixed-length SEG-Y file's
    twosComplement*: bool
      ## SEG-D format 8015 and SEG-2 format 3 mantissas read as two's
      ## complement (some recorders write them so)
    access*: AccessChoice ## how the file's bytes are reached
    demuxDir*: string
      ## where a multiplexed SEG-D file's demultiplexed copy is written; ""
      ## for the system's temporary folder
    signature*: SignatureChoice
      ## a vibrator signature file's own options (it is decoded, not read as SEG-Y or SEG-D)

  OpenFacts* = object
    ## What an open did, read on its thread.
    choice*: OpenChoice    ## the options it was given
    kind*: SeismicKind     ## the standard the file was read as
    detected*: SeismicKind ## what detection says of its first bytes (when a standard was named)
    access*: FileAccess    ## how its bytes are reached (`faMapped` or `faUnmapped`)
    fromCache*: bool       ## its index came from the index cache
    sampled*: bool         ## indexed from its size and a sample of its headers
    demuxed*: bool         ## a multiplexed SEG-D file, read from a demultiplexed copy
    wide*: bool            ## some trace's samples lose precision as 4-byte floats

func isDefault*(c: OpenChoice): bool =
  ## Whether `c` asks for nothing but the defaults.
  c == OpenChoice()

func usesCache*(c: OpenChoice): bool =
  ## Whether an open with `c` may read and write the index cache: only when
  ## its index is made as with the defaults.
  c.standard == scDetect and not c.verifyAll and not c.twosComplement

func kindOf*(s: StandardChoice): SeismicKind =
  ## parseSEG's standard for `s`; `skUnknown` detects.
  case s
  of scDetect: skUnknown
  of scSegy: skSegy
  of scSegd: skSegd
  of scSeg2: skSeg2

func accessOf*(a: AccessChoice): FileAccess =
  case a
  of acAuto: DefaultAccess # (`faAuto`, unless built to read every file unmapped)
  of acMapped: faMapped
  of acUnmapped: faUnmapped

func verifyOf*(c: OpenChoice): VerifyMode =
  ## How much of the file's headers the open checks.
  if c.verifyAll: vfFull else: vfSampled

func openOptions*(c: OpenChoice; cache = ""; vendors = VendorRegistry()): OpenOptions =
  ## What parseSEG's `openSeismic` is given for `c`, with the index cache
  ## file `cache` when `c` may use it (`usesCache`) and the vendor maps
  ## `vendors` (their layouts read a SEG-Y file's line and point numbers as
  ## the file's own header says: the same numbers to every consumer).
  OpenOptions(kind: kindOf(c.standard), verify: verifyOf(c),
    twosComplement8015: c.twosComplement, access: accessOf(c.access), demuxDir: c.demuxDir,
    cache: (if c.usesCache: cache else: ""), vendors: vendors)

func standardName*(k: SeismicKind): string =
  ## A standard's name: "SEG-Y", "SEG-D", "SEG-2"; "not recognised".
  case k
  of skSegy: "SEG-Y"
  of skSegd: "SEG-D"
  of skSeg2: "SEG-2"
  of skUnknown: "not recognised"

func choiceWords*(c: OpenChoice): seq[string] =
  ## What `c` changes from the defaults, a phrase each ("read as SEG-D");
  ## none for the defaults.
  if c.standard != scDetect: result.add "read as " & $c.standard & ", not detected"
  if c.verifyAll: result.add "every trace header checked"
  if c.twosComplement:
    result.add "format 8015 (SEG-D) and format 3 (SEG-2) mantissas read as two's complement"
  case c.access
  of acAuto: discard
  of acMapped: result.add "mapped, wherever it lies"
  of acUnmapped: result.add "read unmapped, wherever it lies"
  if c.demuxDir.len > 0: result.add "its demultiplexed copy written in " & c.demuxDir
  if c.signature.intervalUs > 0:
    result.add "sample interval " & $c.signature.intervalUs & " us"
  if c.signature.swapForces: result.add "force channels wired the other way round"
  if c.signature.fromFirstFrame: result.add "t = 0 at the first frame"

func choiceMark*(c: OpenChoice): string =
  ## `c` in a few words for a window's title or strip ("as SEG-D · every
  ## header checked"); "" for the defaults.
  var parts: seq[string]
  if c.standard != scDetect: parts.add "as " & $c.standard
  if c.verifyAll: parts.add "every header checked"
  if c.twosComplement: parts.add "two's complement"
  case c.access
  of acAuto: discard
  of acMapped: parts.add "mapped"
  of acUnmapped: parts.add "unmapped"
  if c.demuxDir.len > 0: parts.add "demultiplexed copy"
  if c.signature.intervalUs > 0: parts.add $c.signature.intervalUs & " us"
  if c.signature.swapForces: parts.add "forces swapped"
  if c.signature.fromFirstFrame: parts.add "t = 0 at the first frame"
  parts.join(" \u00b7 ")

func choiceText*(c: OpenChoice): string =
  ## `choiceWords` as one sentence's body: "the defaults" for none.
  let w = choiceWords(c)
  if w.len == 0: "the defaults" else: w.join("; ")

func accessWords*(a: FileAccess; chosen: AccessChoice): string =
  ## How a file's bytes are reached, and why, in plain words.
  let how = case a
    of faUnmapped: "unmapped: read into viewSEG's own cache, so a drive that fails " &
      "fails only that read"
    of faMapped: "mapped: the system pages the file in as it is read"
    of faAuto: "chosen by parseSEG"
  result = how & (case chosen
    of acAuto: (if a == faUnmapped: " (it lies on a network share)" else: " (a local disk)")
    of acMapped, acUnmapped: " (as chosen)")

proc openFacts*(f: SeismicFile; c: OpenChoice; size: int64): OpenFacts =
  ## What the open of `f` (of `size` bytes; -1 when not known) with `c`
  ## did. Reads its first bytes when a standard was named (what detection
  ## would have said): call it on the thread that opened the file. Nothing
  ## raises.
  result = OpenFacts(choice: c, kind: f.kind, detected: f.kind, fromCache: f.fromCache,
    demuxed: f.demuxPath.len > 0)
  try:
    result.access = f.access
  except CatchableError:
    result.access = faAuto
  for d in f.log:
    if d.code == dcIndexSampled: result.sampled = true
  try:
    result.wide = f.index.prefersFloat64
  except CatchableError:
    discard
  if c.standard != scDetect and not result.demuxed:
    try:
      let n = min(size, 8192'i64)
      result.detected = if n > 0: detectKind(f.copyBytes(0, int(n))) else: skUnknown
    except CatchableError:
      result.detected = skUnknown
