## The jobs of a project (docs/project.md), each off the UI thread: a project
## folder may be on a drive that does not answer, and its survey is large.
##
## - `openProjectWork` (interactive lane) reads the project document, takes
##   the lock between programs, reads the project's window arrangement,
##   removes leftover shot-log temporaries, and looks at its data folders
##   and at its survey files' originals; with a
##   `NewProject`, it makes the folder and its document first, and copies in
##   what the program remembers about the files of its data folders.
## - `keepSurveyWork` (background lane) copies the survey files imported
##   into the project and writes `survey.bin` from the copies;
##   `updateSurveyWork` copies the originals that changed again.
## - `clearSurveyWork` (background lane) takes the survey's copies and
##   `survey.bin` out of the project folder again (Clear survey).
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

import std/[locks, monotimes, os, strutils, times]
import parseSEG
import diskio, displaypresets, filememory, filesystem, identity, inbox, jobs, join, layouts,
  persist, processing, project, projectnif, session, shotlogjobs, survey, surveystore, threads,
  vendormaps

type NewProject* = object
  ## What Project > New project makes.
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
  ## `text` written to `path` atomically (`fs.writeTextAtomic`).
  fs.writeTextAtomic(path, text)

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
          if t == c.changedModified: result.state = osChanged # found so, as it stands now
          elif fullHash(path, progress) != c.full:
            result.state = osChanged # other content between
            result.readChanged = true
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

const IgnoredFolderFiles = [".ds_store", "desktop.ini", "thumbs.db"]
  ## the files a file manager leaves in a folder: a folder holding only these
  ## is empty (lower case)

proc isEmptyFolder(dir: string): bool =
  ## Nothing in `dir` but the files a file manager leaves there.
  for k, p in fs.walkDir(dir):
    if k != pcFile or p.extractFilename.toLowerAscii notin IgnoredFolderFiles: return false
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
  # What it makes is listed as it is made, so a failure part-way takes back
  # what it made, and nothing it did not make (a folder already there stays).
  var madeDirs, madeFiles: seq[string] = @[]
  try:
    if not fs.dirExists(dir):
      fs.createDir(dir)
      madeDirs.add dir
    for part in [ProjectStoreFolder, SurveyFolder, SurveyCopies, CacheFolder,
        VendorFolderName]:
      let folder = dir.partOf(part)
      if not fs.dirExists(folder):
        fs.createDir(folder)
        madeDirs.add folder
    result = ProjectDoc(name: np.name, created: getTime())
    for d in np.data:
      if result.data.len < MaxProjectData: result.data.add placeOf(dir, d)
    if np.takePresets: (result.displayPresets, result.hasPresets) = (np.presets, true)
    if np.takeProcessing: (result.processing, result.hasProcessing) = (np.processing, true)
    madeFiles.add documentOf(dir)
    writeWhole(documentOf(dir), projectDocument(result))
    for (name, text) in VendorNotes:
      madeFiles.add dir.partOf(VendorFolderName) / name
      writeWhole(dir.partOf(VendorFolderName) / name, text)
    if np.bringFrom.len > 0 and np.data.len > 0:
      var problems: seq[string] = @[]
      for r in listRecords(Store(home: np.bringFrom), problems, look = false):
        var inData = false
        for d in np.data:
          if realPath(r.path).isInside(realPath(d)): inData = true
        let dest = dir.partOf(ProjectStoreFolder) / r.doc
        if inData and r.doc.len > 0 and not fs.fileExists(dest):
          try:
            madeFiles.add dest
            fs.copyFile(np.bringFrom / r.doc, dest)
            inc brought
          except CatchableError:
            discard
  except CatchableError:
    for i in countdown(madeFiles.high, 0): discard fs.tryRemoveFile(madeFiles[i])
    for i in countdown(madeDirs.high, 0): discard fs.tryRemoveDir(madeDirs[i])
    raise

proc prepareVendorFolder(dir: string) =
  ## The project's `vendormaps` folder and its notes, made when they are not
  ## there (a project made by an older program); what cannot be made is left,
  ## and nothing says so. Never replaces a file.
  let folder = dir.partOf(VendorFolderName)
  try:
    if not fs.dirExists(folder): fs.createDir(folder)
    for (name, text) in VendorNotes:
      if name == VendorReadmeName and fs.fileExists(folder / "README.md"): continue # one note
      if not fs.fileExists(folder / name): writeWhole(folder / name, text)
  except CatchableError:
    discard

