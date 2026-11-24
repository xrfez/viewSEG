## The vendor fields an open file has, as the display-line menu lists them.
##
## parseSEG's `vendorFieldNames` says which fields the loaded vendor maps can
## decode for a file, each under the name a display line is chosen by (the bare
## name when no other field has it, else `block.name`). Here that answer is
## made into `VendorFieldEntry` rows: a name that is also a built-in header
## line's name (`headerRefOf` would choose the built-in line) is given with its
## block, which always names the field. The answer is read on a job
## (`core/vendorfieldjobs`) and kept per open file and load of the maps
## (`VendorFieldList`), so the menu never reads a file.

import parseSEG
import panels, session

type
  VendorFieldEntry* = object
    ## One field of the open file's vendor maps.
    name*: string       ## what a display line is chosen by (`vendorRef`)
    level*: VendorLevel ## `vlRecord`: one value per record, spread to its traces
    kind*: VendorValueKind
    repeated*: bool     ## a field of a repeat: only its elements (`name[i]`) have values

  VendorFieldList* = object
    ## The fields one open file has, as read for one load of the vendor maps.
    session*: SessionId
    vendors*: int ## the maps' load (`AppState.vendor.gen`) it was read with
    entries*: seq[VendorFieldEntry]

func isNumeric*(e: VendorFieldEntry): bool =
  ## Whether a display line can show the field: a number, not text, bytes or a repeat.
  e.kind in {vvInt, vvFloat} and not e.repeated

func isBuiltInName(name: string): bool =
  # Whether `name` chooses a built-in display line (`headerRefOf`).
  headerRefOf(name).field != hfVendor

func vendorFieldEntries*(infos: openArray[VendorFieldInfo]): seq[VendorFieldEntry] =
  ## The fields `infos` (parseSEG's `vendorFieldNames`) as rows, in its order.
  ## A field whose bare name is a built-in line's name is named `block.name`,
  ## so choosing it gives the vendor field, not the built-in line.
  result = newSeqOfCap[VendorFieldEntry](infos.len)
  for info in infos:
    let name = if info.name.isBuiltInName: info.blockName & "." & info.fieldName else: info.name
    result.add VendorFieldEntry(name: name, level: info.level, kind: info.kind,
      repeated: info.isRepeat)
