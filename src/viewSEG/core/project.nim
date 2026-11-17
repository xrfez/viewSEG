## A project: one folder the user makes for one job, the home of what the
## job keeps (docs/project.md). This module holds its types and its rules,
## with no file read or written: where its parts are, how a path kept in
## it is looked for again (relative to the project folder first, then where
## it was last found, then beside the project), and what a folder named to
## the program is (a project, or a data folder).
##
## ```
## <project>/
##   project.nif          the project document (`core/projectnif`)
##   layout.nif           the windows as they were arranged in the project
##   files/               what is remembered about each data file (`core/filememory`)
##   survey/files/        copies of the survey files imported
##   survey/survey.bin    the survey as imported (`core/surveystore`)
##   cache/               what can be made again
##   vendormaps/          the project's vendor header maps (`core/vendormaps`)
##   owner.nif, .lock     who has the project open, and the lock between programs
## ```

import std/[os, strutils, times]
import parseSEG
import displaypresets, filesystem, join, nif, processing, vendormaps

const
  ProjectFileName* = "project.nif"       ## the project document, in the project folder
  ProjectVersion* = 1                    ## the document's format
  ProjectLayoutName* = "layout.nif"      ## the windows' arrangement in the project
  ProjectStoreFolder* = "files"          ## the store of what is remembered about files
  SurveyFolder* = "survey"
  SurveyCopies* = "survey/files"         ## the survey files copied into the project
  SurveyStoreName* = "survey/survey.bin" ## the survey as imported
  CacheFolder* = "cache"
  LockName* = ".lock"                    ## the lock between programs
  OwnerName* = "owner.nif"               ## who holds the lock
  MaxProjectData* = 64                   ## data folders a project keeps, at most