var
  releasing: seq[tuple[id: int; dir: string; lock: FileLock]]
    ## the locks that are to be let go by a job queued but not yet run
  releasingNext = 0
  releasingGuard: Lock

initLock releasingGuard

proc stageRelease*(dir: string; lock: FileLock): int =
  ## Notes that `lock` of the project in `dir` is to be let go by `unlockWork(id)`: a program
  ## that opens that project first lets it go itself, so that a project closed and opened at
  ## once is not found held by the program that has just closed it.
  withLock releasingGuard:
    inc releasingNext
    result = releasingNext
    {.cast(gcsafe).}:
      releasing.add (releasingNext, dir, lock)

proc letGo(id: int; dir: string) =
  ## Lets go the staged lock `id`, or every one staged for `dir` when `id` is 0.
  var mine: seq[FileLock] = @[]
  withLock releasingGuard:
    {.cast(gcsafe).}:
      var kept: seq[tuple[id: int; dir: string; lock: FileLock]] = @[]
      for r in releasing:
        if (id != 0 and r.id == id) or (id == 0 and r.dir == dir): mine.add r.lock
        else: kept.add r
      releasing = kept
  for l in mine.mitems: fs.unlock(l)

proc openProjectWork*(dir: string; to: Poster; make = false; np = NewProject();
    writes: ptr DiskIo = nil): JobWork =
  ## The work of a job that opens (with `make`, first makes) the project in
  ## folder `dir` and posts what it found (`pnOpened`). A close queues the
  ## project document and does not wait: every field of that document (the
  ## reference choice, the presets, the processing, the survey) is written
  ## before this job reads it, or a fast reopen would load the one from before.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var news = ProjectNews(dir: dir, kind: pnOpened, created: make)
    {.cast(gcsafe).}:
      try:
        if not make and writes != nil: writes.flush()
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
        letGo(0, dir) # (a close of this project not yet carried out: see `stageRelease`)
        news.lock = fs.lockFile(dir / LockName, initDuration())
        if news.lock.locked:
          if news.doc.version <= ProjectVersion: prepareVendorFolder(dir) # (a read-only project is left alone)
          try:
            writeWhole(dir / OwnerName, ownerDocument(Owner(host: hostName(),
              user: getEnv("USER", getEnv("USERNAME")), pid: getCurrentProcessId(),
              since: getTime())))
          except CatchableError:
            discard # a note only
          sweepShotLogTemps(dir, news.doc.shotLogs)
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

proc unlockWork*(id: int): JobWork =
  ## The work of a job that lets a project's lock go (a close on a share
  ## may take a moment); nothing when the program that opens the project has done it.
  result = proc (ctx: JobContext) {.gcsafe.} =
    letGo(id, "")

proc stopAtCancel(ctx: JobContext; done, total: int64): bool =
  ## A progress callback for `fullHash`: a cancel stops the job.
  if not ctx.progress(done, total): raise newException(JobCancelledError, "cancelled")
  true

proc copyIn(ctx: JobContext; dir, source, name: string; tmps: var seq[(string, string)]):
    string =
  ## Copies `source` for the project's survey copies as `name`, in pieces,
  ## each one a place for a cancel (the temporary file is removed then); its
  ## path relative to the project folder. The copy is written beside its
  ## place, to a temporary file named for the job (no other job's is the
  ## same), noted in `tmps` (temporary, final): `commitCopies` puts it in
  ## place once the survey that reads it is written.
  result = SurveyCopies & "/" & name
  let dest = dir.partOf(result)
  let tmp = dest & "." & $int(ctx.id) & ".tmp"
  fs.createDir(dest.parentDir)
  tmps.add (tmp, dest)
  var (src, dst) = (File(nil), File(nil))
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
    finally:
      close(dst)
  finally:
    close(src)

proc commitCopies(tmps: seq[(string, string)]; job: JobId) =
  ## Puts the copies written to temporary files in place: each old copy is
  ## first set aside (a name made from the job), the new one moved in. When a
  ## move fails, the new ones put in place are removed and the old ones come
  ## back, so the copies are never a mixture of both; the set-aside ones are
  ## removed when all is in place.
  var aside: seq[(string, string)] = @[] # (copy, where its old one is)
  var placed: seq[string] = @[]
  try:
    for (tmp, dest) in tmps:
      if fs.fileExists(dest):
        let old = dest & "." & $int(job) & ".old"
        fs.moveFile(dest, old)
        aside.add (dest, old)
      fs.moveFile(tmp, dest)
      placed.add dest
  except CatchableError:
    for dest in placed: discard fs.tryRemoveFile(dest)
    for (dest, old) in aside:
      try: fs.moveFile(old, dest)
      except CatchableError: discard # nothing more can be done: the old copy stays under its set-aside name
    raise
  for (_, old) in aside: discard fs.tryRemoveFile(old)

