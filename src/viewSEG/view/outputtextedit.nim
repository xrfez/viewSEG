## The edit state of a SEG-Y text header template (`core/outputtext`) in the
## Output window: the name, the character set and the lines as one text, the
## token a person inserts, the limits and problems, and the preview filled in
## for the file shown. No toolkit: the window only draws it. Saving, deleting
## and choosing a template are commands; nothing here changes a project.

import std/[strutils, times, unicode]
import parseSEG
import ../core/[edits, outputnames, outputnamevalues, outputtext, sigtypes, vendormaps]

const
  TextRowLabel* = "Text header"
  TextAsSource* = "From the source or library default"
  TextEditButton* = "Edit..."
  TextRowTip* = "The SEG-Y text header of each file written: a template of the project, " &
    "filled in for that file. None: a copy of a SEG-Y file keeps its own text header and " &
    "a new file gets the library's own."
  TextEditTip* = "Make or change a text header template of the project."
  TextWindowTitle* = "Text header template###output.text"
  TextNameHint* = "Name of this template"
  TextNameTip* = "The name the project keeps this template by."
  CharsetLabel* = "Character set"
  CharsetEbcdic* = "EBCDIC"
  CharsetAscii* = "ASCII"
  CharsetTip* = "How the header is written in the file. EBCDIC is the traditional one. " &
    "A copy of a SEG-Y file is written in the character set of its source."
  LinesTip* = "One card a line: at most 38 lines of 80 characters (cards 39 and 40 are " &
    "always written by the library). A word in braces is filled in for each file."
  InsertToken* = "Insert a token"
  InsertTip* = "Put a token at the cursor of the lines above, or at the end when the " &
    "cursor was not in them."
  PreviewLabel* = "Preview"
  PreviewSample* = "No file is shown: sample values are filled in."
  PreviewReading* = "The file's values are being read: sample values are filled in."
  PreviewTitle* = "Read the shown file's values for a text header"
  PreviewTooBig* = "The file has too many traces to read here: sample values are filled in."
  SaveButton* = "Save"
  SaveNewButton* = "Save as new"
  DeleteButton* = "Delete"
  CancelButton* = "Cancel"
  SaveTip* = "Keep this template in the project under this name, replacing the one of " &
    "that name, and use it."
  SaveNewTip* = "Keep this template as a new one and use it. The name must be new."
  DeleteTip* = "Remove the template of this name from the project."
  CancelTip* = "Close without changing the project. Esc does the same."
  TextNeedProject* = "Open or make a writable project to keep text header templates."
  TextReadOnly* = "The project is open read-only: text header templates cannot be kept."
  NameTaken* = "A template of this name is kept already; Save replaces it."
  NothingToDelete* = "No template of this name is kept."
  PreviewLimit* = 200_000 ## traces of a shown file read to fill the preview in
  TextCapacity* = 12288   ## characters the lines box holds

type
  TextEdit* = object
    ## The template being edited. `original` is the name it was loaded under
    ## ("" for a new one).
    name*: string
    encoding*: TextEncoding
    text*: string ## the lines, one `\n` between two
    original*: string

  TextPreview* = object
    lines*: seq[string] ## the filled-in lines, trailing blank ones left out
    problem*: string
    sample*: bool       ## sample values, not the shown file's

func initTextEdit*(t: OutputText): TextEdit =
  TextEdit(name: t.name, encoding: t.encoding, text: t.lines.join("\n"), original: t.name)

func initTextEdit*(): TextEdit =
  ## A new template: no name, EBCDIC, no lines.
  TextEdit(encoding: teEbcdic)

func trimmedLines*(text: string): seq[string] =
  ## The lines of `text` as typed, a carriage return dropped, the blank lines
  ## at the end left out.
  result = text.replace("\r", "").split('\n')
  while result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

func toTemplate*(e: TextEdit): OutputText =
  OutputText(name: strip(e.name), encoding: e.encoding, lines: trimmedLines(e.text))

func problem*(e: TextEdit): string =
  ## Why the template cannot be kept; "" when it can (`textProblem`).
  textProblem(e.toTemplate)

func charsetWord*(encoding: TextEncoding): string =
  if encoding == teAscii: CharsetAscii else: CharsetEbcdic

