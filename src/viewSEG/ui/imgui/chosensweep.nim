## The project's chosen reference, as the windows that write correlated data see it: a stored
## sweep to load, a pilot rule, or the sentence saying why neither. Reads no file.

import std/[options, os]
import ../../core/[references, state]
import ../../view/outputwords

type ChosenSweep* = object
  name*, path*, why*: string
  pilot*: Option[PilotRule]
  samples*: int        ## a stored sweep: its length, as the archive's index holds it
  intervalUs*: float64 ## and its sample interval

proc chosenSweep*(st: AppState): ChosenSweep =
  ## The project's chosen reference as a sweep the batch can load, or as the pilot
  ## rule each file's records are read with, or why it cannot be used. Reads no file.
  result = ChosenSweep(why: CorrelatedNeedRef)
  if st.chosenReference.len == 0: return
  if not st.referencesLoaded:
    result.why = CorrelatedNeedArchive
    return
  let at = st.references.findId(st.chosenReference)
  if at < 0:
    result.why = referenceGone(st.chosenReference)
    return
  let e = st.references.entries[at]
  if e.missing or e.blocked:
    result.why = referenceGone(e.name)
  elif e.isPilot:
    result = ChosenSweep(name: e.name, pilot: some(e.pilotRuleOf))
  elif e.file.len == 0 or st.referencesHome.len == 0:
    result.why = referenceGone(e.name)
  else:
    result = ChosenSweep(name: e.name, path: st.referencesHome / e.file,
      samples: e.samples, intervalUs: e.intervalUs)
