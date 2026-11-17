## Vendor header maps: the `*.nif` files parseSEG decodes a manufacturer's own
## header blocks with, loaded from the folders the user drops them into, and
## what they decode of an open file (docs/user/vendor-maps.md).
##
## - `loadVendorFolders` reads the folders (off the UI thread: it reads the
##   disk, through the seam) into a `VendorLoad`: parseSEG's `VendorRegistry`,
##   one `VendorMapInfo` per map and one `VendorFolderInfo` per folder, and a
##   `VendorProblem` for each map that did not load or that parseSEG's
##   `checkVendorMap` found something in. The folders come in order of
##   preference (`VendorFolder`: the project's, the user's settings folder,
##   beside the program, the environment's). Of two maps with the same name the
##   earlier folder's is the one kept: a project's copy of a map replaces the
##   program's. Of maps with different names that apply to the same block
##   parseSEG chooses the one whose `match` clauses are the most specific, and
##   the one loaded first when they are equally so, which is the one of the
##   folder preferred.
## - `publishVendors` and `currentVendors`: the registry in force, for the
##   threads that decode a file's blocks (a copy: nothing is shared).
## - `vendorBlocks`: what the registry decodes of a SEG-D record's extended,
##   external, general and trailer blocks, or of a SEG-Y file's binary header
##   and stanzas, as plain rows for the Headers window. A trace's own vendor
##   headers (SEG-D header extensions, SEG-Y proprietary headers) are not
##   decoded here: parseSEG's index does not keep them, and reading them
##   would be a read of the file's map for every trace shown.

import std/[algorithm, locks, os, strutils]
import parseSEG
import filesystem

const
  VendorFolderName* = "vendormaps"
    ## the folder of vendor header maps beside the program, in every project
    ## and in the settings folder
  VendorReadmeName* = "README.txt" ## the note a folder the program made holds
  MaxVendorMapBytes* = 1 shl 20 ## parseSEG refuses a map file larger than this
  VendorGuideName* = "WRITING-A-MAP.md" ## the guide to writing a map, beside the note
  VendorReadme* = "Vendor header maps\n\n" &
    "Drop vendor header maps (files ending in .nif) in this folder. Each one tells viewSEG how " &
    "to read a manufacturer's own header blocks, which the SEG-D and SEG-Y standards leave " &
    "open: the Headers window then shows their fields by name. WRITING-A-MAP.md, in this " &
    "folder, is the guide to the format of a map. File > Reload vendor maps (or opening a " &
    "project) picks up a map dropped here while the program runs.\n"
    ## what the program writes in `README.txt` of each folder it makes
  VendorGuide* = staticRead("../../../vendormaps/WRITING-A-MAP.md")
    ## the guide, written beside the note (the repository's `vendormaps/WRITING-A-MAP.md`;
    ## `tvendorguide` checks it against parseSEG's)

  VendorNotes* = [(VendorReadmeName, VendorReadme), (VendorGuideName, VendorGuide)]
    ## the files of a folder the program makes: written when not there, never replaced

type
  VendorOrigin* = enum
    ## Where a folder of maps comes from, in the order they are preferred.
    voProject = "the project"
    voUser = "your settings folder"
    voProgram = "beside the program"
    voEnvironment = "PARSESEG_VENDOR_PATH"

  VendorFolder* = object
    ## A folder to load maps from.
    dir*: string
    origin*: VendorOrigin

  VendorFolderInfo* = object
    ## What loading found in one folder.
    dir*: string
    origin*: VendorOrigin
    there*: bool ## the folder exists
    loaded*: int ## maps it gave

  VendorMapInfo* = object
    ## One map that loaded.
    name*: string
    file*: string      ## the map's file
    folder*: string
    origin*: VendorOrigin
    appliesTo*: string ## its `match` and its targets, in words

  VendorProblem* = object
    ## Something the loading found wrong with a map, or that left one out.
    file*: string
    text*: string ## the library's reason, in its words
    loaded*: bool ## the map is loaded all the same (a note of `checkVendorMap`)

  VendorLoad* = object
    ## What `loadVendorFolders` made.
    registry*: VendorRegistry
    maps*: seq[VendorMapInfo]
    folders*: seq[VendorFolderInfo]
    problems*: seq[VendorProblem]
    shadowed*: seq[string] ## the maps left out as a map of the same name was kept (lines)

  VendorFieldFact* = object
    ## One decoded field, as the window shows it.
    name*, value*, unit*, label*, flags*: string

  VendorBlockFact* = object
    ## One decoded block.
    map*: string     ## the map that decoded it
    mapFile*: string ## where that map was loaded from; "" for a code decoder
    name*: string    ## the block's name (the map target's)
    fields*: seq[VendorFieldFact]

  VendorShown* = object
    ## What the registry decodes of one file (one record of it, for SEG-D).
    path*: string
    record*: int = -1      ## the SEG-D record; -1 for a SEG-Y file
    gen*: int              ## the maps' generation it was decoded with
    blocks*: seq[VendorBlockFact]
    problems*: seq[string] ## what parseSEG said while decoding, in its words