proc dropCopies(tmps: seq[(string, string)]) =
  ## Removes the temporary files of copies that were not put in place.
  for (tmp, _) in tmps: discard fs.tryRemoveFile(tmp)

func isJobTemporary(name: string): bool =
  ## Whether `name` ends as a copy's temporary file does (`copyIn`):
  ## `.<digits of a job>.tmp`.
  if not name.endsWith(".tmp"): return false
  let stem = name[0 ..< name.len - 4]
  var n = 0
  while n < stem.len and stem[stem.len - 1 - n] in {'0' .. '9'}: inc n
  n > 0 and n < stem.len and stem[stem.len - 1 - n] == '.'

proc sweepTemporaries(dir: string; recorded: openArray[SurveyCopy]) =
  ## Removes the temporary copies an earlier run left (it was cut short): no
  ## job of this program has any, the survey folder being exclusive. Only a
  ## name made as a job makes it (`isJobTemporary`) and never one that is a
  ## recorded copy: a survey file may be named `day1.tmp`.
  let copies = dir.partOf(SurveyCopies)
  var names: seq[string] = @[]
  for c in recorded: names.add c.copy.extractFilename
  try:
    if fs.dirExists(copies):
      for kind, path in fs.walkDir(copies):
        if kind == pcFile and path.extractFilename.isJobTemporary and
            path.extractFilename notin names: discard fs.tryRemoveFile(path)
  except OSError:
    discard

proc clearSurveyWork*(dir: string): JobWork =
  ## The work of a job that removes the survey folder of the project in `dir`
  ## (its copies of the survey files, `survey.bin`, a copy's temporaries):
  ## Clear survey. The survey files the copies were made from are not touched.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      discard fs.tryRemoveDir(dir.partOf(SurveyFolder)) # (`os.removeDir`: with what is in it)

type Resumed = tuple[path: string; outside: bool]

proc resolveResume(dir: string; f: ImportFile; existing: seq[SurveyCopy];
    roots: seq[string]): Resumed =
  ## The original of a file of an import that was cut short, if it is the
  ## file the import began with: at the path recorded (relative to the
  ## project, or absolute; never searched for beside the project or by its
  ## name), of the size and the first and last 64 KiB recorded, and inside
  ## the project folder or one of its data folders `roots` (resolved paths
  ## compared: a project handed over may name any path). A path inside the
  ## survey copies is accepted when it is one of the `existing` copies, of
  ## the size and ends recorded for it. "" when it is not; `outside` when a
  ## path recorded is elsewhere (never copied without a click).
  var places: seq[string] = @[]
  if f.original.path.len > 0:
    places.add normalizedPath(dir / f.original.path.replace('/', DirSep))
  if f.original.absolute.len > 0 and f.original.absolute notin places:
    places.add f.original.absolute
  let copies = realPath(dir.partOf(SurveyCopies))
  for path in places:
    var inside = false
    let real = realPath(path)
    for r in roots:
      if real.isInside(realPath(r)): inside = true
    if not inside:
      result.outside = true
      continue
    try:
      if fs.fileExists(path):
        var t: Time
        let id = quickIdentity(path, t)
        if real.isInside(copies):
          for c in existing:
            if normalizedPath(dir.partOf(c.copy)) == normalizedPath(path) and
                id.size == c.size and id.quick == c.quick: return (path, false)
        elif f.known and id.size == f.size and id.quick == f.quick: return (path, false)
    except IOError, OSError:
      discard

proc ownCopy*(dir, copy: string): tuple[path, why: string] =
  ## The path of `copy` (a name from a project's document) when it is a plain file name
  ## directly in the project's own survey/files folder and no folder on the way there is a
  ## symlink; else "" and why not. The entry itself may be a link: only the link goes.
  let name = copy.extractFilename
  if name.len == 0 or name in [".", ".."] or copy != SurveyCopies & "/" & name or
      name.find({'\\', ':', '\0'}) >= 0:
    return ("", "it is not a plain file name in " & SurveyCopies)
  for folder in [dir.partOf("survey"), dir.partOf(SurveyCopies)]:
    var kind = pcDir
    try: kind = fs.getFileInfo(folder, followSymlink = false).kind
    except OSError: return ("", folder & " cannot be looked at")
    if kind in {pcLinkToDir, pcLinkToFile}:
      return ("", folder & " is a link")
  (dir.partOf(copy), "")