type
  ProjectPath* = object
    ## A folder or file a project names: relative to the project folder, and
    ## where it was last found.
    path*: string ## relative to the project folder ("/" between parts); "" when there is none
    absolute*: string ## where it was last found

  SurveyCopy* = object
    ## A survey file imported into the project: its copy, and the original
    ## as it was when copied.
    kind*: JoinFileKind
    role*: CsvRole ## CSV: which stations its rows are
    copy*: string ## the copy, relative to the project folder ("survey/files/a.sps")
    original*: ProjectPath
    size*: int64 ## the original's size, when copied
    modified*: Time ## its modification time then
    quick*: uint64 ## its first and last 64 KiB's hash then (`quickIdentity`)
    full*: uint64 ## the hash of every byte of its copy (`fullHash`); 0 when not known
    changedModified*: Time
      ## the original's modification time when it was found changed by a read of every
      ## byte: not read again until its time moves

  ImportFile* = object
    ## A survey file of an import that is being copied into the project: its
    ## original, until the copy is whole and a `SurveyCopy` takes its place.
    kind*: JoinFileKind
    role*: CsvRole
    original*: ProjectPath
    known*: bool ## the original's identity below was taken
    size*: int64 ## the original's size when the import began
    modified*: Time ## its modification time then
    quick*: uint64 ## its first and last 64 KiB's hash then (`quickIdentity`)

  StoreInfo* = object
    ## `survey.bin` as written: none while `bytes` is 0.
    format*: int
    bytes*: int64
    hash*: uint64 ## XXH64 of the whole file
    sources*, receivers*, relations*: int

  ProjectDoc* = object
    ## What the project document holds.
    version*: int = ProjectVersion ## as read: a later version's is opened read-only
    name*: string
    created*: Time
    data*: seq[ProjectPath]        ## the data folders, the first listed when the project opens
    survey*: seq[SurveyCopy]       ## the survey files imported, in the order imported
    importing*: seq[ImportFile]    ## an import being copied in: taken up at the next open
    options*: JoinOptions          ## the import's options
    units*: JoinUnits              ## its units, as the user confirmed them or the headers said
    notes*: seq[string]            ## what the survey files' headers say of the datum and the units
    imported*: Time                ## when the survey was imported
    store*: StoreInfo
    displayPresets*: seq[DisplayPreset]
    processing*: Processing        ## the plot's filters in the project
    hasProcessing*: bool           ## `processing` was set in the project (else the user's stand)
    hasPresets*: bool              ## `displayPresets` were set in the project (else the user's)
    referenceId*: string
      ## the reference the plots use in this project; "" is the file's own pilot
    vendorChoice*: VendorChoice
      ## the vendor map rule of the project's files (`core/vendormaps`); automatic when
      ## the document says nothing
    later*: seq[NifNode]
      ## what the document holds that this version does not know (a later
      ## version's), written back as it was

  FolderAction* = enum
    ## What `project folder` does to a project's data folders.
    faAdd = "add"
    faRemove = "remove"
    faLocate = "locate" ## a missing folder is at the place given

  PlaceState* = enum
    ## Where a folder or file a project names stands.
    psLooking = "looking"           ## not looked at yet
    psFound = "found"
    psMissing = "missing"           ## at none of its places
    psNotAnswering = "notAnswering" ## its drive did not answer

  OriginalState* = enum
    ## A survey file's original against its copy in the project.
    osLooking = "looking"
    osAsCopied = "asCopied" ## its size, modification time and hash are as when copied
    osChanged = "changed"   ## it changed since it was copied
    osNotFound = "notFound" ## it is not where it was: the copy stands for it

  OriginalLook* = object
    ## What a look at an original found.
    state*: OriginalState
    path*: string      ## where it was found ("" when it was not)
    size*: int64
    modified*: Time
    readChanged*: bool ## found changed by a read of every byte, its time having moved
    confirmed*: bool   ## its time moved but every byte is the copy's: the new time is recorded

  Owner* = object
    ## Who has a project open (`owner.nif`): said to a second program.
    host*, user*: string
    pid*: int
    since*: Time

  PlaceLook* = object
    ## What a look at a data folder found.
    state*: PlaceState
    path*: string ## where it was found; "" when it was not

  NewsKind* = enum
    ## What a project's job posts (`mkProject`).
    pnOpened    ## a project opened (or made): its document, its lock, where its parts are
    pnSurvey    ## its survey made from `survey.bin`: the joins' geometry (the map's
                ## layers come as `mkSurvey`, one a file)
    pnKept      ## survey files copied into it and `survey.bin` written
    pnImporting ## the identity of the originals an import began to copy
    pnLooked    ## its data folders looked at again
    pnOriginals ## its survey originals looked at (a job of their own: they may be large and far)

  ProjectNews* = object
    ## A project's job's result, for the UI thread.
    dir*: string                    ## the project folder
    folders*: seq[PlaceLook]        ## pnOpened, pnLooked: each data folder
    originals*: seq[OriginalLook]   ## pnOpened, pnLooked: each survey file's original
    case kind*: NewsKind
    of pnOpened:
      doc*: ProjectDoc
      failure*: string              ## why it could not be opened or made; "" when it was
      problems*: seq[string]        ## what in its document could not be used
      lock*: FileLock               ## taken: this program writes the project
      owner*: Owner                 ## who holds the lock, when it was not taken
      layout*: string               ## the project's window arrangement; "" for none
      created*: bool                ## made by New project
      brought*: int                 ## documents of what is remembered copied into it
      storeThere*: bool             ## `survey.bin` is there, of the size the document says
    of pnSurvey:
      geometry*: ref SurveyGeometry ## moved, never shared; nil when it failed
      survey*: JoinSurvey
      layers*: int                  ## the layers posted before it
      restoreMs*: float64           ## how long the restore took
      surveyFailure*: string
    of pnKept:
      copies*: seq[SurveyCopy]
      store*: StoreInfo
      keptFailure*: string
      updated*: bool                ## the copies were updated from their originals
    of pnImporting:
      identities*: seq[ImportFile]
    of pnLooked, pnOriginals:
      discard

func hasSurvey*(d: ProjectDoc): bool {.inline.} =
  ## Whether a survey was imported into the project.
  d.survey.len > 0

func hasImport*(d: ProjectDoc): bool {.inline.} =
  ## Whether an import is being copied into the project.
  d.importing.len > 0

func hasStore*(d: ProjectDoc): bool {.inline.} =
  ## Whether `survey.bin` was written for it.
  d.store.bytes > 0

func projectDirOf*(path: string): string =
  ## The project folder `path` names: the folder itself, or the folder of a
  ## `project.nif` named. Touches no disk.
  if path.extractFilename == ProjectFileName: path.parentDir else: path