# ------------------------------------------------------------ the registry --

var
  shared: VendorRegistry
  sharedLock: Lock

initLock(sharedLock)

proc publishVendors*(reg: VendorRegistry) =
  ## Makes `reg` the registry `currentVendors` gives.
  {.cast(gcsafe).}:
    withLock sharedLock:
      shared = reg

proc currentVendors*(): VendorRegistry =
  ## A copy of the registry in force; empty until maps are published.
  {.cast(gcsafe).}:
    withLock sharedLock:
      result = shared

# ----------------------------------------------------------------- loading --

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func revisionText(r: VendorRevision): string =
  $r.major & "." & $r.minor

func appliesTo*(m: VendorMap): string =
  ## What `m` says it applies to, and what it decodes, in a line.
  var parts: seq[string] = @[]
  if m.match.format.isSome:
    parts.add(if m.match.format.get == skSegd: "SEG-D" else: "SEG-Y")
  if m.match.revisions.isSome:
    let r = m.match.revisions.get
    parts.add "revision " & revisionText(r.first) &
      (if r.last != r.first: " to " & revisionText(r.last) else: "")
  if m.match.manufacturers.len > 0:
    var codes: seq[string] = @[]
    for c in m.match.manufacturers: codes.add $c
    parts.add "manufacturer code " & codes.join(", ")
  if m.match.serialMin >= 0:
    parts.add "serial " & $m.match.serialMin &
      (if m.match.serialMax != m.match.serialMin: " to " & $m.match.serialMax else: "")
  for s in m.match.textContains: parts.add "text holding \"" & s & "\""
  result = if parts.len > 0: parts.join(", ") else: "any file"
  var names: seq[string] = @[]
  for t in m.targets:
    if t.name notin names: names.add t.name
  if names.len > 0: result.add "; decodes " & names.join(", ")

proc mapFiles(dir: string; problems: var seq[VendorProblem]): seq[string] =
  ## The `*.nif` files of `dir`, by name.
  try:
    for kind, path in fs.walkDir(dir):
      if kind in {pcFile, pcLinkToFile} and path.extractFilename.toLowerAscii.endsWith(".nif"):
        result.add path
  except OSError as e:
    problems.add VendorProblem(file: dir, text: "the folder cannot be read (" & e.msg & ")")
  result.sort

proc loadVendorFolders*(folders: openArray[VendorFolder]): VendorLoad =
  ## Loads every map of `folders`, in order, through parseSEG (`loadVendorMap`,
  ## `checkVendorMap`, `addMap`) from text read through the seam. One that does
  ## not load is a `VendorProblem` and the others load all the same.
  result = VendorLoad()
  var seen: seq[(string, string)] = @[] # name, file
  for fo in folders:
    var info = VendorFolderInfo(dir: fo.dir, origin: fo.origin, there: fs.dirExists(fo.dir))
    if info.there:
      for file in mapFiles(fo.dir, result.problems):
        try:
          if fs.getFileSize(file) > MaxVendorMapBytes:
            raise newException(ValueError, "the file is larger than " & $MaxVendorMapBytes &
              " bytes, which parseSEG refuses")
          var m = loadVendorMap(fs.readFile(file), file)
          var at = -1
          for i, (name, _) in seen:
            if name == m.name: at = i
          if at >= 0:
            result.shadowed.add m.name & " (" & file & ") is left out: " & seen[at][1] &
              " is a map of the same name"
          else:
            for note in m.checkVendorMap:
              result.problems.add VendorProblem(file: file, text: note, loaded: true)
            seen.add (m.name, file)
            result.maps.add VendorMapInfo(name: m.name, file: file, folder: fo.dir,
              origin: fo.origin, appliesTo: m.appliesTo)
            result.registry.addMap m
            inc info.loaded
        except CatchableError as e:
          result.problems.add VendorProblem(file: file, text: e.msg.splitLines()[0])
    result.folders.add info

