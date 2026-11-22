## A `.dat` and a `.vib` of the same sweep. Either opens alone, always; a pair adds offers and
## facts and is never a condition for opening.
##
## **The rule** (`pairSweeps`, pure): the candidates of a `.vib` are the `.dat` files whose
## trigger lies in its window (the second its recording began plus 0.2 to 1.5 s, from the
## header alone). One candidate is the pair. Several: those whose serial is the serial of the
## `.vib`'s folder; exactly one is the pair. Otherwise there is none, and the `.vib` is told the
## candidates. File names are never used. One `.dat` pairs with at most one `.vib`: a `.dat`
## that two `.vib`s claim pairs with neither, and both are told.
##
## **On demand** (`findPairWork`): for a file opened alone, a background job lists the file's
## folder, the folder two levels up and its subfolders to depth 2 (a controller's
## `<serial>/<date>/` layout), reads the header of each candidate of the other kind, stops at
## `MaxPairFiles`, and posts the pair or the reason (`mkPaired`).

import std/[algorithm, os, sets, strutils, tables]
import filesystem, inbox, jobs, signatures, sigtypes, sweepinfo

const
  MaxPairFiles* = 5000               ## files a search for a partner looks at, at most
  VibWindowLoNs* = 200_000_000'i64   ## a `.vib`'s trigger lies this long after its start second
  VibWindowHiNs* = 1_500_000_000'i64 ## ... at most this long

type
  PairKey* = object
    ## One signature file, as pairing sees it.
    path*: string
    kind*: SignatureKind
    ns*: int64      ## a `.dat`'s trigger; a `.vib`'s start second (UTC ns since 1970)
    serial*: int64  ## a `.dat`'s controller serial; a `.vib`'s folder serial; -1 for none
    lo*, hi*: int64 ## a `.vib`'s window for the trigger (`windowOf`)

  PairAnswer* = object
    ## What a search for a file's partner found (`mkPaired`), kept by the program.
    partner*: string ## "" when none was found
    info*: SweepInfo ## the partner's list facts
    words*: string   ## why none was found, or which several fit
    candidates*: seq[string]
    looked*: int

  PairResult* = object
    pairs*: Table[string, string]           ## each path of a pair to its partner's, both directions
    notes*: Table[string, string]
      ## a file with no pair and something to tell: its candidates, or the other `.vib` that
      ## claims its `.dat`
    candidates*: Table[string, seq[string]] ## a `.vib`'s several fitting `.dat` files

func windowOf*(startNs: int64): tuple[lo, hi: int64] =
  ## The trigger of a `.vib` that began in the second `startNs` lies in this window (ns).
  (startNs + VibWindowLoNs, startNs + VibWindowHiNs)

