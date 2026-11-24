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
## (`vendorStamp`). A text field has no number: its column is empty and its
## line shows unknown.

import std/[sets, tables]
import parseSEG
import filesystem, panels, sorting, vendormaps

type
  VendorLines* = object
    ## The columns of the vendor fields shown, by name, for one file.
    stamp: int                          ## the vendor maps' load they were read with
    columns: Table[string, seq[float64]] ## empty: no numbers (unknown name, text, no map)
    absent: Table[string, int]          ## per name, the traces without a value

func valueAt*(v: VendorLines; name: string; trace: int): float64 =
  ## Vendor field `name` of file trace `trace`; NaN when it has none (or when
  ## the column was not built, or does not reach).
  let col = v.columns.getOrDefault(name)
  if trace in 0 ..< col.len: col[trace] else: NaN

func has*(v: VendorLines; name: string): bool =
  ## Whether the column of `name` was built (it may hold no value).
  name in v.columns

func absentCount*(v: VendorLines; name: string): int =
  ## The traces of the file without a value for `name`; 0 when not built.
  v.absent.getOrDefault(name)

func vendorNames*(fields: openArray[HeaderRef]): seq[string] =
  ## The vendor fields among `fields`, each once, in order.
  var seen = initHashSet[string]()
  for f in fields:
    if f.field == hfVendor and f.name notin seen:
      seen.incl f.name
      result.add f.name

proc drop*(v: var VendorLines) =
  ## Forgets every column (the file closed or another one is shown).
  v = VendorLines()

proc build*(v: var VendorLines; f: ptr SeismicFile; path: string; names: openArray[string];
    stop: StopProc = nil): bool =
  ## Builds the columns of `names` that are not held, from `f` (read from
  ## `path`) with the vendor maps in force; columns of an older load of the
  ## maps are dropped first. A name no map defines for the file, a text
  ## field, or a file that cannot be read gives an empty column, kept so that
  ## it is not asked for again. False when `stop` said to give up (nothing
  ## of the column then in progress is kept).
  let stamp = vendorStamp()
  if stamp != v.stamp:
    v = VendorLines(stamp: stamp)
  var reg: VendorRegistry
  var haveReg = false
  for name in names:
    if name in v.columns: continue
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
    except CatchableError: discard # unknown or ambiguous name, a cut file, a drive gone
    v.columns[name] = col
    v.absent[name] = absent
  true