func fromWhere(load: VendorLoad): string =
  ## "2 from the project, 1 beside the program".
  var parts: seq[string] = @[]
  for o in VendorOrigin:
    var n = 0
    for f in load.folders:
      if f.origin == o: n += f.loaded
    if n > 0: parts.add $n & (if o == voProgram: " " else: " from ") & $o
  parts.join(", ")

func summaryLine*(load: VendorLoad): string =
  ## The one line a load says: "3 vendor header maps loaded: 2 from the
  ## project, 1 beside the program"; "" when no map was loaded.
  if load.maps.len > 0:
    result = plural(load.maps.len, "vendor header map", "vendor header maps") & " loaded: " &
      load.fromWhere

func problemLine*(p: VendorProblem): string =
  ## A map that did not load, or that loaded with a note, as one line.
  if p.loaded:
    "The vendor header map " & p.file & " loaded, with a note: " & p.text & "."
  else:
    "The vendor header map " & p.file & " was not loaded: " & p.text &
      (if p.text.endsWith("."): "" else: ".")

func foldersText*(load: VendorLoad): string =
  ## The folders looked in, for the line that says no map was found.
  var dirs: seq[string] = @[]
  for f in load.folders:
    if f.there: dirs.add f.dir
  if dirs.len == 0: "no vendormaps folder exists"
  else: dirs.join(", ")

# ---------------------------------------------------------------- decoding --

func valueText(v: VendorValue): string =
  case v.kind
  of vvInt: $v.intVal
  of vvFloat: $v.floatVal
  of vvText: v.text
  of vvBytes:
    var s = ""
    for i, b in v.bytes:
      if i >= 32:
        s.add "..."
        break
      if i > 0: s.add ' '
      s.add toHex(b, 2)
    s

proc fact(b: VendorBlock; reg: VendorRegistry): VendorBlockFact =
  result = VendorBlockFact(map: b.mapName, name: b.name)
  for m in reg.maps:
    if m.name == b.mapName: result.mapFile = m.source
  for f in b.fields:
    result.fields.add VendorFieldFact(name: f.name, value: valueText(f.value),
      unit: f.value.unit, label: f.value.label, flags: f.value.flags.join(", "))

proc vendorBlocks*(f: SeismicFile; record: int; reg: VendorRegistry; gen = 0): VendorShown =
  ## What `reg` decodes of the vendor areas of `f`: of SEG-D record `record`'s
  ## headers and trailer, of a SEG-Y file's binary header and stanzas. Reads
  ## the index in memory only; nothing raises.
  result = VendorShown(path: f.path, record: record, gen: gen)
  var log: DiagLog
  var blocks: seq[VendorBlock] = @[]
  try:
    {.cast(gcsafe).}: # (a code decoder registered with the registry is a plain proc)
      case f.kind
      of skSegd:
        if record in 0 ..< f.index.segdRecords.len:
          blocks = decodeVendorAreas(reg, f.index.segdRecords[record], log, f.path)
      of skSegy:
        result.record = -1
        blocks = decodeVendorAreas(reg, f.index.segy, log, f.path)
      else: discard
  except CatchableError as e:
    result.problems.add "the vendor blocks cannot be decoded: " & e.msg
  for b in blocks: result.blocks.add fact(b, reg)
  for d in log:
    if d.code == dcVendorMap or d.code == dcVendorBlock:
      result.problems.add d.msg
