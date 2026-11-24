## The values of vendor fields shown on a display line, one column per field
## name for an open file.
##
## A display line chosen from a vendor map (`hfVendor`, `HeaderRef.name`) has
## its values in a column read from the file's trace and record headers by
## parseSEG's `vendorColumn`: a record-level field is spread to each trace of
## its record, and a trace without a value is NaN, which the line shows as
## unknown (never 0). The columns are kept in a `VendorLines`, which a reader
## builds on its own thread on the first request that has such a line, and
## drops when its file changes or the vendor maps are loaded again
## (`vendorStamp`). A text field has no number: its column is
## empty and its line shows unknown.
##
## A tile looks each line's column up once (`slot`) and reads its rows by
## slot (`valueAt`): no column is copied.

import std/[atomics, sets, tables]
import parseSEG
import filesystem, panels, sorting, vendormaps

var built: Atomic[int]

proc columnsBuilt*(): int =
  ## How many columns have been read from files so far (all readers): a test's
  ## way to see a column is built once, not at every step.
  built.load(moRelaxed)

type
  VendorLines* = object
    ## The columns of the vendor fields shown, by name, for one file: kept
    ## while the file (its address, path, size and trace count) and the maps'
    ## load stay the same, whatever record or order is shown.
    file: pointer
    path: string
    size: int64
    traces: int
    stamp: int ## the vendor maps' load they were read with
    slots: Table[string, int] ## per name, its column in `columns` and `absent`
    columns: seq[seq[float64]] ## empty: no numbers (unknown name, text, no map)
    absent: seq[int] ## the traces without a value
    missing: seq[string] ## names the file has no vendor field of, not yet said

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

func vendorNames*(fields: openArray[HeaderRef]): seq[string] =
  ## The vendor fields among `fields`, each once, in order.
  var seen = initHashSet[string]()
  for f in fields:
    if f.field == hfVendor and f.name notin seen:
      seen.incl f.name
      result.add f.name

proc takeMissing*(v: var VendorLines): seq[string] =
  ## The names found to be no vendor field of the file since the last call (each is
  ## said once while the file and the maps stay the same).
  result = move v.missing

proc drop*(v: var VendorLines) =
  ## Forgets every column (the file closed or another one is shown).
  v = VendorLines()

proc put(v: var VendorLines; name: string; col: sink seq[float64]; absent: int) =
  v.slots[name] = v.columns.len
  v.columns.add col
  v.absent.add absent

proc build*(v: var VendorLines; f: ptr SeismicFile; path: string; size: int64;
    names: openArray[string]; stop: StopProc = nil): bool =
  ## Builds the columns of `names` that are not held, from `f` (read from
  ## `path`, `size` bytes when it was opened) with the vendor maps in force; columns of another file, or of an older load of the
  ## maps, are dropped first. A name no map defines for the file, a text
  ## field, or a file that cannot be read gives an empty column, kept so that
  ## it is not asked for again. False when `stop`
  ## said to give up (nothing of the column then in progress is kept).
  let stamp = vendorStamp()
  if stamp != v.stamp or pointer(f) != v.file or path != v.path or size != v.size or
      f[].len != v.traces:
    v = VendorLines(stamp: stamp, file: pointer(f), path: path, size: size, traces: f[].len)
  var reg: VendorRegistry
  var haveReg = false
  for name in names:
    if name in v.slots: continue
    if not haveReg:
      reg = currentVendors()
      haveReg = true
    var col: seq[float64] = @[]
    var absent = 0
    try:
      if not f[].inMemory: fs.mappedRead(path, headers = true)
      var c: VendorColumn
      {.cast(gcsafe).}: # (parseSEG's `stop` is not typed gcsafe; ours is, and touches no global)
        c = f[].vendorColumn(reg, name, proc (): bool = stop != nil and stop())
      if c.stopped: return false
      if c.kind in {vvInt, vvFloat}:
        col = c.numbers
        absent = c.absent
    except ValueError: # unknown or ambiguous name
      v.missing.add name
    except CatchableError: discard # a cut file, a drive gone
    built.atomicInc
    v.put(name, col, absent)
  true
