## Which rows of the Shot log grid are the chosen ones, which it lists with "Only selected",
## and when it scrolls to them. The choice is the program's (`ShotRows`: from the map, an
## agent or a click in the grid); the pointer is the map's or the plot's. It follows the
## pointer as the Headers window's Trace tab does (`chosenTraces`): the selection first; with
## none, and "Follow the pointer" on, what the pointer is over; with that off, only the
## selection, and the grid never moves by itself.

import std/algorithm

const
  OnlySelected* = "Only selected"
  OnlySelectedTip* = "Show only the selected rows."
  NoRowsSelected* = "No rows are selected."
  FollowPointer* = "Follow the pointer"
  FollowPointerTip* = "Scroll the grid to the selected rows when the selection changes, and, " &
    "with no row selected, to the rows of the shot under the pointer on the map (the trace " &
    "under the pointer in the plot is Follow the plot's). Off: the grid never scrolls by itself."

type
  RowsBy* = enum
    rbNone = "none"
    rbSelection = "selection"
    rbPointer = "pointer"

  ChosenRows* = object
    by*: RowsBy
    rows*: seq[int] ## ascending, each once

  ScrollKey* = tuple[by: RowsBy, first, revision: int]
    ## What the grid last scrolled for: who chose, the first row, and the choice's revision.

func nextShown*(shown: openArray[int]; col: int): int =
  ## The first of the `shown` columns (ascending: those the grid shows, which
  ## leaves out an ignored one) after `col`, or -1. Tab moves to it.
  result = -1
  for c in shown:
    if c > col: return c

func nextInOrder*(order: openArray[int]; col: int): int =
  ## The column after `col` in `order` (the columns as the grid shows them, which the
  ## user may have rearranged), or -1 when `col` is last or not shown. Tab moves to it.
  result = -1
  for k, c in order:
    if c == col:
      if k + 1 < order.len: result = order[k + 1]
      break

func sortedUnique(rows: openArray[int]): seq[int] =
  result = @rows
  result.sort()
  var kept = 0
  for r in result:
    if kept == 0 or result[kept - 1] != r:
      result[kept] = r
      inc kept
  result.setLen kept

func chosenRows*(selected, pointed: openArray[int]; followPointer: bool): ChosenRows =
  ## The rows the grid marks: the selected ones; with none and `followPointer`, those the
  ## pointer is over.
  if selected.len > 0: ChosenRows(by: rbSelection, rows: sortedUnique(selected))
  elif followPointer and pointed.len > 0:
    ChosenRows(by: rbPointer, rows: sortedUnique(pointed))
  else: ChosenRows(by: rbNone)

func isChosen*(c: ChosenRows; row: int): bool =
  ## Whether `row` is one of the chosen rows.
  c.rows.binarySearch(row) >= 0

func scrollKey*(c: ChosenRows; revision: int): ScrollKey =
  ## The key of the choice `c` at the selection's `revision` (a pointer's choice has none).
  if c.rows.len == 0: (rbNone, -1, 0)
  else: (c.by, c.rows[0], if c.by == rbSelection: revision else: 0)

func scrollsTo*(was, now: ScrollKey; followPointer: bool): bool =
  ## Whether the grid scrolls to the first chosen row: only with "Follow the pointer" on, and
  ## only when the choice changed.
  followPointer and now.by != rbNone and now != was

proc onlySelected*(selected: openArray[int]; n: int; hidden: proc (row: int): bool): seq[int] =
  ## The rows the grid lists with "Only selected": the selected rows of the `n` the log
  ## has that the other filters (`hidden`) leave in, ascending. Filtering never changes the
  ## selection.
  for r in sortedUnique(selected):
    if r in 0 ..< n and not hidden(r): result.add r

func countText*(listed, total: int): string =
  ## "3 of 1200 rows".
  $listed & " of " & $total & (if total == 1: " row" else: " rows")
