## The edit state of a SEG-Y binary header set (`core/outputbinary`) in the
## Output window: the name, one value text for each settable field (empty:
## not set), the filter and the "only fields that are set" switch, the note
## each field shows, and the set the values make. No toolkit: the window only
## draws it. Saving, deleting and choosing a set are commands; nothing here
## changes a project.

import std/[strutils, unicode]
import ../core/outputbinary

const
  BinaryRowLabel* = "Binary header"
  BinaryAsSource* = "From the source or library default"
  BinaryEditButton* = "Edit..."
  BinaryRowTip* = "Values for fields of the SEG-Y binary file header of each file written: " &
    "a set of the project. None: a copy of a SEG-Y file keeps its own binary header and a " &
    "new file gets the library's own."
  BinaryEditTip* = "Make or change a binary header set of the project."
  BinaryWindowTitle* = "Binary header set###output.binary"
  BinaryNameHint* = "Name of this set"
  BinaryNameTip* = "The name the project keeps this set by."
  BinaryFilterHint* = "Filter the fields"
  BinaryFilterTip* = "Show only the fields whose name has these letters in it."
  BinaryOnlySetLabel* = "Only fields that are set"
  BinaryOnlySetTip* = "Hide the fields with no value."
  BinaryValueTip* = "A number. Empty: the field is not set, and the file keeps the value of " &
    "its source or the library's."
  BinColField* = "Field"
  BinColBytes* = "Bytes"
  BinColValue* = "Value"
  BinColShown* = "In the shown file"
  BinColNote* = "Note"
  BinShownTip* = "The value in the binary header of the file the Seismic window shows."
  BinShownReading* = "The shown file's values are being read."
  BinShownNone* = "No SEG-Y file is shown."
  BinSaveTip* = "Keep this set in the project under this name, replacing the one of that " &
    "name, and use it."
  BinSaveNewTip* = "Keep this set as a new one and use it. The name must be new."
  BinDeleteTip* = "Remove the set of this name from the project."
  BinCancelTip* = "Close without changing the project. Esc does the same."
  BinaryNeedProject* = "Open or make a writable project to keep binary header sets."
  BinaryReadOnly* = "The project is open read-only: binary header sets cannot be kept."
  BinNameTaken* = "A set of this name is kept already; Save replaces it."
  BinNothingToDelete* = "No set of this name is kept."
  BinNoFieldsShown* = "No field matches."
  Rev2Note* = "SEG-Y revision 2 only"
  ValueCapacity* = 40 ## characters a value box holds

type
  BinaryEdit* = object
    ## The set being edited. `original` is the name it was loaded under ("" for
    ## a new one). `values` follows `BinaryFields`.
    name*: string
    original*: string
    values*: seq[string]
    filter*: string
    onlySet*: bool

  FieldNote* = object
    text*: string ## "" when the field has nothing to say
    warn*: bool   ## a problem or a value that will not be written, not just a remark

func initBinaryEdit*(): BinaryEdit =
  ## A new set: no name, no value.
  BinaryEdit(values: newSeq[string](BinaryFields.len))

func initBinaryEdit*(b: OutputBinary): BinaryEdit =
  result = initBinaryEdit()
  result.name = b.name
  result.original = b.name
  for e in b.entries:
    for i, f in BinaryFields:
      if f.name == e.field: result.values[i] = e.value

func toSet*(e: BinaryEdit): OutputBinary =
  ## The set the values make: every field with a value, in file order.
  result = OutputBinary(name: strip(e.name))
  for i, f in BinaryFields:
    if i < e.values.len and strip(e.values[i]).len > 0:
      result.entries.add BinaryEntry(field: f.name, value: strip(e.values[i]))

func problem*(e: BinaryEdit): string =
  ## Why the set cannot be kept; "" when it can (`binaryProblem`).
  binaryProblem(e.toSet)

func isSet*(e: BinaryEdit; i: int): bool =
  i < e.values.len and strip(e.values[i]).len > 0

func setCount*(e: BinaryEdit): int =
  for i in 0 ..< BinaryFields.len:
    if e.isSet(i): inc result

func setNote*(e: BinaryEdit): string =
  ## "3 fields set", under the table.
  let n = e.setCount
  $n & (if n == 1: " field set" else: " fields set")

func bytesLabel*(f: BinaryFieldInfo): string =
  ## The file bytes the field covers, as `3225-3226`.
  $f.firstByte & "-" & $(f.firstByte + f.bytes - 1)

func isShown*(e: BinaryEdit; i: int): bool =
  ## Whether field `i` is in the table now: its name or label has the filter's
  ## letters (case ignored), and it has a value when only those are shown.
  let f = BinaryFields[i]
  let want = toLower(strip(e.filter))
  result = (want.len == 0 or toLower(f.name).contains(want) or
    toLower(f.label).contains(want)) and (not e.onlySet or e.isSet(i))

func shownCount*(e: BinaryEdit): int =
  for i in 0 ..< BinaryFields.len:
    if e.isShown(i): inc result

func fieldNote*(e: BinaryEdit; i: int): FieldNote =
  ## What the table says of field `i` beside its value: why the value is not
  ## one, then that a Rev 2 field is written only to a Rev 2 file, then that
  ## its Rev 2 twin replaces it.
  let f = BinaryFields[i]
  if not e.isSet(i):
    if f.rev2: result.text = Rev2Note
    return
  let why = valueProblem(f, e.values[i])
  if why.len > 0: return FieldNote(text: why, warn: true)
  if f.rev2: return FieldNote(text: Rev2Note, warn: true)
  let twin = twinOf(f.name)
  if twin.len > 0:
    for j, g in BinaryFields:
      if g.name == twin and e.isSet(j) and valueProblem(g, e.values[j]).len == 0 and
          strip(e.values[j]) notin ["0", "0.0"]:
        return FieldNote(text: "replaced by " & g.label & " in SEG-Y revision 2, as that is set",
          warn: true)

func clearValues*(e: var BinaryEdit) =
  for v in e.values.mitems: v = ""

func matchingSet*(names: openArray[string]; name: string): bool =
  ## Whether `names` holds a set called `name` (spaces stripped, case ignored).
  let want = toLower(strip(name))
  for n in names:
    if toLower(strip(n)) == want: return true
