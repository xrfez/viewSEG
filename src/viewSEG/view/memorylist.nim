## The File memory window's rows: what is remembered about each file, in
## words, and which entries each of the window's removals takes away, so
## that the window can say so before anything goes.

import std/times
import ../core/filememory
import filetable

type
  MemoryRow* = object
    ## One file the store remembers.
    doc*: string     ## its document: what `ckForgetFiles` names
    name*: string    ## the name it was last seen under
    path*: string    ## where
    opened*: string  ## when it was last opened, local time ("2026-11-15 10:02")
    days*: int       ## whole days since then
    kept*: string    ## what is kept: "3 killed, 1 reversed"
    size*: string    ## the file's size
    entry*: string   ## the size of its entry in the store
    gone*: bool      ## no file at `path` any more (or one of another size)

proc memoryRows*(records: openArray[FileRecord]; now = getTime()): seq[MemoryRow] =
  ## A row per record, in their order (the newest opened first).
  for r in records:
    let days = if r.opened == Time(): 0 else: max(0, int((now - r.opened).inDays))
    result.add MemoryRow(doc: r.doc, name: r.name, path: r.path,
      opened: (if r.opened == Time(): "" else: r.opened.local.format("yyyy-MM-dd HH:mm")),
      days: days, kept: keptWords(r.edits), size: sizeText(r.identity.size),
      entry: sizeText(r.bytes), gone: r.gone)

func notOpenedFor*(rows: openArray[MemoryRow]; days: int): seq[int] =
  ## The rows of files not opened for `days` days or more.
  for i, r in rows:
    if r.days >= days: result.add i

func goneRows*(rows: openArray[MemoryRow]): seq[int] =
  ## The rows of files that are not where they were last seen.
  for i, r in rows:
    if r.gone: result.add i
