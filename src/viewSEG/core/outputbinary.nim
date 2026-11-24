## A named set of values for the SEG-Y binary file header (bytes 3201 to
## 3600) of a file the Output window writes: each entry names one field and
## gives its value as the person typed it (a number). The library's SEG-Y
## writers take such values as `binary.<field>` overrides and write them
## exactly; nothing else of the header changes.
##
## The fields a person may set (`BinaryFields`) come from the library's own
## layout table of the binary header (`binaryHeaderFields`: name, first byte,
## width and kind of every field): the raw byte runs are left out, and so are
## the fields the library refuses (`Refused`: what sizes the file or names the
## revision, and the sample interval the writer sets from the traces). The
## library does not export its refusal list, so `Refused` is copied from the
## documentation of `openSeismicWriter`; `tests/toutputbinary` opens a real
## writer with every field and checks the two agree.
##
## A field only Rev 2 has is not written into a Rev 0 or Rev 1 file, and a
## 16-bit field that its set Rev 2 extended twin hides is not written into a
## Rev 2 file: `overridesOf` leaves each out and says so, in a sentence.

import std/[math, options, parseutils, strutils, unicode]
import parseSEG
import parseSEG/model/traceindex
import outputnames

const
  MaxBinaryName* = MaxPatternName ## the set's name, in characters

type
  BinaryKind* = enum
    ## How a field's value is typed and checked.
    bkInt   ## a whole number, signed
    bkUInt  ## a whole number, not below 0
    bkFloat ## any finite number

  BinaryFieldInfo* = object
    ## One field a person may set, for a list in a window.
    name*: string            ## the library's field name, as stored in a set (`jobId`)
    label*: string           ## a short name in words (`Job id`)
    firstByte*: int          ## the 1-based byte of the file (3201 to 3600)
    bytes*: int              ## width in bytes
    kind*: BinaryKind
    lowest*, highest*: int64 ## the whole numbers it holds (`bkInt`, `bkUInt`)
    rev2*: bool              ## only a Rev 2 file has it

  BinaryEntry* = object
    ## One field of a set, with its value as typed.
    field*: string ## a `BinaryFieldInfo.name`
    value*: string ## a number: `7`, `-3`, `4000.5`

  OutputBinary* = object
    ## One set, by the name a person picks it by.
    name*: string
    entries*: seq[BinaryEntry] ## in the order the person gave them

  BinaryOverrides* = object
    ## What `overridesOf` makes for one output revision.
    overrides*: seq[HeaderOverride] ## to pass as `binaryOverrides`
    notes*: seq[string]             ## sentences, one per entry not written

const
  Refused* = ["samplesPerTrace", "formatCode", "extSamplesPerTrace", "byteOrderMarker",
    "segyMajor", "segyMinor", "fixedLengthTraces", "numExtTextHeaders", "maxAddlTraceHeaders",
    "numTraces", "firstTraceOffset", "numTrailerRecords", "sampleInterval",
    "extSampleInterval"]
    ## fields the library refuses to override (see the unit's header)
  Rev2Only = ["extDataTracesPerEnsemble", "extAuxTracesPerEnsemble", "extSamplesPerTraceOrig",
    "extSampleIntervalOrig", "extEnsembleFold", "timeBasisCode"]
    ## fields only a Rev 2 file has
  Twins = [("dataTracesPerEnsemble", "extDataTracesPerEnsemble"),
    ("auxTracesPerEnsemble", "extAuxTracesPerEnsemble"),
    ("ensembleFold", "extEnsembleFold"),
    ("samplesPerTraceOrig", "extSamplesPerTraceOrig"),
    ("sampleIntervalOrig", "extSampleIntervalOrig")]
    ## a 16-bit field and the Rev 2 field that hides it when that one is not 0

func labelOf(name: string): string =
  ## `sweepFreqStart` as `Sweep frequency start`.
  var words: seq[string] = @[]
  var word = ""
  for c in name:
    if c.isUpperAscii and word.len > 0:
      words.add word
      word = ""
    word.add c.toLowerAscii
  words.add word
  for w in words.mitems:
    case w
    of "ext": w = "extended"
    of "freq": w = "frequency"
    of "orig": w = "original"
    of "addl": w = "additional"
    of "id": w = "ID"
    else: discard
  result = words.join(" ")
  result[0] = result[0].toUpperAscii

