## The jobs of a project (docs/project.md), each off the UI thread: a project
## folder may be on a drive that does not answer, and its survey is large.
##
## - `openProjectWork` (interactive lane) reads the project document, takes
##   the lock between programs, reads the project's window arrangement, and
##   looks at its data folders and at its survey files' originals; with a
##   `NewProject`, it makes the folder and its document first, and copies in
##   what the program remembers about the files of its data folders.
## - `keepSurveyWork` (background lane) copies the survey files imported
##   into the project and writes `survey.bin` from the copies;
##   `updateSurveyWork` copies the originals that changed again.
## - `restoreWork` (background lane) makes the survey from `survey.bin`: the
##   map's layers (`mkSurvey`, one per file) and the joins' geometry
##   (`pnSurvey`), without reading a survey file.
## - `planWork` (interactive lane) works out a file's join with the project's
##   survey as the import does, from the geometry already made
##   (`mkJoining`): every file opened in a project is matched without the
##   import's window.
## - `lookWork` looks at the data folders and originals again;
##   `unlockWork` lets the lock go.
##
## What they find is posted as `mkProject` (`ProjectNews`).

import std/[monotimes, os, strutils, times]
import parseSEG
import displaypresets, filekinds, filememory, filesystem, identity, inbox, jobs, join, layouts,
  nif, persist, processing, project, projectnif, session, survey, surveystore, threads

type NewProject* = object
  ## What File > New project makes.
  name*: string
  data*: seq[string] ## the data folders, absolute
  bringFrom*: string
    ## the program's own store of what is remembered: its documents of files
    ## last seen in the data folders are copied in; "" for none
  presets*: seq[DisplayPreset]
  takePresets*: bool
  processing*: Processing
  takeProcessing*: bool

proc post(to: Poster; job: JobId; news: sink ProjectNews) =
  to.post Msg(job: job, kind: mkProject, news: news)

proc writeWhole(path, text: string) =
  ## `text` written to `path` atomically: a temporary file beside it, then
  ## a rename.
  let tmp = path & "." & $getCurrentProcessId() & ".tmp"
  var f: File
  if not fs.open(f, tmp, fmWrite): raise newException(IOError, "cannot write " & tmp)
  try:
    if text.len > 0 and fs.writeBuffer(f, tmp, unsafeAddr text[0], text.len) != text.len:
      raise newException(IOError, "the disk did not take " & tmp)
    flushFile(f)
  finally:
    close(f)
  fs.moveFile(tmp, path)

proc lookPlace*(p: ProjectPath; dir: string): PlaceLook =
  ## Where data folder `p` of the project in `dir` is now.
  result = PlaceLook(state: psMissing)
  for c in p.candidates(dir):
    if fs.dirExists(c): return PlaceLook(state: psFound, path: c)

proc lookOriginal*(c: SurveyCopy; dir: string;
    progress: proc (done, total: int64): bool {.gcsafe.} = nil): OriginalLook =
  ## Where survey file `c`'s original is now, and whether its content
  ## changed since it was copied into the project in `dir`: by its size and
  ## the hash of its first and last 64 KiB, and, when those agree but its
  ## modification time moved, by the hash of every byte against the copy's
  ## (read with `progress`, which may raise to stop). A file touched, renamed
  ## or copied with its content as it was has not changed (`confirmed` when
  ## its time moved: the new time is then the one to record); one whose
  ## content differs has, whatever its time says.
  result = OriginalLook(state: osNotFound)
  for path in c.original.candidates(dir):
    if path.len > 0 and fs.fileExists(path):
      try:
        var t: Time
        let id = quickIdentity(path, t)
        result = OriginalLook(state: osAsCopied, path: path, size: id.size, modified: t)
        if id.size != c.size or id.quick != c.quick: result.state = osChanged
        elif t != c.modified and c.full != 0:
          if fullHash(path, progress) != c.full: result.state = osChanged # other content between
          else: result.confirmed = true
        return
      except IOError, OSError:
        discard

proc looks(doc: ProjectDoc; dir: string; folders: var seq[PlaceLook];
    originals: var seq[OriginalLook]) =
  ## The data folders looked at; the originals only listed as not looked at
  ## yet (`originalsWork` does that: they may be large, or on a drive that does
  ## not answer, and no open waits for them).
  for p in doc.data: folders.add lookPlace(p, dir)
  for c in doc.survey: originals.add OriginalLook(state: osLooking)