proc keepSurveyWork*(dir: string; files: seq[JoinFile]; existing: seq[SurveyCopy];
    to: Poster; resume: seq[ImportFile] = @[]; dataFolders: seq[string] = @[]): JobWork =
  ## The work of a job that copies survey files `files` into the project in
  ## `dir` (a file already a copy of it is kept as it is), writes
  ## `survey.bin` from the copies and posts both (`pnKept`); the copies come
  ## in place only after `survey.bin` is written, and a job that fails or is
  ## cancelled leaves none. Copies of `existing` no longer named are removed.
  ## It first posts the identity of each original (`pnImporting`), which the
  ## project document keeps. With `resume` (one per file: an import that a
  ## close or a quit cut short, taken up again at the next open), each
  ## original is taken only if it is the file the import began with and lies
  ## in the project folder or one of `dataFolders`.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var news = ProjectNews(dir: dir, kind: pnKept)
    var tmps: seq[(string, string)] = @[]
    {.cast(gcsafe).}:
      try:
        sweepTemporaries(dir, existing)
        var taken: seq[string] = @[]
        let copies = dir.partOf(SurveyCopies)
        var paths: seq[string] = @[]
        for i, jf in files:
          if i < resume.len:
            let found = resolveResume(dir, resume[i], existing, @[dir] & dataFolders)
            if found.path.len == 0:
              if found.outside:
                raise newException(IOError, "the import of the survey was interrupted, and " &
                  resume[i].original.displayName & " is not in the project or its data " &
                  "folders, so it is not copied again by itself: import the survey again")
              raise newException(IOError, "the import of the survey was interrupted and its " &
                "files are not as they were (" & resume[i].original.displayName & "): import " &
                "the survey again")
            paths.add found.path
          else: paths.add jf.path
        if resume.len == 0: # the identities the document keeps, until the copy is whole
          var identities = ProjectNews(dir: dir, kind: pnImporting)
          for i, jf in files:
            var f = ImportFile(kind: jf.kind, role: jf.role, original: placeOf(dir, paths[i]))
            if not paths[i].isInside(copies):
              var t: Time
              let id = quickIdentity(paths[i], t)
              (f.known, f.size, f.modified, f.quick) = (true, id.size, t, id.quick)
            identities.identities.add f
          to.post(ctx.id, identities)
        var sources: seq[string] = @[]
        for i, jf in files:
          let path = paths[i]
          ctx.setPhase "copying " & path.extractFilename & " into the project"
          if path.isInside(copies):
            var kept = false
            for c in existing:
              if dir.partOf(c.copy) == path:
                news.copies.add c
                sources.add ""
                taken.add c.copy.extractFilename
                kept = true
            if not kept: raise newException(IOError, path & " is not a survey file of it")
          else:
            var t: Time
            let id = quickIdentity(path, t)
            let name = copyName(path.extractFilename, taken)
            taken.add name
            let copy = ctx.copyIn(dir, path, name, tmps)
            sources.add tmps[^1][0]
            news.copies.add SurveyCopy(kind: jf.kind, role: jf.role, copy: copy,
              original: placeOf(dir, path), size: id.size, modified: t, quick: id.quick,
              full: fullHash(tmps[^1][0], proc (done, total: int64): bool =
              ctx.stopAtCancel(done, total)))
          if not ctx.progress(i + 1, files.len + 1):
            raise newException(JobCancelledError, "cancelled")
        news.store = writeStore(dir, news.copies, ctx, sources)
        commitCopies(tmps, ctx.id)
        tmps.setLen 0
        for c in existing:
          var still = false
          for x in news.copies:
            if x.copy == c.copy: still = true
          if not still:
            let (old, why) = ownCopy(dir, c.copy)
            if old.len > 0: discard fs.tryRemoveFile(old)
            else: news.refused.add c.copy & " was not removed: " & why
      except JobCancelledError:
        dropCopies(tmps)
        raise
      except CatchableError as e:
        dropCopies(tmps)
        news.keptFailure = e.msg.splitLines()[0]
    to.post(ctx.id, news)

