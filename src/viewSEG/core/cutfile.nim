## What the viewer says of an open file that was cut short, or whose drive
## failed, in plain words. The finding is parseSEG's own guard (`cutShort`,
## `readFailed`, `SegTruncatedError`, the decode log's `dcTruncated` and
## `dcIo`; the file's source says where its bytes end with `readable`): a read past a cut gives zeros and a failed row, never a fault
## that ends the program, so the viewer checks nothing before a read; it
## says afterwards what the guard found.

import std/strutils
import parseSEG

func firstLine*(msg: string): string =
  ## The first line of `msg` (the system's words in an error).
  result = msg
  let cut = result.find('\n')
  if cut >= 0: result.setLen cut

func driveWords*(msg: string): string =
  ## "it cannot be read now (...): its drive went away or fails", for an
  ## error `msg` of a read the drive failed.
  let first = firstLine(msg)
  "it cannot be read now (" & (if first.len > 0: first else: "its drive does not answer") &
    "): its drive went away or fails"

func cutWords*(failed: bool): string =
  ## Why a file that `cutShort` found is not read: `failed` when the drive's
  ## read failed (`readFailed`), else another program cut the file.
  if failed:
    "the file could not be read past a point (an I/O error: its drive failed or stopped " &
      "answering): it is not read until it is opened again"
  else:
    "the file was cut short while it was open (another program cut it or is writing it " &
      "again): it is not read until it is opened again"

proc cutWhy*(f: SeismicFile): string =
  ## Why nothing of `f` is read now, when parseSEG's guard has found it cut
  ## short or its read failed (`cutShort`: one `fstat` of a mapped file);
  ## "" when it can be read.
  if f.cutShort: cutWords(f.readFailed) else: ""

proc readProblem*(e: ref CatchableError): string =
  ## What a part says of a read that raised `e`: a file cut short, a drive,
  ## or another reason (`e.msg`).
  if e of SegTruncatedError: cutWords(("could not be read" in e.msg))
  elif e of OSError or e of IOError: driveWords(e.msg)
  elif e.msg.len > 0: e.msg
  else: $e.name