proc hostName(): string =
  result = getEnv("HOSTNAME")
  if result.len == 0: result = getEnv("COMPUTERNAME")
  if result.len == 0:
    try: result = fs.readFile("/etc/hostname").strip
    except IOError, OSError: discard

proc realPath(path: string): string =
  ## `path` with its links resolved when it exists, as given when it does
  ## not: a job compares a project's folder with its data folders by these
  ## (a link to a data folder is that folder). Worker-only: it reads the disk.
  result = path
  if fs.dirExists(path) or fs.fileExists(path):
    try: result = fs.expandFilename(path)
    except OSError: discard

proc isEmptyFolder(dir: string): bool =
  for _ in fs.walkDir(dir): return false
  true

proc makeProject(dir: string; np: NewProject; brought: var int): ProjectDoc =
  if fs.fileExists(documentOf(dir)):
    raise newException(IOError, "there is a project in " & dir & " already")
  if fs.dirExists(dir) and not isEmptyFolder(dir):
    raise newException(IOError, "the folder " & dir & " is not empty: a project is made in " &
      "an empty folder, or in a new one")
  for d in np.data:
    if realPath(dir).isInside(realPath(d)):
      raise newException(IOError, "it would be inside its data folder " & d &
        ", and data folders are never written to")
  fs.createDir(dir)
  for part in [ProjectStoreFolder, SurveyCopies, CacheFolder]: fs.createDir(dir.partOf(part))
  result = ProjectDoc(name: np.name, created: getTime())
  for d in np.data:
    if result.data.len < MaxProjectData: result.data.add placeOf(dir, d)
  if np.takePresets: (result.displayPresets, result.hasPresets) = (np.presets, true)
  if np.takeProcessing: (result.processing, result.hasProcessing) = (np.processing, true)
  writeWhole(documentOf(dir), projectDocument(result))
  if np.bringFrom.len > 0 and np.data.len > 0:
    var problems: seq[string] = @[]
    for r in listRecords(Store(home: np.bringFrom), problems, look = false):
      var inData = false
      for d in np.data:
        if realPath(r.path).isInside(realPath(d)): inData = true
      let dest = dir.partOf(ProjectStoreFolder) / r.doc
      if inData and r.doc.len > 0 and not fs.fileExists(dest):
        try:
          fs.copyFile(np.bringFrom / r.doc, dest)
          inc brought
        except CatchableError:
          discard

proc openProjectWork*(dir: string; to: Poster; make = false; np = NewProject()): JobWork =
  ## The work of a job that opens (with `make`, first makes) the project in
  ## folder `dir` and posts what it found (`pnOpened`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    var news = ProjectNews(dir: dir, kind: pnOpened, created: make)
    {.cast(gcsafe).}:
      try:
        ctx.setPhase(if make: "making the project" else: "reading the project")
        if make:
          news.doc = makeProject(dir, np, news.brought)
        else:
          let doc = documentOf(dir)
          if not fs.fileExists(doc):
            raise newException(IOError, "there is no " & ProjectFileName & " in " & dir)
          var text = ""
          let why = readDocument(doc, text)
          if why.len > 0: raise newException(IOError, ProjectFileName & " cannot be read (" &
            why & ")")
          news.doc = readProject(text, ProjectFileName, news.problems)
        if news.doc.name.len == 0: news.doc.name = untitled(dir)
        news.lock = fs.lockFile(dir / LockName, initDuration())
        if news.lock.locked:
          try:
            writeWhole(dir / OwnerName, ownerDocument(Owner(host: hostName(),
              user: getEnv("USER", getEnv("USERNAME")), pid: getCurrentProcessId(),
              since: getTime())))
          except CatchableError:
            discard # a note only
        else:
          try: news.owner = readOwner(fs.readFile(dir / OwnerName))
          except CatchableError: discard
        let layout = dir / ProjectLayoutName
        if fs.fileExists(layout):
          let l = loadLayoutFile(layout)
          if l.found: news.layout = l.layout.imgui
        ctx.setPhase "looking at its folders"
        looks(news.doc, dir, news.folders, news.originals)
        let store = dir.partOf(SurveyStoreName)
        news.storeThere = news.doc.hasStore and fs.fileExists(store) and
          fs.getFileSize(store) == news.doc.store.bytes
      except JobCancelledError:
        if news.lock.locked: fs.unlock(news.lock)
        raise
      except CatchableError as e:
        if news.lock.locked: fs.unlock(news.lock)
        news.failure = e.msg.splitLines()[0]
    discard ctx.progress(1, 1)
    to.post(ctx.id, news)

