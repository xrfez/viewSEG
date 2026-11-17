## A chosen archive reference for tests that need a correlation to draw.
## The correlation window uses only that choice; these helpers store one
## trace and select it.

import std/os
import viewSEG/core/[persist, state]
import waiting

proc readyArchive*(st: var AppState; dir: string) =
  ## The reference archive in `dir`, read. A folder that is not there is made.
  createDir(dir)
  st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
  st.rememberFilesIn(dir)

proc chooseStored*(st: var AppState; dir: string; trace: int; name = "ref"): string =
  ## Stores open trace `trace` (a survey-wide id) as `name` and selects it.
  ## The archive is started in `dir` when none is.
  if st.referencesHome.len == 0: st.readyArchive(dir)
  doAssert waitUntil((discard st.drainInbox(); st.referencesLoaded)),
    "the archive was not read"
  let before = st.references.entries.len
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: name,
    trace: trace, fromMs: 0, toMs: -1))
  doAssert waitUntil((discard st.drainInbox(); st.references.entries.len > before)),
    "the reference was not stored"
  result = ""
  for e in st.references.entries:
    if e.name == name: result = e.id
  doAssert result.len > 0, "stored \"" & name & "\" was not listed"
  st.apply Command(kind: ckSelectReference, refId: result)