func documentOf*(dir: string): string {.inline.} =
  ## The project document of the project folder `dir`.
  dir / ProjectFileName

func partOf*(dir, part: string): string {.inline.} =
  ## A part of the project in `dir` (`SurveyStoreName`, `ProjectStoreFolder`).
  dir / part.replace('/', DirSep)

func isInside*(path, folder: string): bool =
  ## Whether `path` is `folder` or inside it (both absolute and normalized).
  if folder.len == 0: return false
  let f = folder.strip(leading = false, chars = {DirSep, AltSep})
  when defined(windows):
    let (p, q) = (path.toLowerAscii, f.toLowerAscii)
  else:
    let (p, q) = (path, f)
  p == q or (p.len > q.len and p.startsWith(q) and p[q.len] in {DirSep, AltSep})

proc placeOf*(dir, target: string): ProjectPath =
  ## `target` (absolute) as the project in `dir` keeps it: relative to `dir`
  ## where it can be (on another drive it cannot), and absolute.
  result = ProjectPath(absolute: target)
  try:
    let rel = relativePath(target, dir)
    if rel.len > 0 and not rel.isAbsolute: result.path = rel.replace(DirSep, '/')
  except Exception:
    discard

func candidates*(p: ProjectPath; dir: string): seq[string] =
  ## Where `p` is looked for, in order: relative to the project folder `dir`,
  ## where it was last found, then a folder or file of the same name beside
  ## the project folder (a project handed over with its data beside it).
  result = @[]
  if p.path.len > 0: result.add normalizedPath(dir / p.path.replace('/', DirSep))
  if p.absolute.len > 0 and p.absolute notin result: result.add p.absolute
  let name = (if p.absolute.len > 0: p.absolute else: p.path.replace('/', DirSep)).
    strip(leading = false, chars = {DirSep, AltSep}).extractFilename
  if name.len > 0:
    let beside = normalizedPath(dir.parentDir / name)
    if beside notin result: result.add beside

func displayName*(p: ProjectPath): string =
  ## What a folder or file is called: its last part.
  let s = (if p.absolute.len > 0: p.absolute else: p.path).strip(leading = false,
    chars = {DirSep, AltSep, '/'})
  result = s.extractFilename
  if result.len == 0: result = s

func copyName*(name: string; taken: openArray[string]): string =
  ## A name for the copy of a survey file named `name` that none of `taken`
  ## has: the name itself, else "name-2.ext" and on. Characters a file name
  ## cannot have on every system (`\ / : * ? " < > |`, controls) are `_`:
  ## the copy's place is a file name in `survey/files`.
  var clean = name
  for c in mitems(clean):
    if c in {'\\', '/', ':', '*', '?', '"', '<', '>', '|'} or c < ' ': c = '_'
  result = clean
  var n = 2
  let (stem, ext) = (clean.changeFileExt(""), clean.splitFile.ext)
  while result in taken:
    result = stem & "-" & $n & ext
    inc n

func moved*(p: ProjectPath; fromDir, toDir: string): ProjectPath =
  ## `p` re-pointed when the folder `fromDir` it was under is now `toDir`
  ## (a drive mounted elsewhere): its absolute place moves with it.
  result = p
  if p.absolute.isInside(fromDir):
    result.absolute = toDir / p.absolute[fromDir.strip(leading = false,
      chars = {DirSep, AltSep}).len .. ^1].strip(trailing = false, chars = {DirSep, AltSep})
    result.absolute = result.absolute.normalizedPath

func projectNameProblem*(name: string): string =
  ## Why `name` cannot name a project folder ("" when it can).
  let n = name.strip
  if n.len == 0: "it is empty"
  elif n.len > 120: "it is longer than 120 characters"
  elif n in [".", ".."]: "it is not a name"
  else:
    var bad = ""
    for c in n:
      if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|'} or ord(c) < 32:
        bad = "it holds " & (if ord(c) < 32: "a control character" else: "'" & c & "'")
        break
    bad

func untitled*(dir: string): string =
  ## A project's name when its document gives none: its folder's.
  dir.strip(leading = false, chars = {DirSep, AltSep}).extractFilename