func pairKeyOf*(path: string; i: SweepInfo): PairKey =
  ## The key of the signature file at `path` whose list facts are `i`.
  result = PairKey(path: path, kind: i.kind, ns: i.triggerNs,
    serial: (if i.serialFrom == sfNone: -1'i64 else: i.controller))
  if i.kind == sgVib: (result.lo, result.hi) = windowOf(i.triggerNs)

func lowerBound(dats: openArray[PairKey]; ns: int64): int =
  var (lo, hi) = (0, dats.len)
  while lo < hi:
    let mid = (lo + hi) div 2
    if dats[mid].ns < ns: lo = mid + 1 else: hi = mid
  lo

proc pairSweeps*(keys: openArray[PairKey]): PairResult =
  ## Pairs the `.dat` and `.vib` files in `keys` by the rule above. O(n log n): the `.dat`
  ## files are sorted by trigger, and each `.vib` looks its window up in them.
  var dats: seq[PairKey] = @[]
  var vibs: seq[PairKey] = @[]
  for k in keys:
    if k.kind == sgDat: dats.add k elif k.kind == sgVib: vibs.add k
  dats.sort(proc (a, b: PairKey): int = cmp(a.ns, b.ns))
  var claim = initTable[string, string]() # a .vib's path to the .dat it chose
  var claimedBy = initTable[string, seq[string]]() # a .dat's path to the .vibs that chose it
  for v in vibs:
    var fit: seq[PairKey] = @[]
    var at = dats.lowerBound(v.lo)
    while at < dats.len and dats[at].ns <= v.hi:
      fit.add dats[at]
      inc at
    var chosen = ""
    if fit.len == 1:
      chosen = fit[0].path
    elif fit.len > 1:
      var same: seq[PairKey] = @[]
      if v.serial >= 0:
        for d in fit:
          if d.serial == v.serial: same.add d
      if same.len == 1:
        chosen = same[0].path
      else:
        var names: seq[string] = @[]
        for d in fit: names.add d.path
        result.candidates[v.path] = names
        result.notes[v.path] = $fit.len & " .dat files fit: choose one"
    if chosen.len > 0:
      claim[v.path] = chosen
      claimedBy.mgetOrPut(chosen, @[]).add v.path
  for v, d in claim:
    if claimedBy[d].len == 1:
      result.pairs[v] = d
      result.pairs[d] = v
    else:
      for other in claimedBy[d]:
        if other != v:
          result.notes[v] = "another .vib (" & other.extractFilename & ") fits the same .dat: " &
            "neither is paired"
      result.notes[d] = $claimedBy[d].len & " .vib files fit this .dat: none is paired"

func noPairWords*(kind: SignatureKind; folder, controllerFolder: string; looked: int;
    window: string): string =
  ## What a search that found no partner says.
  let wanted = if kind == sgDat: ".vib" else: ".dat"
  let where = if controllerFolder.len > 0 and controllerFolder != folder:
      folder & " or " & controllerFolder else: folder
  result = "No " & wanted & " of this sweep was found in " & where & " (looked at " & $looked &
    " " & wanted & " files: none " & window & ")."

proc searchFolders(path: string): seq[string] =
  ## The folders a search looks in: the file's own, the one two levels up and its subfolders
  ## to depth 2, each once.
  let own = path.parentDir
  result = @[own]
  let up = own.parentDir # (`<serial>/<date>/NNNN.VIB`: the controller's folder)
  if up.len > 0 and up != own and fs.dirExists(up):
    var level = @[up]
    for depth in 0 .. 2:
      var next: seq[string] = @[]
      for d in level:
        if d notin result: result.add d
        if depth < 2:
          try:
            for kind, p in fs.walkDir(d, checkDir = true):
              if kind == pcDir and not p.extractFilename.startsWith("."): next.add p
          except OSError:
            discard
      level = next

proc findPairWork*(path: string; to: Poster): JobWork =
  ## The work of a background job that looks for the partner of the signature file at `path`
  ## (opened alone) and posts what it finds (`mkPaired`). Reads through `fs` only; stops at
  ## `MaxPairFiles` files and at a cancel.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "looking for the other file of this sweep"
    var m = Msg(job: ctx.id, kind: mkPaired, pairFor: path)
    var own: seq[byte] = @[]
    let size = readHead(path, own)
    let self = readSweepInfo(path, signatureKindOf(own), max(size, 0))
    if self.kind == sgNone or self.problem.len > 0:
      m.pairWords = "this file's header cannot be read" &
        (if self.problem.len > 0: ": " & self.problem else: "")
      to.post move m
      return
    let selfKey = pairKeyOf(path, self)
    var keys = @[selfKey]
    var infos = @[self]
    var looked = 0
    var seen = initHashSet[string]()
    seen.incl path
    let folders = searchFolders(path)
    var stopped = false
    for d in folders:
      if not stopped:
        try:
          for kind, p in fs.walkDir(d, checkDir = true):
            if kind in {pcFile, pcLinkToFile} and p notin seen and
                not p.extractFilename.startsWith("."):
              seen.incl p
              if seen.len > MaxPairFiles:
                stopped = true
                break
              ctx.checkCancelled()
              var h: seq[byte] = @[]
              let psize = readHead(p, h)
              let k = if psize > 0: signatureKindOf(h) else: sgNone
              if k in SignatureKinds and k != self.kind:
                inc looked
                let info = readSweepInfo(p, k, psize)
                if info.problem.len == 0:
                  keys.add pairKeyOf(p, info)
                  infos.add info
        except OSError:
          discard # a folder that cannot be read is left out
    m.pairLooked = looked
    m.pairSelf = self
    let r = pairSweeps(keys)
    if stopped:
      m.pairWords = "too many files to search: open the controller's folder in Files with " &
        "Include subfolders"
    elif path in r.pairs:
      m.pairPath = r.pairs[path]
      for i, k in keys:
        if k.path == m.pairPath: m.pairInfo = infos[i]
    elif path in r.candidates:
      m.pairWords = r.notes[path]
      m.pairCandidates = r.candidates[path]
    elif path in r.notes:
      m.pairWords = r.notes[path]
    else:
      let window = if self.kind == sgDat: "began 0.2 to 1.5 s before the trigger " &
          timeText(self.triggerNs, 3)
        else: "has a trigger in the window after " & timeText(self.triggerNs, 0)
      m.pairWords = noPairWords(self.kind, path.parentDir, path.parentDir.parentDir, looked,
        window)
    to.post move m
