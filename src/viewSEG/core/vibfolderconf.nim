## The vibrator QC configuration a folder run is made with, read from the
## project: the profile the Vibrator signature window keeps as the user sets
## it, the project's chosen reference, the force scale in force and the job's
## weights. A run asks for nothing else; when the project has no profile the
## run is not configured.

import std/[os, sequtils]
import analysis, openchoice, project, references, settings, state, vibfolderqc, vibprofile

const
  NotConfigured* = "Vibrator signature QC is not configured."
  WhereToConfigure* = "Set it in a Vibrator signature window: Analysis > New plot > " &
    "Vibrator, on a signature file."

  StillListing* = "The folder is still being listed: run again when the listing is done."
  ReadOnlyProject* = "The project is read-only: the QC settings cannot be kept in it."
  ReferencesLoading* = "The references are being read."
  ReferenceMissing* = "The chosen reference is not in the archive: choose a reference " &
    "(Analysis > References). To measure against each file's recorded reference, choose a " &
    "reference that is a trace of the record (Analysis > References)."

type
  ReferenceState* = enum
    ## Which reference a run measures against.
    rfNone     ## none is chosen: each file's recorded reference
    rfStored   ## a stored sweep of the archive
    rfRecorded ## a reference that is a trace of the record: each file's recorded reference
    rfLoading  ## the archive is still being read: not known yet
    rfMissing  ## the chosen reference is not in the archive

  VibQcConfig* = object
    ## What a run uses. Copied out of `AppState`, so a job never reads the state.
    configured*: bool
    profile*: VibQcProfile      ## as stored, with the chosen reference and force scale in force
    ask*: VibQcAsk
    weights*: VibJobWeights
    reference*: FolderReference ## the archive reference; no path: the recorded pilot
    referenceName*: string      ## the name of the reference measured against; "": the recorded one
    referenceState*: ReferenceState
    unsetWhy*: string           ## when not configured: why no settings could be kept, if known
    blocked*: string            ## why a run cannot start (the reference is not known); "": it can

func archiveIds(st: AppState): seq[string] =
  result = @[]
  if not st.referencesLoaded: return
  for e in st.references.entries:
    if e.id.len > 0: result.add e.id

func referenceChoice*(loaded: bool; index: ReferenceIndex; home, id: string): tuple[
    reference: FolderReference; name: string; state: ReferenceState] =
  ## The archive entry `id` names: its name, how it is measured against, and, for a
  ## stored sweep, where its file is. A trace of the record (a pilot rule) has no
  ## file: each file's recorded reference is used, and the entry's name says so.
  result.state = rfNone
  if id.len == 0: return
  if not loaded:
    result.state = rfLoading
    return
  result.state = rfMissing
  for e in index.entries:
    if e.id == id:
      result.name = e.name
      if e.isPilot:
        result.state = rfRecorded
        result.reference = FolderReference(name: e.name, recorded: true)
      elif not (e.file.len == 0 or home.len == 0):
        result.state = rfStored
        result.reference = FolderReference(path: home / e.file, name: e.name,
          startMs: e.timeStart, exactTopHz: generatedTopHz(e))
      return

func vibQcConfig*(st: AppState): VibQcConfig =
  ## The configuration in force. The project's chosen reference is used; the
  ## profile's stored one only when none is chosen; either with the top the project keeps
  ## for it now. The force scale is the one set now. Not configured without an open project that holds a profile.
  if not (st.inProject and st.project.doc.hasVibProfile):
    if st.inProject and st.project.readOnly: result.unsetWhy = ReadOnlyProject
    return
  result.configured = true
  result.profile = st.project.doc.vibProfile
  let chosen = st.chosenReference
  if chosen.len > 0: result.profile.referenceId = chosen
  if result.profile.referenceId.len > 0:
    # the top a window measured against that reference takes: the one the project keeps for it
    # now, not the one the profile held when it was stored (a top typed since on a window that
    # writes no profile, a SEG-Y one's, changes the project's alone)
    result.profile.topHz = topsOf(st.project.doc.vibTops).topOf(result.profile.referenceId)
  result.profile.forceScale = st.settings.forceScale
  result.ask = applied(result.profile, archiveIds(st))
  result.ask.layouts = st.vibRoleChoices
  result.ask.tops = st.project.doc.vibTops
  result.ask.segyHundredPct = st.settings.plotOptions.vibrator.forceHundredPct
  result.ask.segyTargetPct = st.settings.plotOptions.vibrator.targetPct
  (result.ask.segyLimits, result.ask.segyQcWindowMs, result.ask.segyHarmonics) = (
    st.settings.plotOptions.vibrator.qc, st.settings.plotOptions.vibrator.qcWindowMs,
    st.settings.plotOptions.vibrator.harmonics)
  result.weights = st.project.doc.vibJobWeights
  let found = referenceChoice(st.referencesLoaded, st.references, st.referencesHome,
    result.profile.referenceId)
  result.reference = found.reference
  result.referenceName = found.name
  result.referenceState = found.state
  result.blocked = case found.state
    of rfLoading: ReferencesLoading
    of rfMissing: ReferenceMissing
    else: ""