proc lookWork*(dir: string; doc: ProjectDoc; to: Poster): JobWork =
  ## The work of a job that looks at the data folders of the project in
  ## `dir` again (`pnLooked`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    var news = ProjectNews(dir: dir, kind: pnLooked)
    {.cast(gcsafe).}:
      looks(doc, dir, news.folders, news.originals)
    news.originals.setLen 0
    to.post(ctx.id, news)

proc originalsWork*(dir: string; doc: ProjectDoc; to: Poster): JobWork =
  ## The work of a job (the lane of hashes) that looks at the survey
  ## originals of the project in `dir` (`pnOriginals`): their size and ends,
  ## and, when their time moved, every byte against the copy's, with
  ## progress; a cancel stops it between files and within a file.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var news = ProjectNews(dir: dir, kind: pnOriginals)
    {.cast(gcsafe).}:
      for i, c in doc.survey:
        ctx.setPhase "looking at " & c.original.displayName
        if not ctx.progress(i, doc.survey.len): raise newException(JobCancelledError, "cancelled")
        news.originals.add lookOriginal(c, dir, proc (done, total: int64): bool =
          if not ctx.progress(done, total): raise newException(JobCancelledError, "cancelled")
          true)
    discard ctx.progress(doc.survey.len, doc.survey.len)
    to.post(ctx.id, news)

proc unlockWork*(lock: FileLock): JobWork =
  ## The work of a job that lets a project's lock go (a close on a share
  ## may take a moment).
  result = proc (ctx: JobContext) {.gcsafe.} =
    var l = lock
    fs.unlock(l)

proc stopAtCancel(ctx: JobContext; done, total: int64): bool =
  ## A progress callback for `fullHash`: a cancel stops the job.
  if not ctx.progress(done, total): raise newException(JobCancelledError, "cancelled")
  true

proc copyIn(ctx: JobContext; dir, source, name: string): string =
  ## Copies `source` into the project's survey copies as `name`, in pieces,
  ## each one a place for a cancel (the copy's temporary file is removed
  ## then); its path relative to the project folder. The temporary file is
  ## named for the job: no other job's is the same.
  result = SurveyCopies & "/" & name
  let dest = dir.partOf(result)
  let tmp = dest & "." & $int(ctx.id) & ".tmp"
  fs.createDir(dest.parentDir)
  var (src, dst) = (File(nil), File(nil))
  var ok = false
  if not fs.open(src, source, fmRead): raise newException(IOError, "cannot read " & source)
  try:
    if not fs.open(dst, tmp, fmWrite): raise newException(IOError, "cannot write " & tmp)
    try:
      var buf = newSeq[byte](1 shl 20)
      let total = try: fs.getFileSize(source) except OSError: 0'i64
      var done = 0'i64
      while true:
        let n = fs.readBuffer(src, source, addr buf[0], buf.len)
        if n <= 0: break
        if fs.writeBuffer(dst, tmp, addr buf[0], n) != n:
          raise newException(IOError, "the disk did not take " & tmp.extractFilename)
        done += n
        discard stopAtCancel(ctx, done, total)
      flushFile(dst)
      ok = true
    finally:
      close(dst)
  finally:
    close(src)
    if not ok: discard fs.tryRemoveFile(tmp)
  fs.moveFile(tmp, dest)

