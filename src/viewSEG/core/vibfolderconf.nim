## The vibrator QC configuration a folder run is made with, read from the
## project: the profile the Vibrator signature window keeps as the user sets
## it, the project's chosen reference, the force scale in force and the job's
## weights. A run asks for nothing else; when the project has no profile the
## run is not configured.

import std/[os, sequtils]
import analysis, project, settings, state, vibfolderqc, vibprofile

const
  NotConfigured* = "Vibrator signature QC is not configured."
  WhereToConfigure* = "Set it in a Vibrator signature window: Analysis > New plot > " &
    "Vibrator, on a signature file."

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
          startMs: e.timeStart)
      return

func vibQcConfig*(st: AppState): VibQcConfig =
  ## The configuration in force. The project's chosen reference is used; the
  ## profile's stored one only when none is chosen. The force scale is the
  ## one set now. Not configured without an open project that holds a profile.
  if not (st.inProject and st.project.doc.hasVibProfile):
    if st.inProject and st.project.readOnly: result.unsetWhy = ReadOnlyProject
    return
  result.configured = true
  result.profile = st.project.doc.vibProfile
  let chosen = st.chosenReference
  if chosen.len > 0 and chosen != result.profile.referenceId:
    # the top typed was typed for the reference the profile was stored with
    result.profile.referenceId = chosen
    result.profile.topHz = topsOf(st.project.doc.vibTops).topOf(chosen)
  result.profile.forceScale = st.settings.forceScale
  result.ask = applied(result.profile, archiveIds(st))
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