func insertToken*(e: var TextEdit; word: string; cursor: int): int =
  ## Puts `{word}` into the text at byte `cursor`, or at the end when `cursor`
  ## is outside the text (-1: unknown). Returns the cursor after the token.
  ## A cursor inside a character moves back to its start.
  var at = if cursor < 0 or cursor > e.text.len: e.text.len else: cursor
  while at > 0 and at < e.text.len and (ord(e.text[at]) and 0xC0) == 0x80: dec at
  let piece = "{" & word & "}"
  e.text.insert(piece, at)
  at + piece.len

func lineCount*(e: TextEdit): int = trimmedLines(e.text).len

func longestLine*(e: TextEdit): int =
  for line in trimmedLines(e.text): result = max(result, line.runeLen)

func lengthNote*(e: TextEdit): string =
  ## "3 of 38 lines, the longest 42 of 80 characters."
  $e.lineCount & " of " & $MaxTextLines & " lines, the longest " & $e.longestLine &
    " of " & $MaxTextLine & " characters."

func columnRuler*(): string =
  ## One mark a column over `MaxTextLine` columns: the tens as digits, the
  ## fives as `+`, the rest `.`; column 1 is the first character.
  for col in 1 .. MaxTextLine:
    result.add(if col mod 10 == 0: char(ord('0') + (col div 10) mod 10)
               elif col mod 5 == 0: '+' else: '.')

func tokenLabel*(info: TextTokenInfo): string =
  "{" & info.word & (if info.width: ":n" else: "") & "}"

func num(x: float64): NameValue = NameValue(state: nvNumber, number: x)
func whole(n: int64): NameValue = NameValue(state: nvInt, intValue: n)

func sampleValues*(writtenUs: int64): TextValues =
  ## Values that show a template's shape when no file is shown.
  result.source = "file.sgy"
  result.writtenUs = writtenUs
  result.values[npStem] = NameValue(state: nvText, text: "file")
  result.values[npRecord] = num(7)
  result.values[npSrcLine] = num(12)
  result.values[npRcvLine] = num(12)
  result.values[npSrcPoint] = num(1034.5)
  result.values[npRcvPoint] = num(1034.5)
  result.values[npSrcIndex] = whole(1)
  result.values[npRcvIndex] = whole(1)
  result.values[npSystemSerial] = whole(4521)
  result.values[npController] = whole(1)
  result.values[npVibrator] = whole(1)
  result.values[npFileNumber] = whole(7)
  result.values[npSigLine] = num(12)
  result.values[npSigStation] = num(1034.5)
  result.values[npShotId] = whole(7)
  result.values[npSweepId] = whole(1)
  result.values[npSensorSerial] = NameValue(state: nvText, text: "S1042")
  result.values[npTime] = NameValue(state: nvTimeUs, timeUs: 1_718_454_645_000_000'i64,
    wholeSeconds: true)

proc nowUs*(): int64 =
  let t = getTime()
  t.toUnix * 1_000_000 + int64(t.nanosecond div 1000)

func wantedParts*(e: TextEdit): set[NamePartKind] =
  ## The parts the file's values must be read for: only the sensor serial is
  ## read on request.
  if "{sensorSerial" in e.text: result.incl npSensorSerial

proc previewOf*(e: TextEdit; v: TextValues; sample: bool): TextPreview =
  ## The lines of `e` filled in from `v`, and why they cannot be written.
  result.sample = sample
  let t = e.toTemplate
  result.lines = render(t, v)
  while result.lines.len > 0 and strip(result.lines[^1]).len == 0:
    result.lines.setLen(result.lines.len - 1)
  result.problem = renderProblem(t, v)

func matchingName*(names: openArray[string]; name: string): bool =
  ## Whether `names` holds a template called `name` (spaces stripped, case ignored).
  let want = toLower(strip(name))
  for n in names:
    if toLower(strip(n)) == want: return true

proc valuesOfFile*(file: SeismicFile; source: string; facts: SignatureFacts;
    edits: FileEdits; e: TextEdit): tuple[ok: bool; values: TextValues; why: string] =
  ## What the shown file gives the tokens, as the write takes them (killed
  ## traces dropped). Reads only keys already in memory; not ok, with the
  ## sentence for the preview, when there are none or too many to read here.
  result.ok = false
  if not file.isOpen or not file.hasKeys: result.why = PreviewSample
  elif file.len > PreviewLimit: result.why = PreviewTooBig
  else:
    result.ok = true
    result.values = textValuesOf(file, source, facts, edits, true, nowUs(), nil,
      e.wantedParts, currentVendors())
