## The vibrator QC configuration a folder run is made with, read from the
## project: the profile the Vibrator signature window keeps as the user sets
## it, the project's chosen reference, the force scale in force and the job's
## weights. A run asks for nothing else; when the project has no profile the
## run is not configured.

import std/os
import analysis, project, settings, state, vibfolderqc, vibprofile

const
  NotConfigured* = "Vibrator signature QC is not configured."
  WhereToConfigure* = "Set it in a Vibrator signature window: Analysis > New plot > " &
    "Vibrator, on a signature file."

type
  VibQcConfig* = object
    ## What a run uses. Copied out of `AppState`, so a job never reads the state.
    configured*: bool
    profile*: VibQcProfile      ## as stored, with the chosen reference and force scale in force
    ask*: VibQcAsk
    weights*: VibJobWeights
    reference*: FolderReference ## the archive reference; no path: the recorded pilot
    referenceName*: string      ## the name of the reference measured against; "": the recorded one

func archiveIds(st: AppState): seq[string] =
  result = @[]
  if not st.referencesLoaded: return
  for e in st.references.entries:
    if e.id.len > 0: result.add e.id

func referenceFor(st: AppState; id: string): tuple[reference: FolderReference; name: string] =
  ## The archive entry `id` names: its name, and, when it is a file of the archive (not a
  ## trace of each record), where it is. Nothing when `id` is none or not in the archive.
  if id.len == 0 or not st.referencesLoaded: return
  for e in st.references.entries:
    if e.id == id:
      result.name = e.name
      if not (e.isPilot or e.file.len == 0 or st.referencesHome.len == 0):
        result.reference = FolderReference(path: st.referencesHome / e.file, name: e.name,
          startMs: e.timeStart)
      return

func vibQcConfig*(st: AppState): VibQcConfig =
  ## The configuration in force. The project's chosen reference is used; the
  ## profile's stored one only when none is chosen. The force scale is the
  ## one set now. Not configured without an open project that holds a profile.
  if not (st.inProject and st.project.doc.hasVibProfile): return
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
  let found = referenceFor(st, result.profile.referenceId)
  result.reference = found.reference
  result.referenceName = found.name

proc withShots*(rows: var seq[FolderRow]; st: AppState) =
  ## Each row's shot log match, from the loaded logs (the first that has a row
  ## for the sweep). In memory only: no file is read. A row no log fits, or any
  ## row with no log loaded, has none: never a guess.
  for row in rows.mitems:
    row.shot = FolderShot()
    for i in 0 ..< st.shotLogCount:
      let ix = st.shotIndexOf(st.shotLogId(i))
      if ix != nil:
        let hit = shotOf(row.query, ix[], st.shotView(i))
        if hit.found:
          row.shot = hit
          break
