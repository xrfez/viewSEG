## How the Shot log grid is laid out: which columns are shown, in which order and how
## wide, and what the rows are sorted by. Kept by column name (the header's fitted name,
## "Column N" where there is none), so a log read again with the same headers gets its
## layout back; a column the layout does not know goes to the end, shown. The layout is
## stored with the log's map in the project, and, for every log, in the settings as the
## last layout for that set of headers. A layout never changes the log, its rows or
## their numbers.

import nif

const
  MaxLayoutColumns* = 512    ## columns of one layout that are kept
  MaxLayoutSort* = 8         ## sort keys of one layout that are kept
  MaxSavedLayouts* = 32      ## header sets the settings keep a layout for
  DefaultColumnEm* = 8.0'f32 ## a column's width, in font sizes, until it is changed

type
  ShotColumnLayout* = object
    name*: string
    hidden*: bool
    width*: float32 ## in font sizes; 0 for the default

  ShotSortKey* = tuple[name: string, descending: bool]

  ShotLayout* = object
    columns*: seq[ShotColumnLayout] ## in the order shown
    sort*: seq[ShotSortKey]         ## first key first

  SavedShotLayout* = object
    headers*: string ## `headerKey` of the log's columns
    layout*: ShotLayout

  ColumnPlace* = object
    ## One column of a log as the grid places it.
    col*: int       ## the log's column
    hidden*: bool
    width*: float32 ## in font sizes

func isDefault*(l: ShotLayout): bool =
  l.columns.len == 0 and l.sort.len == 0

func columnKey*(name: string; col: int): string =
  ## The name a column is kept under: its header name, or "Column N".
  if name.len > 0: name else: "Column " & $(col + 1)

func headerKey*(names: openArray[string]): string =
  ## One text for a whole set of header names, in order.
  for i, n in names:
    if i > 0: result.add '\x1f'
    result.add columnKey(n, i)

func places*(l: ShotLayout; keys: openArray[string]; eligible: openArray[bool]): seq[ColumnPlace] =
  ## The columns of a log whose column keys are `keys` (`columnKey`), in the order
  ## shown: those the layout names first, in its order (each name taking the first
  ## column of that name not taken yet), then the others in file order, shown. A column
  ## that is not `eligible` (mapped to Ignore) is left out.
  var taken = newSeq[bool](keys.len)
  for lc in l.columns:
    for c in 0 ..< keys.len:
      if not taken[c] and keys[c] == lc.name:
        taken[c] = true
        if eligible[c]:
          result.add ColumnPlace(col: c, hidden: lc.hidden, width: lc.width)
        break
  for c in 0 ..< keys.len:
    if not taken[c] and eligible[c]:
      result.add ColumnPlace(col: c, width: 0)

func sortColumns*(l: ShotLayout; keys: openArray[string]):
    seq[tuple[col: int, descending: bool]] =
  ## The sort as the log's columns; a key that names no column is dropped, and a column
  ## is a key once.
  var used = newSeq[bool](keys.len)
  for k in l.sort:
    for c in 0 ..< keys.len:
      if not used[c] and keys[c] == k.name:
        used[c] = true
        result.add (col: c, descending: k.descending)
        break

func layoutFrom*(placed: openArray[ColumnPlace]; keys: openArray[string];
    sort: openArray[tuple[col: int, descending: bool]]): ShotLayout =
  ## The layout that places `placed` and sorts by `sort`.
  for p in placed:
    if result.columns.len < MaxLayoutColumns:
      result.columns.add ShotColumnLayout(name: keys[p.col], hidden: p.hidden, width: p.width)
  for s in sort:
    if result.sort.len < MaxLayoutSort:
      result.sort.add (name: keys[s.col], descending: s.descending)

func remember*(saved: var seq[SavedShotLayout]; headers: string; layout: ShotLayout) =
  ## Keeps `layout` as the last for `headers`, the newest first; the oldest go when there
  ## are more than `MaxSavedLayouts`. A default layout removes the entry.
  if headers.len == 0: return
  var at = -1
  for i, s in saved:
    if s.headers == headers: at = i
  if at >= 0: saved.delete at
  if layout.isDefault: return
  saved.insert(SavedShotLayout(headers: headers, layout: layout), 0)
  if saved.len > MaxSavedLayouts: saved.setLen MaxSavedLayouts

func layoutFor*(saved: openArray[SavedShotLayout]; headers: string): ShotLayout =
  ## The layout kept for `headers`, or the default.
  for s in saved:
    if s.headers == headers: return s.layout

# ----------------------------------------------------------------- NIF --

proc writeLayout*(w: var NifWriter; l: ShotLayout) =
  ## `(layout (sort "name" asc|desc) ... (col "name" width [hidden]) ...)`; nothing for
  ## a default layout.
  if l.isDefault: return
  w.open "layout"
  for k in l.sort:
    w.open "sort"
    w.add k.name
    w.ident(if k.descending: "desc" else: "asc")
    w.close
  for c in l.columns:
    w.open "col"
    w.add c.name
    w.add float64(c.width)
    if c.hidden: w.ident "hidden"
    w.close
  w.close

func readLayout*(n: NifNode): ShotLayout =
  ## The layout `n` (a `layout` node) holds; what cannot be used is left out.
  for k in n.kids:
    if k.kind != nkTree or k.kids.len < 1 or k.kids[0].kind != nkString: continue
    let name = k.kids[0].text
    if name.len == 0 or name.len > 256: continue
    case k.tag
    of "sort":
      if result.sort.len < MaxLayoutSort:
        result.sort.add (name: name,
          descending: k.kids.len > 1 and k.kids[1].kind == nkIdent and k.kids[1].text == "desc")
    of "col":
      if result.columns.len < MaxLayoutColumns:
        var c = ShotColumnLayout(name: name)
        for v in k.kids[1 .. ^1]:
          case v.kind
          of nkFloat:
            if v.floatVal >= 0 and v.floatVal < 1000: c.width = float32(v.floatVal)
          of nkInt:
            if v.intVal >= 0 and v.intVal < 1000: c.width = float32(v.intVal)
          of nkIdent: c.hidden = v.text == "hidden"
          else: discard
        result.columns.add c
    else: discard