func choicesAt*(st: AppState; paths: openArray[string]): seq[SignatureChoice] =
  ## The options each of the files at `paths` (canonical) is decoded with, as a window opens it
  ## now (`openChoiceOf`): those it was reopened with, else those given for every file of its
  ## kind in the listing, else the defaults. In memory: no file is read.
  result = newSeq[SignatureChoice](paths.len)
  for i, path in paths: result[i] = st.openChoiceOf(path).signature

proc runRefusal*(st: AppState): string =
  ## Why a folder run is not started now: the Files listing is still being made, so the
  ## options its files open with are not known. Empty when a run may start.
  if st.fileList.scanning: StillListing else: ""

proc canonicalPaths*(files: openArray[FolderListed]): seq[string] =
  ## The canonical path of each of `files` (`canonical`), as `choicesAt` takes them.
  result = newSeq[string](files.len)
  for i, f in files: result[i] = canonical(f.path)

proc folderChoices*(st: AppState; files: openArray[FolderListed]): seq[SignatureChoice] =
  ## The options each of `files` is decoded with, as a window opens it now (`choicesAt`).
  st.choicesAt(canonicalPaths(files))

type FolderRunKey* = object
  ## Everything a folder run is judged with beside what its configuration's lines show: the
  ## whole ask (the roles, polarities and ground force switch chosen per file layout, the tops
  ## typed, a SEG-Y window's 100 % force and drive level among them), the job's weights, the
  ## reference, and each file's open options. A run made now with another key judges with other
  ## settings.
  settings: string
  choices: seq[SignatureChoice]

proc runKeyOf*(c: VibQcConfig; choices: seq[SignatureChoice]): FolderRunKey =
  ## The key of a run made with `c` on files decoded with `choices` (`folderChoices`). An
  ## unset value (NaN) is the same as another unset one.
  FolderRunKey(settings: $c.ask & $c.weights & $c.reference, choices: choices)

func sameShot(a, b: FolderShot): bool =
  a.ffid == b.ffid and a.line == b.line and a.point == b.point

proc withShots*(rows: var seq[FolderRow]; st: AppState) =
  ## Each row's shot log match, from the loaded logs, in two passes over all of
  ## them: a match by the sweep's time first, and only when no log matches by time
  ## one by numbers (the first log that has one). Two logs that match by time with
  ## different rows give nothing, and the row says so. In memory only: no file is
  ## read. A row no log fits, or any row with no log loaded, has none: never a guess.
  for row in rows.mitems:
    row.shot = FolderShot()
    row.warnings.keepItIf(it != TwoShotLogs)
    var byNumbers = FolderShot()
    var clash = false
    for i in 0 ..< st.shotLogCount:
      let ix = st.shotIndexOf(st.shotLogId(i))
      if ix != nil:
        let hit = shotOf(row.query, ix[], st.shotView(i))
        if hit.found and hit.byTime:
          if not row.shot.found: row.shot = hit
          elif not sameShot(row.shot, hit): clash = true
        elif hit.found and not byNumbers.found: byNumbers = hit
    if clash:
      row.shot = FolderShot()
      row.warnings.add TwoShotLogs
    elif not row.shot.found:
      row.shot = byNumbers
