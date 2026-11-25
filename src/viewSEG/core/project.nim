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
##   shotlogs/            copies of shot logs imported (`core/shotlog`)
##   owner.nif, .lock     who has the project open, and the lock between programs
## ```

import std/[options, os, strutils, times]
import parseSEG
import breakmodel, displaypresets, edits, filesystem, join, nif, outputbinary, outputnames,
    outputtext, processing, shotlayout, shotlog,
  sensors, stationmoves, vendormaps, vibprofile

const
  ProjectFileName* = "project.nif"       ## the project document, in the project folder
  ProjectVersion* = 1                    ## the document's format
  ProjectLayoutName* = "layout.nif"      ## the windows' arrangement in the project
  ProjectStoreFolder* = "files"          ## the store of what is remembered about files
  SurveyFolder* = "survey"
  SurveyCopies* = "survey/files"         ## the survey files copied into the project
  ShotLogsFolder* = "shotlogs"           ## copies of shot logs imported into the project
  SurveyStoreName* = "survey/survey.bin" ## the survey as imported
  CacheFolder* = "cache"
  LockName* = ".lock"                    ## the lock between programs
  OwnerName* = "owner.nif"               ## who holds the lock
  MaxProjectData* = 64                   ## data folders a project keeps, at most
  MaxShotLogs* = 64                      ## shot logs a project keeps, at most
  MaxShotLogColumns* = 256               ## columns a stored map keeps, at most
  MaxShotLogSentinels* = 64              ## sentinels a stored map keeps, at most
  MaxShotLogName* = 120                  ## a shot log's name, at most, in characters
  MaxShotLogSkip* = 1_000_000            ## lines a stored map skips, at most
  MaxOutputTexts* = 32                   ## text header templates a project keeps, at most
  MaxOutputBinaries* = 32                ## binary header sets a project keeps, at most
  MaxOutputPatterns* = 32                ## name patterns a project keeps, at most

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

  VibJobWeights* = object
    ## The job's vibrator weights, once for the project, in kilograms. Not a file
    ## header's. NaN: that weight was not set.
    holdDownKg*: float64 = NaN
    baseplateMassKg*: float64 = NaN
    reactionMassKg*: float64 = NaN
    later*: seq[NifNode]
      ## fields of the weights tree this version does not know, written back

  StoredShotLog* = object
    ## A shot log kept with the project: a short name, the copy's file name
    ## under `shotlogs/`, and how to read it. The text is the copy, not a
    ## node of the document.
    name*: string
    file*: string ## a plain file name; the copy is `shotlogs/` & file
    map*: ShotLogMap
    layout*: ShotLayout
      ## how the grid shows it: columns, widths, order and sort, by column name
    later*: seq[NifNode]
      ## fields of the log this version does not know, written back
    mapLater*: seq[NifNode]
      ## fields of the map this version does not know, written back inside it

  LastShotMap* = object
    ## The column map used last for a shot log in this project, and the header
    ## names it was read with. Removing a log does not clear it. Absent
    ## (`none`) means nothing is remembered. The names are not fields of
    ## `ShotLogMap`: a stored log's map does not keep them.
    map*: ShotLogMap
    headers*: seq[string]
    mapLater*: seq[NifNode]
      ## fields of the map this version does not know, written back inside it
    later*: seq[NifNode]
      ## fields beside the map this version does not know, written back

  StoreInfo* = object
    ## `survey.bin` as written: none while `bytes` is 0.
    format*: int
    bytes*: int64
    hash*: uint64           ## XXH64 of the whole file
    sources*, receivers*: int
    relations*: int
      ## the X records (source-domain relations; `(relations n)` in the document, as
      ## it always was, so an older build and an older document read as before)
    receiverRelations*: int ## the O records (receiver-domain relations)
    splitKnown*: bool
      ## `relations` and `receiverRelations` are the X and O counts apart; false for a
      ## document of an earlier build, whose `relations` held both

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
    outputPatterns*: seq[OutputPattern]
      ## how a file written from this project is named
    hasOutputPatterns*: bool
      ## `outputPatterns` were set in the project (else today's naming)
    outputPattern*: string
      ## the pattern used, by its label; "" is today's naming
    outputPatternLater*: seq[seq[NifNode]]
      ## children of each pattern this version does not know, written back
    outputPatternsLater*: seq[NifNode]
      ## children of `(outputPatterns)` this version does not know, written back
    outputTexts*: seq[OutputText]
      ## the SEG-Y text header templates of this project
    hasOutputTexts*: bool
      ## `outputTexts` were set in the project
    outputText*: string
      ## the template used, by its name; "" is the writer's own text
    outputTextLater*: seq[seq[NifNode]]
      ## children of each template this version does not know, written back
    outputTextsLater*: seq[NifNode]
      ## children of `(outputTexts)` this version does not know, written back
    outputBinaries*: seq[OutputBinary]
      ## the SEG-Y binary header sets of this project
    hasOutputBinaries*: bool
      ## `outputBinaries` were set in the project
    outputBinary*: string
      ## the set used, by its name; "" writes no binary header values
    outputBinaryLater*: seq[seq[NifNode]]
      ## children of each set this version does not know, written back
    outputBinariesLater*: seq[NifNode]
      ## children of `(outputBinaries)` this version does not know, written back
    auxMarks*: seq[AuxMarkEntry]
      ## the auxiliary positions marked for correlation in every file of the project, ascending
      ## by position; each `marked`, with its shift in `ms`
    auxMarksLater*: seq[NifNode]
      ## children of `(auxMarks)` this version does not know, written back
    breakModel*: BreakModel ## the first-break overlay's model in the project
    hasBreakModel*: bool ## `breakModel` was set in the project (else the user's)
    referenceId*: string
      ## the reference the plots use in this project; "" is the file's own pilot
    lastFolder*: string
      ## the folder the Files panel listed last in this project, as "N|rest": data folder
      ## N (from 0, as listed in `data`) and the path below it ("" for the folder itself),
      ## so it is found again wherever the data folder is; listed again when the project
      ## opens
    includeSubfolders*: bool
      ## the Files panel lists the subfolders' files too
    vibRoles*: seq[string]
      ## the vibrator signature's roles chosen by hand in this project, per file layout
      ## (`choiceText`)
    vibTops*: seq[string]
      ## the vibrator signature's top frequency typed per reference in this project
      ## (`topText`: "220.0 reference-id")
    vibProfile*: VibQcProfile
      ## the job's vibrator QC profile, when `hasVibProfile`: settings taken from
      ## one Vibrator window so a QC run can apply them to other files
    hasVibProfile*: bool
      ## `vibProfile` was stored; an older project, or one with none, is false
    vibJobWeights*: VibJobWeights
      ## the job's hold-down, baseplate and reaction mass, in kilograms (`jobWeights`)
    stationMoves*: StationMoves
      ## receiver stations moved during a deployment: a new position from a time
      ## on, not written into the seismic file or the survey file
    sensors*: SensorTable
      ## the sensors the traces were recorded with, one row per component, as typed
    sensorsLater*: seq[NifNode]
      ## children of `(sensors)` this version does not know, written back
    vendorChoice*: VendorChoice
      ## the vendor map rule of the project's files (`core/vendormaps`); automatic when
      ## the document says nothing
    shotLogs*: seq[StoredShotLog]
      ## shot logs imported into the project; absent in an older document is none
    shotLogsLater*: seq[NifNode]
      ## children of `(shotLogs)` this version does not know, written back
    lastShotMap*: Option[LastShotMap]
      ## the column map used last; absent in an older document is none
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
      unused*: seq[string]
        ## the copies of the files it left out (another of their kind is later in the store)
      restoreMs*: float64           ## how long the restore took
      surveyFailure*: string
    of pnKept:
      copies*: seq[SurveyCopy]
      store*: StoreInfo
      keptFailure*: string
      updated*: bool                ## the copies were updated from their originals
      refused*: seq[string]         ## copies no longer in the document that were not removed, and why
    of pnImporting:
      identities*: seq[ImportFile]
    of pnLooked, pnOriginals:
      discard

