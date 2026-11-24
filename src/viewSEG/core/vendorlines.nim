## The values of vendor fields shown on a display line, one column per field
## name for an open file.
##
## A display line chosen from a vendor map (`hfVendor`, `HeaderRef.name`) has
## its values in a column read from the file's trace and record headers by
## parseSEG's `vendorColumn`: a record-level field is spread to each trace of
## its record, and a trace without a value is NaN, which the line shows as
## unknown (never 0). The columns are kept in a `VendorLines`, which a reader
## builds on its own thread on the first request that has such a line, and
## drops when it shows another open file (`SessionId`, never reused, so a file
## closed, rewritten and opened again is read again) or the vendor maps are
## loaded again (`vendorStamp`). A text field has no number: its column is
## empty and its line shows unknown.
##
## A tile looks each line's column up once (`slot`) and reads its rows by
## slot (`valueAt`): no column is copied.

import std/[atomics, os, strutils, tables]
import parseSEG
import filesystem, panels, session, sorting, vendormaps

var built, held: Atomic[int]

proc columnsBuilt*(): int =
  ## How many columns have been read from files so far (all readers): a test's
  ## way to see a column is built once, not at every step.
  built.load(moRelaxed)

proc columnsHeld*(): int =
  ## How many columns are held now, counted when one is built and when its
  ## `VendorLines` is dropped (a reader drops its own when it shows another
  ## file, nothing, or ends): a test's way to see a closed file's are let go.
  held.load(moRelaxed)

type
  VendorLines* = object
    ## The columns of the vendor fields shown, by name, for one open file:
    ## kept while the file (its session, path, size and trace count) and the
    ## maps' load stay the same, whatever record or order is shown.
    session: SessionId
    path: string
    size: int64
    traces: int
    stamp: int ## the vendor maps' load they were read with
    slots: Table[string, int] ## per name, its column in `columns` and `absent`
    columns: seq[seq[float64]] ## empty: no numbers (unknown name, text, no map)
    absent: seq[int] ## the traces without a value
    notes: seq[string] ## what was found of a name, not yet said

func session*(v: VendorLines): SessionId {.inline.} =
  ## The open file the columns are of; `NoSession` when none is held.
  v.session

func slot*(v: VendorLines; name: string): int =
  ## Where the column of `name` is held, for `valueAt`; -1 when not built.
  v.slots.getOrDefault(name, -1)

func valueAt*(v: VendorLines; slot, trace: int): float64 {.inline.} =
  ## The value at file trace `trace` of the column in `slot` (`slot`); NaN
  ## when it has none (or when `slot` is -1, or the column does not reach).
  if slot in 0 ..< v.columns.len and trace in 0 ..< v.columns[slot].len:
    v.columns[slot][trace]
  else: NaN

func valueAt*(v: VendorLines; name: string; trace: int): float64 =
  ## Vendor field `name` of file trace `trace`; NaN when it has none (or when
  ## the column was not built, or does not reach).
  v.valueAt(v.slot(name), trace)

func has*(v: VendorLines; name: string): bool =
  ## Whether the column of `name` was built (it may hold no value).
  name in v.slots

func absentCount*(v: VendorLines; name: string): int =
  ## The traces of the file without a value for `name`; 0 when not built.
  let s = v.slot(name)
  if s < 0: 0 else: v.absent[s]

func hasVendorLine*(fields: openArray[HeaderRef]): bool =
  ## Whether a vendor field is among `fields` (allocates nothing).
  for f in fields:
    if f.field == hfVendor: return true
  false

func vendorNames*(fields: openArray[HeaderRef]): seq[string] =
  ## The vendor fields among `fields`, each once, in order (a display header
  ## has at most `MaxHeaderLines`); empty, unallocated, when there is none.
  for f in fields:
    if f.field == hfVendor and f.name notin result: result.add f.name

proc takeNotes*(v: var VendorLines): seq[string] =
  ## What was found of the names since the last call, in words (a name the
  ## file has no vendor field of, a field that could not be read, a text
  ## field): each is said once while the file and the maps stay the same.
  result = move v.notes

proc drop*(v: var VendorLines) =
  ## Forgets every column (the file closed or another one is shown).
  discard held.fetchSub(v.columns.len, moRelaxed)
  v = VendorLines()

proc put(v: var VendorLines; name: string; col: sink seq[float64]; absent: int) =
  v.slots[name] = v.columns.len
  v.columns.add col
  v.absent.add absent
  held.atomicInc

func listed(fields: openArray[VendorFieldInfo]; name: string): bool =
  # Whether `name` names one of `fields`, also as an element `name[i]`.
  let cut = if name.endsWith(']'): name.rfind('[') else: -1
  for f in fields:
    if f.name == name or (cut > 0 and name.toOpenArray(0, cut - 1) == f.name): return true
  false

proc build*(v: var VendorLines; f: ptr SeismicFile; session: SessionId; path: string;
    size: int64; names: openArray[string]; stop: StopProc = nil): bool =
  ## Builds the columns of `names` that are not held, from `f` (open file
  ## `session`, read from `path`, `size` bytes when it was opened) with the
  ## vendor maps in force; columns of another file, or of an older load of the
  ## maps, are dropped first, and so are all when `session` is `NoSession`
  ## (a file not known to be the same is read again). A name no map defines for the file, a text
  ## field, or a file that cannot be read gives an empty column, kept so that
  ## it is not asked for again, and a note (`takeNotes`). False when `stop`
  ## said to give up (nothing of the column then in progress is kept).
  let stamp = vendorStamp()
  if session == NoSession or session != v.session or stamp != v.stamp or path != v.path or
      size != v.size or f[].len != v.traces:
    v.drop()
    v = VendorLines(stamp: stamp, session: session, path: path, size: size, traces: f[].len)
  var reg: VendorRegistry
  var haveReg = false
  for name in names:
    if name in v.slots: continue
    if not haveReg:
      reg = currentVendors()
      haveReg = true
    var col: seq[float64] = @[]
    var absent = 0
    let file = path.extractFilename
    try:
      if not f[].inMemory: fs.mappedRead(path, headers = true)
      var c: VendorColumn
      {.cast(gcsafe).}: # (parseSEG's `stop` is not typed gcsafe; ours is, and touches no global)
        c = f[].vendorColumn(reg, name, proc (): bool = stop != nil and stop())
      if c.stopped: return false
      if c.kind in {vvInt, vvFloat}:
        col = c.numbers
        absent = c.absent
      else:
        v.notes.add "The vendor field '" & name & "' is text; a display line shows " &
          "numbers, so it shows as unknown."
    except ValueError as e: # an unknown or ambiguous name, or a field that cannot be read
      var fields: seq[VendorFieldInfo] = @[]
      try: fields = reg.vendorFieldNames(f[])
      except ValueError: discard # (no vendor field: a SEG-2 file)
      if fields.listed(name):
        v.notes.add "The vendor field '" & name & "' could not be read from " & file & ": " &
          e.msg & ". It shows as unknown."
      else:
        v.notes.add "'" & name & "' is not a header line or a vendor field of " & file &
          ": it shows as unknown."
    except CatchableError: discard # a cut file, a drive gone
    built.atomicInc
    v.put(name, col, absent)
  true