proc keepSurveyWork*(dir: string; files: seq[JoinFile]; existing: seq[SurveyCopy];
    to: Poster; places: seq[ProjectPath] = @[]): JobWork =
  ## The work of a job that copies survey files `files` into the project in
  ## `dir` (a file already a copy of it is kept as it is), writes
  ## `survey.bin` from the copies and posts both (`pnKept`). Copies of
  ## `existing` no longer named are removed. With `places` (one per file),
  ## each file is looked for at them (an import that a close or a quit
  ## cut short, taken up again at the next open).
  result = proc (ctx: JobContext) {.gcsafe.} =
    var news = ProjectNews(dir: dir, kind: pnKept)
    {.cast(gcsafe).}:
      try:
        var taken: seq[string] = @[]
        let copies = dir.partOf(SurveyCopies)
        for i, jf0 in files:
          var jf = jf0
          if i < places.len:
            jf.path = ""
            for c in places[i].candidates(dir):
              if c.len > 0 and fs.fileExists(c):
                jf.path = c
                break
            if jf.path.len == 0:
              raise newException(IOError, places[i].displayName & ", a file of the survey " &
                "being copied in, is not found")
          ctx.setPhase "copying " & jf.path.extractFilename & " into the project"
          if jf.path.isInside(copies):
            var kept = false
            for c in existing:
              if dir.partOf(c.copy) == jf.path:
                news.copies.add c
                taken.add c.copy.extractFilename
                kept = true
            if not kept: raise newException(IOError, jf.path & " is not a survey file of it")
          else:
            var t: Time
            let id = quickIdentity(jf.path, t)
            let name = copyName(jf.path.extractFilename, taken)
            taken.add name
            let copy = ctx.copyIn(dir, jf.path, name)
            news.copies.add SurveyCopy(kind: jf.kind, role: jf.role, copy: copy,
              original: placeOf(dir, jf.path), size: id.size, modified: t, quick: id.quick,
              full: fullHash(dir.partOf(copy), proc (done, total: int64): bool =
              ctx.stopAtCancel(done, total)))
          if not ctx.progress(i + 1, files.len + 1):
            raise newException(JobCancelledError, "cancelled")
        news.store = writeStore(dir, news.copies, ctx)
        for c in existing:
          var still = false
          for x in news.copies:
            if x.copy == c.copy: still = true
          if not still:
            # only a file directly in survey/files is a copy: a copy named
            # outside it (a hand-edited document) is never removed
            let old = dir.partOf(c.copy)
            if old.parentDir == copies: discard fs.tryRemoveFile(old)
      except JobCancelledError:
        raise
      except CatchableError as e:
        news.keptFailure = e.msg.splitLines()[0]
    to.post(ctx.id, news)

proc updateSurveyWork*(dir: string; copies: seq[SurveyCopy]; originals: seq[OriginalLook];
    to: Poster): JobWork =
  ## The work of a job that copies the originals that changed (`osChanged`
  ## in `originals`) over their copies in the project in `dir`, writes
  ## `survey.bin` again and posts it (`pnKept`, `updated`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    var news = ProjectNews(dir: dir, kind: pnKept, updated: true, copies: copies)
    {.cast(gcsafe).}:
      try:
        for i, c in copies:
          if i < originals.len and originals[i].state == osChanged:
            let src = originals[i].path
            ctx.setPhase "copying " & src.extractFilename & " into the project again"
            var t: Time
            let id = quickIdentity(src, t)
            discard ctx.copyIn(dir, src, c.copy.extractFilename)
            news.copies[i].size = id.size
            news.copies[i].modified = t
            news.copies[i].quick = id.quick
            news.copies[i].full = fullHash(dir.partOf(c.copy), proc (done, total: int64): bool =
              ctx.stopAtCancel(done, total))
            news.copies[i].original = placeOf(dir, src)
        news.store = writeStore(dir, news.copies, ctx)
      except JobCancelledError:
        raise
      except CatchableError as e:
        news.keptFailure = e.msg.splitLines()[0]
    to.post(ctx.id, news)

func roleOf(k: SpsPointKind): PointRole {.inline.} =
  if k == pkSource: prSource else: prReceiver

func pointIndex(i: int): int16 {.inline.} =
  int16(clamp(i, int(low(int16)), int(high(int16))))

func p1Number(lineName: string): float64 =
  result = NaN
  if lineName.strip.len > 0:
    try: result = parseFloat(lineName.strip)
    except ValueError: discard