func finiteWeight(x: float64): bool {.inline.} =
  x == x and x != Inf and x != -Inf

func sameWeight(x, y: float64): bool {.inline.} =
  x == y or (x != x and y != y)

func weightsSet*(w: VibJobWeights): bool =
  ## Whether any weight was set, or a newer document left a field to keep.
  finiteWeight(w.holdDownKg) or finiteWeight(w.baseplateMassKg) or
    finiteWeight(w.reactionMassKg) or w.later.len > 0

func `==`*(a, b: VibJobWeights): bool =
  ## Whether two jobs' weights are the same, a NaN (unset) equal to a NaN.
  ## `later` is what a newer document kept, not a weight, so it is not compared.
  sameWeight(a.holdDownKg, b.holdDownKg) and
    sameWeight(a.baseplateMassKg, b.baseplateMassKg) and
    sameWeight(a.reactionMassKg, b.reactionMassKg)

func jobWeights*(d: ProjectDoc): VibJobWeights =
  ## The job's vibrator weights (hold-down, baseplate, reaction mass), in kilograms.
  d.vibJobWeights

proc `jobWeights=`*(d: var ProjectDoc; w: VibJobWeights) =
  ## Stores the job's vibrator weights. A weight not set is NaN.
  d.vibJobWeights = w

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

