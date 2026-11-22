## What a file is, told from its first bytes: a seismic file (SEG-Y, SEG-D,
## SEG-2: parseSEG's `detectKind`) or a survey file (SPS source, receiver or
## relation records, or SEG P1 shotpoint positions). The file list sniffs
## every file it lists this way (`filejobs.sniff`), and an open job does the
## same before it opens a file, so survey files are listed as what they are
## and opened into the survey instead of the plot.
##
## **Signature files.** A vibrator controller's `.dat` and `.vib` files are told by their
## content (never their extension) before the SEG kinds, whose detection takes some of their
## bytes for a SEG-Y header, and after the survey (text) kinds; the kind-6 `.vib` and an empty file are not signature files (`core/signatures`
## gives their refusal on an explicit open).
##
## **Survey files.** Text, in 80-column cards. A head (at most `SniffBytes`)
## that holds anything but text (a NUL, control characters, mostly bytes
## above 127) is not one. An SPS file is known by its data records (an `R`
## or `S` record with grid coordinates in columns 47-65, an `X` or `O`
## record with channel numbers in columns 39-48, as parseSEG's
## `looksLikeSps` judges them) or, when the head holds only header records
## (SPS headers are often longer than 4 KiB), by an `H00` record that names
## SPS, or by three header records and a name ending as SPS files do. Which
## records it holds comes from its data records, else from that ending
## (`.s`, `.sps`, `.r`, `.rps`, `.x`, `.xps`, `.ops` ...). A SEG P1 file is
## known by its data records: a blank first column, `N` or `S` in column 35
## and `E` or `W` in column 45. Fixed 80-byte cards without line ends are
## read as such; EBCDIC survey files are not recognised.

import std/[os, strutils]
import parseSEG/common/seismickind
import parseSEG/model/indexwalk
import sigdat, sigtypes, sigvib

type
  FileKind* = enum
    ## What a file holds, as far as its first bytes tell.
    fkUnknown = "unknown"   ## neither seismic nor survey (or too short to tell yet)
    fkSegy = "SEG-Y"
    fkSegd = "SEG-D"
    fkSeg2 = "SEG-2"
    fkSpsSource = "SPS S"   ## SPS source points (S records)
    fkSpsReceiver = "SPS R" ## SPS receiver points (R records)
    fkSpsRelation = "SPS X" ## SPS relations (X or O records)
    fkSps = "SPS"           ## SPS of more than one kind of record, or of no data yet
    fkP1 = "P1"             ## SEG P1 shotpoint positions
    fkDat = "vibrator .dat" ## a vibrator controller's .dat signature file (`core/sigdat`)
    fkVib = "vibrator .vib" ## its .vib signature record (`core/sigvib`)

const
  SignatureFileKinds* = {fkDat, fkVib}
    ## signature files: decoded into SEG-Y in memory when opened (`core/signatures`)
  SeismicKinds* = {fkSegy, fkSegd, fkSeg2, fkDat, fkVib}
  SpsKinds* = {fkSpsSource, fkSpsReceiver, fkSpsRelation, fkSps}
  SurveyKinds* = SpsKinds + {fkP1}

func sweepKindOf*(k: FileKind): SignatureKind =
  ## The signature kind a file kind is; `sgNone` for any other.
  case k
  of fkDat: sgDat
  of fkVib: sgVib
  else: sgNone

func isSeismic*(k: FileKind): bool {.inline.} = k in SeismicKinds
func isSurvey*(k: FileKind): bool {.inline.} = k in SurveyKinds

func fileKind*(k: SeismicKind): FileKind =
  ## The file kind of a seismic standard.
  case k
  of skUnknown: fkUnknown
  of skSegy: fkSegy
  of skSegd: fkSegd
  of skSeg2: fkSeg2

func isText(head: openArray[char]): bool =
  ## Whether `head` reads as text: no NUL or other control character but
  ## tab, line ends, form feed and DOS's end-of-file mark, and at most one
  ## byte in 20 above 127 (accented letters in a comment).
  var high = 0
  for c in head:
    if c < ' ' and c notin {'\t', '\n', '\r', '\f', '\x1A'}: return false
    if c == '\x7F': return false
    if c >= '\x80': inc high
  high * 20 <= head.len

func col(line: openArray[char]; first, last: int): string =
  ## Columns `first .. last` (1-based, as the formats count them) of `line`,
  ## blanks where it is shorter.
  result = newString(last - first + 1)
  for i in first .. last:
    result[i - first] = if i - 1 < line.len: line[i - 1] else: ' '

func number(field: string): bool =
  ## Whether a fixed-width field holds a number (blanks around it).
  let t = field.strip
  if t.len == 0: return false
  try:
    discard parseFloat(t)
    true
  except ValueError:
    false

