## The file list: the seismic files of a folder, or of files the user chose,
## that the user steps through, one shown at a time.
##
## A listing is made off the UI thread (`filejobs.scanWork`, a job on the
## background lane): the folder's names are read and put in natural order
## ("shot2" before "shot10"), then the first bytes of each file are read to
## tell whether it is SEG-Y, SEG-D or SEG-2 (parseSEG's `detectKind`), so a
## folder of thousands of files is listed without opening any of them. The
## files that are not seismic are counted, not listed. The scan posts what it
## found in batches (`mkListed`), so the first files appear at once.
##
## `chosen` is the file the main plot window shows, or is opening to show:
## the list marks it, and stepping (the arrow keys) goes on from it.

import std/[strutils, times]
import parseSEG/common/seismickind
import jobs

export SeismicKind

const
  SniffBytes* = 4096 ## the bytes read from each file to tell its standard
  ListBatch* = 64    ## entries a scan posts at a time, at most

type
  FileEntry* = object
    ## One seismic file of the list.
    path*: string ## absolute and normalized, as files are opened
    name*: string
    kind*: SeismicKind
    size*: int64
    modified*: Time

  FileList* = object
    ## What the file list shows. Changed only by `AppState`.
    title*: string           ## the folder listed, or "3 files"; "" before any listing
    folder*: string          ## the folder listed; "" for files chosen one by one
    asked*: seq[string]      ## the paths the listing was asked for (for a refresh)
    entries*: seq[FileEntry] ## the seismic files, in natural order of their names
    others*: int             ## files that are not seismic, so not listed
    unreadable*: int         ## files that could not be read
    scanning*: bool          ## the scan has not finished
    job*: JobId              ## the scan's job; `NoJob` for none
    gen*: uint64             ## bumped by each new listing; what a scan posts carries it
    chosen*: string          ## the file the main plot shows or is opening; "" for none
    failed*: seq[string]     ## files of the list that could not be opened
    error*: string           ## why the listing failed; "" when it did not
    revision*: int           ## bumped on every change

func isDigit(c: char): bool {.inline.} = c in {'0'..'9'}

func naturalCmp*(a, b: string): int =
  ## Compares names as people sort them: case-insensitively, with runs of
  ## digits compared as numbers ("shot2" before "shot10"); names that are
  ## equal so ("a01" and "a1", "A" and "a") as plain text.
  var i, j = 0
  while i < a.len and j < b.len:
    if a[i].isDigit and b[j].isDigit:
      var i2 = i
      var j2 = j
      while i2 < a.len and a[i2].isDigit: inc i2
      while j2 < b.len and b[j2].isDigit: inc j2
      var x = i # skip leading zeros, then the longer run is the larger number
      while x < i2 - 1 and a[x] == '0': inc x
      var y = j
      while y < j2 - 1 and b[y] == '0': inc y
      if i2 - x != j2 - y: return cmp(i2 - x, j2 - y)
      for k in 0 ..< i2 - x:
        if a[x + k] != b[y + k]: return cmp(a[x + k], b[y + k])
      i = i2
      j = j2
    else:
      let (p, q) = (a[i].toLowerAscii, b[j].toLowerAscii)
      if p != q: return cmp(p, q)
      inc i
      inc j
  result = cmp(a.len - i, b.len - j)
  if result == 0: result = cmp(a, b)

func filterWords*(filter: string): seq[string] =
  ## The words of a filter typed by the user, in lower case.
  filter.toLowerAscii.splitWhitespace

func holds(name, word: string): bool =
  ## Whether `name` holds `word` (lower case), in any case. Allocates
  ## nothing: the file table runs it on every file of a folder.
  for i in 0 .. name.len - word.len:
    var j = 0
    while j < word.len and name[i + j].toLowerAscii == word[j]: inc j
    if j == word.len: return true
  false

func matches*(e: FileEntry; words: openArray[string]): bool =
  ## Whether `e`'s name holds every one of `words` (`filterWords`), in any
  ## case; no words match every file.
  for word in words:
    if not e.name.holds(word): return false
  true

func matches*(e: FileEntry; filter: string): bool =
  ## Whether `e`'s name holds every word of `filter`, in any case; an empty
  ## filter matches every file.
  e.matches(filterWords(filter))

func find*(list: FileList; path: string): int =
  ## The index of `path` in the list's entries; -1 when it is not listed.
  for i, e in list.entries:
    if e.path == path: return i
  -1

proc merge*(list: var FileList; found: openArray[FileEntry]) =
  ## Adds `found` (files not listed yet: a scan names each file once) to the
  ## entries, keeping them in natural order. A scan posts in that order, so
  ## each entry goes at the end.
  for e in found:
    var at = list.entries.len
    while at > 0 and naturalCmp(list.entries[at - 1].name, e.name) > 0: dec at
    list.entries.insert(e, at)
  if found.len > 0: inc list.revision