func build(): seq[BinaryFieldInfo] =
  result = @[]
  for f in binaryHeaderFields:
    if f.kind in {fkInt, fkUInt, fkFloat} and f.name notin Refused:
      var info = BinaryFieldInfo(name: f.name, label: labelOf(f.name), firstByte: f.specByte,
        bytes: f.size, kind: bkFloat, rev2: f.name in Rev2Only)
      if f.kind == fkInt:
        info.kind = bkInt
        info.lowest = -(1'i64 shl (8 * f.size - 1))
        info.highest = (1'i64 shl (8 * f.size - 1)) - 1
      elif f.kind == fkUInt:
        info.kind = bkUInt
        info.highest = (1'i64 shl (8 * f.size)) - 1
      result.add info

const BinaryFields*: seq[BinaryFieldInfo] = build()
  ## every field a person may set, in file order

func fieldInfo*(name: string): Option[BinaryFieldInfo] =
  ## The field called `name` (the library's spelling); none when it is not one
  ## that can be set.
  result = none(BinaryFieldInfo)
  for f in BinaryFields:
    if f.name == name: return some(f)

func find*(b: OutputBinary; field: string): int =
  ## The index of the entry for `field`; -1 when there is none.
  result = -1
  for i, e in b.entries:
    if e.field == field: return i

func nameProblem(name: string): string =
  let n = strip(name)
  if n.len == 0: return "A binary header set needs a name."
  if validateUtf8(n) >= 0: return "A binary header set's name is not text (not UTF-8)."
  if n.runeLen > MaxBinaryName:
    return "A binary header set's name is at most " & $MaxBinaryName & " characters long."
  for c in n:
    if c in {'\0' .. '\31', '\127'}: return "A binary header set's name holds no control characters."
  ""

func numberOf(info: BinaryFieldInfo; text: string; whole: var int64; real: var float64): string =
  ## Reads `text` as the field's number; "" when it is one the field holds,
  ## else what is wrong with it (no field name in it).
  let t = strip(text)
  if info.kind == bkFloat:
    let used = if '_' in t: 0 else: parseFloat(t, real)
    if used != t.len or t.len == 0 or classify(real) in {fcNan, fcInf, fcNegInf}:
      return "'" & t & "' is not a number."
    return ""
  let used = if '_' in t: 0 else: parseBiggestInt(t, whole)
  if used != t.len or t.len == 0:
    return "'" & t & "' is not a whole number."
  if whole < info.lowest or whole > info.highest:
    return $whole & " is not from " & $info.lowest & " to " & $info.highest & "."
  ""

func valueProblem*(info: BinaryFieldInfo; text: string): string =
  ## Why `text` is not a value of the field `info`: `'abc' is not a whole number.`,
  ## `40000 is not from -32768 to 32767.`; "" when it is one.
  var whole = 0'i64
  var real = 0.0
  numberOf(info, text, whole, real)

func twinOf*(field: string): string =
  ## The Rev 2 extended field that hides the 16-bit `field` when it is set;
  ## "" when `field` has none.
  for (small, big) in Twins:
    if small == field: return big

func binaryProblem*(b: OutputBinary): string =
  ## Why `b` cannot be kept; "" when it can: no name, a name that is too long
  ## or holds a control character, a field that cannot be set or given twice,
  ## and a value that is not a number the field holds.
  result = nameProblem(b.name)
  if result.len > 0: return
  var seen: seq[string] = @[]
  for e in b.entries:
    let info = fieldInfo(e.field)
    if info.isNone:
      return "'" & e.field & "' is not a binary header field that can be set."
    if e.field in seen: return info.get.label & " is given twice."
    seen.add e.field
    let why = valueProblem(info.get, e.value)
    if why.len > 0: return info.get.label & ": " & why

func revisionWord(rev: SegyRevision): string =
  ## `0`, `1`, `2.0`, `2.1`: the words the revisions go by.
  if rev.major < 2: $rev.major else: $rev

func isSet(b: OutputBinary; field: string): bool =
  ## `field` is in `b` with a value that is not 0.
  let i = b.find(field)
  if i < 0: return false
  var real = 0.0
  discard parseFloat(strip(b.entries[i].value), real)
  result = real != 0.0

func overridesOf*(b: OutputBinary; rev: SegyRevision): BinaryOverrides =
  ## The entries of `b` as the writer takes them for a file of revision `rev`
  ## (call it when `binaryProblem` is ""). An entry the revision cannot hold
  ## is left out and `notes` says so: a Rev 2 field in a Rev 0 or Rev 1 file,
  ## and a 16-bit field in a Rev 2 file whose extended twin is also set (it
  ## would hide it).
  result = BinaryOverrides()
  for e in b.entries:
    let info = fieldInfo(e.field)
    if info.isSome:
      var hiddenBy = ""
      if rev.major >= 2:
        for (small, big) in Twins:
          if small == e.field and b.isSet(big): hiddenBy = fieldInfo(big).get.label
      if info.get.rev2 and rev.major < 2:
        result.notes.add "Binary header: " & info.get.label & " is not written in SEG-Y revision " &
          revisionWord(rev) & "."
      elif hiddenBy.len > 0:
        result.notes.add "Binary header: " & info.get.label & " is not written in SEG-Y revision " &
          revisionWord(rev) & ": " & hiddenBy & " is set and replaces it."
      else:
        var whole = 0'i64
        var real = 0.0
        discard numberOf(info.get, e.value, whole, real)
        let name = "binary." & e.field
        if info.get.kind == bkFloat: result.overrides.add headerOverride(name, real)
        else: result.overrides.add headerOverride(name, whole)

func chosenBinary*(sets: openArray[OutputBinary]; name: string): Option[OutputBinary] =
  ## The set called `name`; none when `name` is "" or names none.
  result = none(OutputBinary)
  if name.len > 0:
    for s in sets:
      if s.name == name: return some(s)

func shownValues*(file: SeismicFile): tuple[ok: bool; values: seq[string]] =
  ## The value of every `BinaryFields` field in the binary header of `file`
  ## (as its index holds it: nothing is read), as text; "" for a Rev 2 field
  ## of a file that is not Rev 2. Not ok, no values, when `file` is not an
  ## open SEG-Y file.
  result = (false, @[])
  if file.isOpen and file.kind == skSegy:
    let h = file.index.segy.binary
    let rev2 = file.index.segy.revision.major >= 2
    result.ok = true
    for f in BinaryFields:
      let v = fieldByName(h, f.name)
      if v.isNone or (f.rev2 and not rev2): result.values.add ""
      elif v.get.kind == fvInt: result.values.add $v.get.intVal
      else: result.values.add $v.get.toFloat