proc updateSurveyWork*(dir: string; copies: seq[SurveyCopy]; originals: seq[OriginalLook];
    to: Poster): JobWork =
  ## The work of a job that copies the originals that changed (`osChanged`
  ## in `originals`) for their copies in the project in `dir`, writes
  ## `survey.bin` again from them and only then puts them over the copies,
  ## and posts it (`pnKept`, `updated`). An update refused (an original written
  ## while it is copied) or cancelled leaves the copies, the document and
  ## `survey.bin` as they were.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var news = ProjectNews(dir: dir, kind: pnKept, updated: true, copies: copies)
    var tmps: seq[(string, string)] = @[]
    {.cast(gcsafe).}:
      try:
        sweepTemporaries(dir, copies)
        var sources = newSeq[string](copies.len)
        for i, c in copies:
          if i < originals.len and originals[i].state == osChanged:
            let src = originals[i].path
            # The identity taken after the copy, and the same as before it: a
            # file written while it was copied is not recorded as a state the
            # copy is not (one more try, then it is refused).
            var t: Time
            var id: FileIdentity
            var same = false
            let mark = tmps.len
            for attempt in 1 .. 2:
              var before: Time
              let first = quickIdentity(src, before)
              ctx.setPhase "copying " & src.extractFilename & " into the project again" &
                (if attempt > 1: " (once more)" else: "")
              dropCopies(tmps[mark ..< tmps.len])
              tmps.setLen mark
              discard ctx.copyIn(dir, src, c.copy.extractFilename, tmps)
              id = quickIdentity(src, t)
              same = id.size == first.size and id.quick == first.quick and t == before
              if same: break
            if not same:
              raise newException(IOError, src.extractFilename & " changed while it was " &
                "copied; update again when it is not being written")
            news.copies[i].size = id.size
            news.copies[i].modified = t
            news.copies[i].quick = id.quick
            news.copies[i].full = fullHash(tmps[^1][0], proc (done, total: int64): bool =
              ctx.stopAtCancel(done, total))
            news.copies[i].original = placeOf(dir, src)
            news.copies[i].changedModified = Time()
            sources[i] = tmps[^1][0]
        news.store = writeStore(dir, news.copies, ctx, sources)
        commitCopies(tmps, ctx.id)
        tmps.setLen 0
      except JobCancelledError:
        dropCopies(tmps)
        raise
      except CatchableError as e:
        dropCopies(tmps)
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
        # one file of each kind: of two the store holds the later is used, the earlier is
        # neither on the map nor in the geometry (a project saved when more were allowed)
        # (the kinds come from the store's file headers: its record blocks are passed over,
        # so the store is read once, below)
        var stored: seq[tuple[copy: string; kinds: set[SurveyContent]]] = @[]
        try:
          for f in storeFiles(dir.partOf(SurveyStoreName)):
            stored.add (f.copy, contentsOf(f.fileKind, f.domain))
        except IOError:
          discard # the read below says why the store cannot be used
        var skip = newSeq[bool](stored.len)
        var taken: set[SurveyContent] = {}
        for k in countdown(stored.high, 0):
          if stored[k].kinds * taken != {}:
            skip[k] = true
            news.unused.add stored[k].copy
          else: taken = taken + stored[k].kinds
        var at = -1
        var skipping = false
        var (rows, skipped) = (0, 0)
        var problems: seq[string] = @[]
        proc onFile(f: StoredFile) =
          inc at
          skipping = at < skip.len and skip[at]
          if skipping: return
          names.add f.name
          if layers and f.kind != jkCsv:
            b = initSurveyFileBuilder(dir.partOf(f.copy), f.fileKind, f.size, f.modified,
              naming, opts.trailingDigits)
            building = true
        proc onSps(f: StoredFile; part: SpsFile) =
          if skipping: return
          if building:
            for q in part.points:
              b.addPoint(roleOf(q.kind), b.lineOf(q.lineName, q.line), q.point,
                pointIndex(q.index), q.easting, q.northing, q.elevation)
            var rel = part # (`addRelations` takes the points out for a moment)
            b.addRelations(rel, f.domain)
          g[].addSps(part, f.domain)
        proc onP1(f: StoredFile; pf: P1File) =
          if skipping: return
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
          if skipping: return
          rows += g[].addCsv(text, f.name, f.role, problems, skipped)
        proc onEnd(f: StoredFile) =
          if skipping: return
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