func digitsOrBlank(field: string): bool =
  field.strip.len > 0 and field.allCharsInSet(Digits + {' '})

const
  SourceEndings = [".s", ".sps", ".src", ".sou", ".shot", ".shp"]
  ReceiverEndings = [".r", ".rps", ".rcv", ".rec"]
  RelationEndings = [".x", ".xps", ".rel", ".ops"]

func spsByName(name: string): FileKind =
  ## The kind of SPS file a name says it is; `fkSps` when it says none.
  let ext = name.splitFile.ext.toLowerAscii
  if ext in SourceEndings: fkSpsSource
  elif ext in ReceiverEndings: fkSpsReceiver
  elif ext in RelationEndings: fkSpsRelation
  else: fkSps

func surveyKind*(head: string; name: string; whole: bool): FileKind =
  ## The survey kind of a file whose first bytes are `head` (all of it with
  ## `whole`, else its last line may be cut short and is left out) and whose
  ## name is `name`; `fkUnknown` when it is not a survey file.
  result = fkUnknown
  var at = 0
  if head.len >= 3 and head[0] == '\xEF' and head[1] == '\xBB' and head[2] == '\xBF': at = 3
  if not isText(head.toOpenArray(at, head.high)): return
  var lines: seq[Slice[int]]
  var hasEnds = false
  block cut:
    var lo = at
    for i in at ..< head.len:
      if head[i] in {'\n', '\r'}:
        hasEnds = true
        if i > lo: lines.add lo ..< i
        lo = i + 1
    if not hasEnds:
      # Fixed 80-byte cards: no line ends at all.
      lo = at
      while lo + 80 <= head.len:
        lines.add lo ..< lo + 80
        lo += 80
    if lo < head.len and whole: lines.add lo ..< head.len
  var points: array[2, int] # S, R
  var relations, p1, headers, comments, others = 0
  var declared = false
  for s in lines:
    let line = head[s.a .. s.b]
    if line.len == 0 or line[0] notin {'H', 'S', 'R', 'X', 'O', 'C', ' '}:
      if line.len > 0 and not line.col(1, line.len).isEmptyOrWhitespace: inc others
    else:
      case line[0]
      of 'H':
        inc headers
        if line.col(2, 3) == "00" and "SPS" in line.col(1, line.len).toUpperAscii:
          declared = true
      of 'S', 'R':
        if number(line.col(47, 55)) and number(line.col(56, 65)):
          inc points[ord(line[0] == 'R')]
        else: inc others
      of 'X', 'O':
        if digitsOrBlank(line.col(39, 48)): inc relations else: inc others
      of 'C': inc comments
      else: # a blank first column: SEG P1 data, or a blank line
        if line.col(35, 35)[0] in {'N', 'S'} and line.col(45, 45)[0] in {'E', 'W'} and
            line.col(27, 34).allCharsInSet(Digits + {' '}):
          inc p1
  let sps = points[0] + points[1] + relations
  if p1 > sps:
    result = fkP1
  elif sps > 0 and sps >= others:
    let kinds = ord(points[0] > 0) + ord(points[1] > 0) + ord(relations > 0)
    result = if kinds > 1: fkSps
             elif points[0] > 0: fkSpsSource
             elif points[1] > 0: fkSpsReceiver
             else: fkSpsRelation
  elif sps == 0 and p1 == 0 and others == 0 and headers > 0 and
      (declared or (headers >= 3 and spsByName(name) != fkSps)):
    # Header records only so far: the name says which records follow.
    result = spsByName(name)

func fileKindOf*(head: openArray[byte]; name: string; whole: bool): FileKind =
  ## What a file whose first bytes are `head` (all of it with `whole`) and
  ## whose name is `name` holds. Text is never seismic (a SEG-Y file's head
  ## holds its binary header), so a survey file whose comments start with
  ## `C`, as a SEG-Y textual header does, is still a survey file.
  if head.len == 0: return fkUnknown
  var text = newString(head.len)
  copyMem(addr text[0], addr head[0], head.len)
  result = surveyKind(text, name, whole)
  if result == fkUnknown:
    # The signature kinds are told before parseSEG's `detectKind`, which takes some of their
    # bytes for a SEG-Y header. Their own tests are strict (a checksummed first block, `VIB` and
    # 11 and a date), and none of the SEG samples passes them (`tests/tdatopen`, `tvibopen`).
    result = case datKind(head)
      of sgDat: fkDat
      else: (if vibKindOf(head) == sgVib: fkVib else: fkUnknown)
  if result == fkUnknown: result = fileKind(detectKind(head))