func windowsDeviceName(name: string): bool =
  ## Whether `name` (with or without an extension) is a name Windows keeps
  ## for a device: `CON`, `NUL`, `COM1`, `LPT3`. Opening one reaches the
  ## device, not a file.
  let stem = name.split('.', 1)[0].strip(leading = false, trailing = true,
    chars = {' ', '.'}).toUpperAscii
  stem in ["CON", "PRN", "AUX", "NUL"] or
    (stem.len == 4 and stem[0 .. 2] in ["COM", "LPT"] and stem[3] in {'1' .. '9'})

func isShotLogFile*(name: string): bool =
  ## Whether `name` can be a shot log's copy: a plain file name, not empty,
  ## not `.` or `..`, without a separator or a drive colon, and not a name
  ## Windows keeps for a device or one that ends in a dot or a space.
  name.len > 0 and name.len <= MaxShotLogName and name notin [".", ".."] and
    name.find({'/', '\\', ':'}) < 0 and name[^1] notin {'.', ' '} and
    not name.windowsDeviceName

func shotLogCopy*(name: string): string {.inline.} =
  ## The copy of a shot log named `name`, relative to the project folder.
  ShotLogsFolder & "/" & name

func isShotLogCopy*(copy: string): bool =
  ## `copy` is `shotlogs/<name>` with `<name>` a plain file name.
  const Prefix = ShotLogsFolder & "/"
  copy.startsWith(Prefix) and copy[Prefix.len .. ^1].isShotLogFile

func copyName*(name: string; taken: openArray[string]): string =
  ## A name for the copy of a file named `name` that none of `taken` has:
  ## the name itself, else "name-2.ext" and on. Characters a file name cannot
  ## have on every system (`\ / : * ? " < > |`, controls) are `_`. A trailing
  ## dot or space is dropped (Windows drops them). A name Windows keeps for
  ## a device gets a suffix, as a taken name does. The copy's place is a
  ## file name in `survey/files` or `shotlogs/`.
  var clean = name
  for c in mitems(clean):
    if c in {'\\', '/', ':', '*', '?', '"', '<', '>', '|'} or c < ' ': c = '_'
  while clean.len > 0 and clean[^1] in {'.', ' '}: clean.setLen(clean.len - 1)
  if clean.len == 0: clean = "_"
  result = clean
  var n = 2
  let (stem, ext) = (clean.changeFileExt(""), clean.splitFile.ext)
  while result in taken or result.windowsDeviceName:
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