proc restoreWork*(dir: string; doc: ProjectDoc; layers: bool; to: Poster): JobWork =
  ## The work of a job that makes the survey of the project in `dir` from
  ## its `survey.bin`: with `layers`, the map's layer of each SPS and P1
  ## file (`mkSurvey`, as a survey file loaded is), then the joins' geometry
  ## with the project's options (`pnSurvey`). No survey file is read.
  result = proc (ctx: JobContext) {.gcsafe.} =
    let began = getMonoTime()
    var news = ProjectNews(dir: dir, kind: pnSurvey)
    var built: seq[SurveyLayer] = @[]
    {.cast(gcsafe).}:
      try:
        ctx.setPhase "making the survey kept in the project"
        let opts = doc.options
        var g = new SurveyGeometry
        g[] = initSurveyGeometry()
        g.trailingDigits = opts.trailingDigits
        g.multiComponent = opts.multiComponent
        for ln in opts.lineNames: g[].mapLine(ln.name, ln.line)
        var naming: seq[(string, float64)] = @[]
        for ln in opts.lineNames: naming.add (ln.name, ln.line)
        var names: seq[string] = @[]
        var b: SurveyFileBuilder
        var building = false
        var (rows, skipped) = (0, 0)
        var problems: seq[string] = @[]
        proc onFile(f: StoredFile) =
          names.add f.name
          if layers and f.kind != jkCsv:
            b = initSurveyFileBuilder(dir.partOf(f.copy), f.fileKind, f.size, f.modified,
              naming, opts.trailingDigits)
            building = true
        proc onSps(f: StoredFile; part: SpsFile) =
          if building:
            for q in part.points:
              b.addPoint(roleOf(q.kind), b.lineOf(q.lineName, q.line), q.point,
                pointIndex(q.index), q.easting, q.northing, q.elevation)
            var rel = part # (`addRelations` takes the points out for a moment)
            b.addRelations(rel)
          g[].addSps(part, relationDomainOf(f.copy))
        proc onP1(f: StoredFile; pf: P1File) =
          if building:
            for lf in pf.files:
              if lf.format == pfP1:
                for r in lf.records:
                  let line = b.lineOf(r.lineName, p1Number(r.lineName))
                  let index = if r.reshoot in {'A' .. 'Z'}: int16(ord(r.reshoot) - ord('A') + 2)
                              else: 0'i16
                  b.addPoint(prSource, line, r.point, index, r.easting, r.northing, NaN)
          g[].addP1(pf)
        proc onCsv(f: StoredFile; text: string) =
          rows += g[].addCsv(text, f.name, f.role, problems, skipped)
        proc onEnd(f: StoredFile) =
          if building:
            var l = b.finish()
            l.withLevels()
            built.add l
            building = false
        readStore(dir.partOf(SurveyStoreName), ctx, StoreReader(onFile: onFile, onSps: onSps,
          onP1: onP1, onCsv: onCsv, onEnd: onEnd))
        news.survey = surveyOf(g[], names)
        news.survey.notes = doc.notes
        (news.survey.csvRows, news.survey.csvSkipped) = (rows, skipped)
        news.geometry = move g
      except JobCancelledError:
        raise
      except CatchableError as e:
        news.surveyFailure = e.msg.splitLines()[0]
        built.setLen 0
    news.layers = built.len
    for l in built.mitems:
      to.post Msg(job: ctx.id, kind: mkSurvey, layer: move l)
    news.restoreMs = float64((getMonoTime() - began).inMicroseconds) / 1000
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post(ctx.id, news)

proc planWork*(file: ptr SeismicFile; session: SessionId; g: ptr SurveyGeometry;
    names, notes: seq[string]; opts: JoinOptions; to: Poster): JobWork =
  ## The work of a job that works out what joining the project's survey `g`
  ## (already made) to open file `session` does (`planJoin`), and posts it
  ## as the import's first job does (`mkJoining`, its geometry nil: the
  ## project keeps its own). Submitted with the file in `reads`.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var plan: JoinPlan
    var survey: JoinSurvey
    {.cast(gcsafe).}:
      ctx.setPhase "matching the traces"
      plan = planJoin(file, g[], opts, proc (done, total: int): bool =
        ctx.progress(done, total))
      survey = surveyOf(g[], names)
    if plan.traces != file[].len: raise newException(JobCancelledError, "cancelled")
    survey.notes = notes
    discard ctx.progress(1, 1)
    to.post Msg(job: ctx.id, kind: mkJoining, planSession: session, plan: move plan,
      joinSurvey: move survey)
