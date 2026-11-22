## What viewSEG knows of a vibrator controller's signature file (a `.dat` or a
## `.vib`) beyond the SEG-Y it is decoded into: plain values that every layer
## above `core/sigdat` and `core/sigvib` may use, so that no library type crosses
## those two modules.
##
## `SignatureFacts` is made on the open job, next to the in-memory SEG-Y
## (`core/signatures`), and kept by the `Session`. It holds the words' sources
## (the decoded numbers), never the words themselves: `core/properties` says
## them, so the Headers window and the agent's `properties` agree.

import std/[math, strutils]
import parseSEG
import headers
from openchoice import SignatureChoice

export SignatureChoice

type
  SignatureKind* = enum
    ## Which signature file a file is, told from its first bytes, never its extension.
    sgNone = "" ## not a signature file
    sgDat = "vibrator .dat"
    sgVib = "vibrator .vib"

  QcLimit* = enum
    ## The controller's limit letters, as its report prints them; their meanings are
    ## not known.
    qlT = "T", qlM = "M", qlV = "V", qlF = "F", qlR = "R"

  SweepQc* = object
    ## The controller's QC numbers a list row shows.
    valid*: bool
    forceMaxPct*, forceMinPct*, forceAvgPct*, thdMaxPct*, thdAvgPct*: int16 = -1
    phaseMaxDeg*: float32 = NaN
    limits*: set[QcLimit]

  SerialFrom* = enum
    sfNone   ## no serial known
    sfFile   ## the .dat's record header
    sfFolder ## a .vib's folder name (a hint, not in the file)
    sfPair   ## the .dat of the same sweep

  SweepInfo* = object
    ## One signature file as a list knows it, without a decoded sample.
    kind*: SignatureKind
    problem*: string                                        ## why it could not be read; "" when it could
    controller*: int64 ## the controller's serial; meaningful with `serialFrom` not sfNone
    serialFrom*: SerialFrom
    vibrator*: int                                          ## the QC record's vibrator ID; 0: none
    fileNumber*: int64 ## .dat: the file number; .vib: the file counter (-1 when unnumbered)
    triggerNs*: int64 ## UTC ns since 1970: a .dat's trigger, a .vib's start second
    timeIsStart*: bool                                      ## .vib: `triggerNs` is the second the recording began
    samples*, declared*: int32 ## per channel present, announced (.vib: frames, frames)
    blocks*, blocksDeclared*: int32                         ## .dat only
    intervalUs*: float64
    complete*: bool
    sweepNumber*: int16                                     ## .dat: 16 is a pulse record
    line*, station*, shotId*, sweepId*, sourceIndex*: int64 ## .dat: 0 is not given
    qc*: SweepQc

  SignaturePair* = object
    ## The `.dat` of a `.vib`'s sweep, as the open job is given it: its trigger time and what
    ## only it knows (a `.vib` file holds neither the controller nor the vibrator).
    path*: string ## the `.dat`'s path; "" for no pair
    triggerNs*: int64
    controller*: int64
    vibrator*: int

  ControllerQc* = object
    ## The whole QC record of a .dat (a stopped recording has none: `valid` false). A
    ## .vib has none.
    valid*: bool
    crew*, vibrator*, sweepNumber*: int
    sweepId*, shotId*, sourceLine*, sourceStation*: int64
    sweepChecksum*, paramChecksum*: int
    brief*: SweepQc
    stiffness*, viscosity*: tuple[max, min, avg: int]
    targetForceLbf*: int = -1
    satellites*, correctionAgeS*: int
    heightCm*: int64
    pdop*, hdop*, vdop*: float64
    correlationMagnitude*: int
    correlationStored*: bool ## the 128 lags of the controller's own correlation are in the record
    correlationLagZero*: int ## its value at lag 0 (index 64) when stored

  TriggerSource* = enum
    trNone, trEstimated, trGiven

  SignatureTrigger* = object
    ## .vib: where t = 0 is. (A .dat's trigger is its sample 0.)
    source*: TriggerSource
    frame*, sigmaFrames*: float64 = NaN
    startHz*, rateHzPerS*, residualCycles*: float64 = NaN
    crossings*: int
    why*: string       ## no fit: why (a pulse, a non-linear sweep, too few crossings)
    timeZero*: string  ## "trigger" or "first frame"
    clockFrom*: string ## "the second the recording began" or "the .dat of this sweep"

  SignatureTrace* = object
    name*: string  ## what the plots call the trace
    short*: string ## the same in a few letters, for a narrow header column
    code*: int16   ## its SEG-Y trace identification code
    unit*: string  ## "counts", "pound-counts"

  SignaturePosition* = object
    valid*: bool
    latitudeDeg*, longitudeDeg*: float64
    altitudeM*: float64 = NaN
    fixQuality*, satellites*: int
    hdop*: float64 = NaN

  SignatureFacts* = object
    ## What a signature session knows beyond its in-memory SEG-Y. `kind` is `sgNone`
    ## for every other session.
    kind*: SignatureKind
    info*: SweepInfo
    qc*: ControllerQc
    choice*: SignatureChoice ## as used: the interval resolved
    intervalStated*: bool ## false: assumed (neither kind states it)
    forceChannels*: bool ## M and B are forces already (a .dat), not accelerations
    groundForceGiven*: bool ## trace 4 is the ground force: both kinds
    masses*: tuple[baseplateLb, massLb, holdDownLb: float64] = (NaN, NaN, NaN) ## .vib header
    sensitivities*: tuple[first, second: float64] = (NaN, NaN) ## .vib header
    calibrations*: tuple[valve, mass: float64] = (NaN, NaN) ## .vib header
    unknown*: tuple[first, second: float64] = (NaN, NaN) ## .vib header: meaning unknown
    trigger*: SignatureTrigger
    traces*: seq[SignatureTrace] ## one per trace, in the layout's order
    endsInSweep*: bool ## .vib: the record ends inside the sweep (a stopped recording)
    headerText*: string ## .dat: the GNSS text, sanitized
    gga*, fix*: SignaturePosition
    rows*: seq[FieldRow] ## the file's own fields, offsets in the file
    blocks*: seq[RawBlock] ## those blocks' bytes, for the hex pane
    decodedAs*: string ## "SEG-Y Rev 2.1 in memory (no file written)"
    warnings*: seq[string] ## said once at the open (stopped, cut short)
    notes*: seq[string] ## information said once at the open (no trigger found)
    pair*: string ## the partner's path when the open was given it (a `.vib`'s `.dat`)
    pairTriggerNs*: int64 ## with `pair`: the `.dat`'s trigger, the clock time of the `.vib`

  SignatureError* = object of CatchableError
    ## A file that cannot be decoded: plain words, the library's.

