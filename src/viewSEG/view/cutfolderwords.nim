## Words for the whole-folder part of Project > Slice by shot log: what a check of the
## folder found, and what a run did.

import std/[os, strutils]
import ../core/cutfolderjobs

const NamedFiles = 5 ## how many skipped or failed files are named

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func lostWords(f: FolderFile): string =
  ## What a file skipped after the shots were placed leaves unsliced.
  if f.shots > 0: " (" & plural(f.shots, "shot", "shots") & " not sliced)" else: ""

func skipLines*(r: FolderResult): seq[string] =
  ## The files that are not sliced, each with its reason; the first few.
  var left = 0
  for f in r.files:
    if f.skip.len > 0:
      if result.len < NamedFiles: result.add f.path.extractFilename & ": " & f.skip & lostWords(f)
      else: inc left
  if left > 0: result.add "and " & plural(left, "more file", "more files") & " not sliced"

func unplacedWords*(r: FolderResult): string =
  ## The shots no file holds, counted once and the first few named; "" when none.
  if r.unplaced == 0: return ""
  result = plural(r.unplaced, "shot is", "shots are") & " in no file of the folder (its " &
    "record does not start inside a recording): " & r.unplacedNamed.join(", ")
  if r.unplaced > r.unplacedNamed.len: result.add ", ..."
  result.add "."

func checkWords*(r: FolderResult): string =
  ## What the check of the folder found, in a sentence.
  let n = r.countSliceable
  var shots = 0
  for f in r.files:
    if f.sliceable: shots += f.shots
  if r.files.len == 0: return "The folder has no file."
  result = plural(n, "recording", "recordings") & " of " & plural(r.files.len, "file", "files") &
    " can be sliced"
  if n > 0: result.add " (" & plural(shots, "shot", "shots") & ")"
  result.add "."
  if r.capped: result.add " The list of files stopped at the limit."

func outcomeWords*(r: FolderResult): string =
  ## What a run did, in a sentence.
  let written = r.countWritten
  let failed = r.countFailed
  result = "Sliced " & plural(written, "file", "files")
  if failed > 0: result.add "; " & plural(failed, "file", "files") & " failed"
  result.add "."

func outcomeLines*(r: FolderResult): seq[string] =
  ## The files written and the files that failed, one line each (the first few of the
  ## failures), then the shots that no file holds.
  for f in r.files:
    if f.written: result.add f.path.extractFilename & " -> " & f.dest.extractFilename & ": " & f.line
  var named = 0
  for f in r.files:
    if f.reason.len > 0 and named < NamedFiles:
      result.add f.path.extractFilename & " failed: " & f.reason
      inc named
  var skipped = 0
  for f in r.files:
    if f.skip.len > 0 and f.shots > 0 and skipped < NamedFiles:
      result.add f.path.extractFilename & " not sliced: " & f.skip & lostWords(f)
      inc skipped
  let un = unplacedWords(r)
  if un.len > 0: result.add un