const
  SignatureKinds* = {sgDat, sgVib}
  MaxYear* = 2262
    ## the last year whose time in nanoseconds since 1970 fits 64 bits: a signature file's
    ## date beyond it is refused, not wrapped
  DatIntervalUs* = 1000.0
  VibIntervalUs* = 500.0

func isSignature*(f: SignatureFacts): bool {.inline.} = f.kind != sgNone

func defaultIntervalUs*(k: SignatureKind): float64 =
  ## What a kind's interval is taken to be when nothing else is said.
  if k == sgVib: VibIntervalUs else: DatIntervalUs

func sigRow*(blockName, field, description, value: string; number: float64; blockOffset: int64;
    blockSize, at, size: int): FieldRow =
  ## One field of a signature file's own block: `at` is its first byte in the block (from 0),
  ## `size` the bytes it takes; offsets are in the file.
  FieldRow(blockName: blockName, kind: hbRaw, field: field, description: description,
    value: value, number: number, first: at + 1, last: at + max(size, 1),
    offset: blockOffset + at, size: size, blockOffset: blockOffset, blockSize: blockSize,
    firstNibble: -1)

func daysFromCivil(y0, m, d: int): int64 =
  let y = if m <= 2: y0 - 1 else: y0
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let mp = if m > 2: m - 3 else: m + 9
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  int64(era) * 146097 + int64(doe) - 719468

func unixNs*(year, month, day, hour, minute, second, nanosecond: int): int64 =
  ## UTC nanoseconds since 1970 of a date and time of day the library has checked
  ## (1970 to 9999), a leap second counted as the second after the 59th. Past the year 2262,
  ## which 64 bits of nanoseconds cannot hold, it is the largest value (never an overflow).
  let secs = daysFromCivil(year, month, day) * 86400 + int64(hour * 3600 + minute * 60 + second)
  if secs >= 9_223_372_035'i64: high(int64)
  else: secs * 1_000_000_000 + int64(nanosecond)

func civilOf*(ns: int64): tuple[year, month, day, hour, minute, second, nanosecond: int] =
  ## UTC date and time of day of `ns` (nanoseconds since 1970).
  let secs = floorDiv(ns, 1_000_000_000'i64)
  let days = floorDiv(secs, 86400'i64)
  let rest = int(floorMod(secs, 86400'i64))
  let z = days + 719468
  let era = floorDiv(z, 146097'i64)
  let doe = int(z - era * 146097)
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let day = doy - (153 * mp + 2) div 5 + 1
  let month = if mp < 10: mp + 3 else: mp - 9
  result = (int(era) * 400 + yoe + (if month <= 2: 1 else: 0), month, day, rest div 3600,
    rest mod 3600 div 60, rest mod 60, int(floorMod(ns, 1_000_000_000'i64)))

func timeText*(ns: int64; fraction = 9): string =
  ## `ns` (UTC nanoseconds since 1970) as "2001-02-03 04:05:06.789012345", with `fraction`
  ## digits of a second (none: the whole second only).
  let c = civilOf(ns)
  result = intToStr(c.year, 4) & "-" & intToStr(c.month, 2) & "-" & intToStr(c.day, 2) & " " &
    intToStr(c.hour, 2) & ":" & intToStr(c.minute, 2) & ":" & intToStr(c.second, 2)
  if fraction > 0:
    result.add "." & intToStr(c.nanosecond, 9)[0 ..< min(fraction, 9)]

func secondsWords*(seconds: float64): string =
  ## "12.000 s".
  formatFloat(seconds, ffDecimal, 3) & " s"

func groupDigits*(n: int64): string =
  ## `n` with its thousands apart: "24 800".
  let digits = $abs(n)
  for i, c in digits:
    if i > 0 and (digits.len - i) mod 3 == 0: result.add ' '
    result.add c
  if n < 0: result = "-" & result


func headerName*(label: string): string =
  ## The short part of a signature trace's label ("short\tfull"), for a narrow header column.
  let at = label.find('\t')
  if at >= 0: label[0 ..< at] else: label

func fullName*(label: string): string =
  ## The full part of a signature trace's label ("short\tfull"), for the readout.
  let at = label.find('\t')
  if at >= 0: label[at + 1 .. ^1] else: label
