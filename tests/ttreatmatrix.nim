## What is remembered about a file, run through every state a document of the store may be in
## when the file is next met, and every way it is met, to the state the next run finds.
##
## The document of the file's quick identity (one at most here):
##   kind:  none | treat (only what the file is treated as: continuous) | edits (trace 1 killed) |
##          both
##   time:  the modification time it saw is the file's | another (the file touched or copied)
##   hash:  the hash of every byte not known | known, the file's | known, another content's
##          (whose document names another path)
## What this run does: list the folder | list it, then open the file | open the file | open,
## kill trace 0 | open, kill trace 0 and quit before the hash of every byte | list, set the file
## to time sliced.
## The next run opens the file and waits for what is remembered; then:
##   - the document is the file's ("own") when its hash is the file's, or when it has none and
##     either saw the file at this time or holds no edits (a document of only a choice is the
##     file's once the hash says no other is); a document of edits without a hash that saw
##     another time is never taken (as before there were choices: its edits are absent);
##   - the choice shown: time sliced after a choice; continuous when the document is own and has
##     it; else none (automatic);
##   - its edits (trace 1): applied when it is own and has them;
##   - trace 0 killed: applied after an edit; after a quit before the hash, offered (kept apart,
##     to apply or forget) when the edits were being checked (a document taken at once that
##     holds edits, or knows a hash: what it brings back waits for that hash), else applied;
##   - at most one confirmed document of the file's content; another content's document stands
##     as it was written; an unconfirmed one only for edits offered.
## In the list of the first run, a choice shows when the document saw the file at its time (a
## document that may be another content's is shown until the file is identified: the hash of
## the list's files is not taken). Listed, then opened in the same run, the file shows once it is
## identified what the next run shows of it (a choice the list showed of another content's
## document goes).
## Cells found otherwise and kept as they were before choices existed: a document of edits
## whose hash is the file's, that saw another time, with an edit and a quit before the hash: the
## next run takes the document of the quit's edit (its time is the file's) and the other stays:
## two documents of one content ("twoOfOne"); the choice of the one that stays goes to the one
## taken.
##
## Seen to fail, 14 of 95 cells, with the other documents of an open's time not waiting for the
## hash, a document of only a choice that knows a hash written into before it, a document of
## only a choice that waits for the hash not taking the edits, a document of edits without a
## hash and of another time taken for a choice, and a second document of only a choice of this
## content left beside the one taken. With the hash that finds no document of the file's own
## leaving the choice the list showed, 2 cells of a list and an open (another content's
## document at the file's time).

import std/[importutils, options, os, sequtils, strutils, tables, times]
import parseSEG
import viewSEG/core/state {.all.}
import viewSEG/core/[edits, filelist, filememory, identity, jobs, recordingkind, treatas]
import utils/[fixtures, kindfiles, waiting]

privateAccess(AppState)
privateAccess(Remembered)

type
  DocKind = enum dkNone = "none", dkTreat = "treat", dkEdits = "edits", dkBoth = "both"
  DocTime = enum tmSame = "time same", tmOther = "time other"
  DocHash = enum hhUnknown = "hash unknown", hhSame = "hash same", hhOther = "hash other"
  Action = enum
    acList = "list", acListOpen = "list+open", acOpen = "open", acEdit = "open+edit"
    acQuit = "open+edit+quit"
    acForce = "force"
  Ours = enum oAbsent = "absent", oApplied = "applied", oOffered = "offered"

  Expected = object
    listed: bool ## the choice shows in the first run's list (`acList`, or before the open)
    inRun: Option[RecordingKind]
      ## `acListOpen`: the choice once the file is identified
    shown: Option[RecordingKind]
    stored: bool ## the document's edits (trace 1) are applied
    ours: Ours   ## trace 0
    twoOfOne: bool

func expected(k: DocKind; t: DocTime; h: DocHash; a: Action): Expected =
  let own = k != dkNone and (h == hhSame or (h == hhUnknown and (t == tmSame or k == dkTreat)))
  let checking = k != dkNone and t == tmSame and (k in {dkEdits, dkBoth} or h != hhUnknown)
  result.listed = k in {dkTreat, dkBoth} and t == tmSame
  result.shown =
    if a == acForce: some rkReceiverSliced
    elif own and k in {dkTreat, dkBoth}: some rkReceiverContinuous
    else: none(RecordingKind)
  result.twoOfOne = a == acQuit and k in {dkEdits, dkBoth} and h == hhSame and t == tmOther
  result.stored = own and k in {dkEdits, dkBoth} and not result.twoOfOne
  if a == acListOpen: result.inRun = result.shown
  result.ours =
    case a
    of acEdit: oApplied
    of acQuit: (if checking: oOffered else: oApplied)
    else: oAbsent

template settled(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc appIn(dir: string): AppState =
  result = initAppState()
  result.rememberFilesIn(dir)

proc docs(dir: string): seq[FileRecord] =
  let store = dir / StoreFolder
  if dirExists(store):
    for kind, p in walkDir(store):
      if p.endsWith(MemorySuffix):
        var problems: seq[string]
        result.add readMemoryFile(p, problems)

proc idle(st: var AppState): bool =
  st.flushFiles()
  st.memoryWork.len == 0 and st.treatJobs.len == 0 and
    st.remembered.allIt(it.job == NoJob and it.hashJob == NoJob)

proc listed(st: AppState): bool =
  not st.fileList.scanning and st.fileList.entries.len == 1 and
    st.fileList.entries[0].kindState != ksUnread and st.kindJob == NoJob

proc open(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settled(st.sessions.len == 1 and st.remembered.len == 1 and
    st.remembered[0].known), "not opened: " & path

proc kill(st: var AppState; trace: int) =
  st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
    edited: @[st.sessions[^1].base + trace], on: true, origin: coWindow)

proc main*() =
  withFixtures fx:
    var cells, wrong: seq[string]
    for k in DocKind:
      for t in DocTime:
        for h in DocHash:
          if k == dkNone and (t != tmSame or h != hhUnknown): continue # (one cell of no document)
          for a in Action:
            let name = $k & ", " & $t & ", " & $h & ", " & $a
            let at = fx.dir / ("cell" & $cells.len)
            cells.add name
            let cfg = at / "config"
            let f = canonical(writeSpecs(at / "data", "f", [spec(0, 0), spec(0, 1000),
              spec(0, 2000)]))
            var modified: Time
            let id = quickIdentity(f, modified)
            let real = fullHash(f)
            var problems: seq[string]
            if k != dkNone:
              var d = FileRecord(identity: id, name: "f.sgd",
                path: if h == hhOther: "/elsewhere/f.sgd" else: f,
                opened: getTime() - initDuration(days = 1),
                modified: if t == tmSame: modified else: modified - initDuration(hours = 2))
              if h != hhUnknown:
                d.identity.full = if h == hhSame: real else: real xor 1
                d.identity.fullKnown = true
              if k in {dkTreat, dkBoth}: d.treat = TreatAs(kind: some rkReceiverContinuous)
              if k in {dkEdits, dkBoth}: d.edits.lists[teKilled] = @[1]
              let store = Store(home: cfg / StoreFolder)
              createDir(store.home)
              writeFile(store.docPath(freeDocName(id, @[])), memoryDocument(d))
            let want = expected(k, t, h, a)
            var got = Expected()
            # this run
            var one = appIn(cfg)
            case a
            of acList, acForce:
              one.apply Command(kind: ckBrowse, paths: @[at / "data"])
              doAssert one.settled(one.listed), name & ": not listed"
              got.listed = one.fileList.entries[0].treat.isSet
              # a listing does not hash: a choice of a document that knows a hash is shown,
              # but no job uses it until the file's hash confirms the document
              if a == acList and one.treatOf(f).isSet and
                  one.treatInForce(f).isSet != (h == hhUnknown):
                wrong.add name & ": the listed choice is in force for jobs: " &
                  $one.treatInForce(f).isSet
              if a == acForce:
                one.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "sliced")
                doAssert one.settled(one.idle), name & ": the choice's look-up did not end"
            of acListOpen:
              one.apply Command(kind: ckBrowse, paths: @[at / "data"])
              doAssert one.settled(one.listed), name & ": not listed"
              got.listed = one.fileList.entries[0].treat.isSet
              one.open(f)
              doAssert one.settled(one.idle), name & ": what is remembered was not read"
              got.inRun = one.treatOf(f).kind
              if one.fileList.entries[0].treat.kind != got.inRun:
                got.inRun = some rkShotGather # (the row and the file disagree: never wanted)
            of acOpen, acEdit:
              one.open(f)
              doAssert one.settled(one.idle), name & ": what is remembered was not read"
              if a == acEdit:
                one.kill(0)
                doAssert one.settled(one.idle), name & ": not written"
            of acQuit:
              one.open(f) # its identity known; the hash, if any, never taken in
              if one.remembered[0].hashJob != NoJob:
                discard one.jobs.cancel(one.remembered[0].hashJob)
              one.kill(0)
            one.shutdown()
            # the next run
            var two = appIn(cfg)
            two.open(f)
            doAssert two.settled(two.idle), name & ": the next run did not settle"
            got.shown = two.treatOf(f).kind
            let kept = two.editsAt(f).kept.lists[teKilled]
            got.stored = 1 in kept
            got.ours = if 0 in kept: oApplied
              elif two.earlierOf(f).anyIt(0 in it.edits.lists[teKilled]): oOffered
              else: oAbsent
            two.shutdown()
            let onDisk = docs(cfg)
            let mine = onDisk.filterIt(not it.unconfirmed and it.identity.fullKnown and
              it.identity.full == real)
            got.twoOfOne = mine.len > 1
            if a notin {acList, acListOpen}: got.listed = want.listed # (looked at in the list only)
            if a != acListOpen: got.inRun = want.inRun
            var said: seq[string] = @[]
            if got != want: said.add "got " & $got & ", wanted " & $want
            if h == hhOther: # another content's document stands as it was written
              let theirs = onDisk.filterIt(it.identity.fullKnown and it.identity.full != real)
              if theirs.len != 1 or theirs[0].path != "/elsewhere/f.sgd" or
                  theirs[0].edits.lists[teKilled] != (if k in {dkEdits, dkBoth}: @[1] else: @[]) or
                  theirs[0].treat.kind.isSome != (k in {dkTreat, dkBoth}):
                said.add "another content's document changed: " & $theirs.len
            if want.ours != oOffered and onDisk.anyIt(it.unconfirmed):
              said.add "an unconfirmed document is left"
            discard problems
            if said.len > 0: wrong.add name & ": " & said.join("; ")
    block carriedOnce:
      # two documents of one content, the one that stays holding a force: the force goes to the
      # document taken once, and a later automatic stays (nothing comes back, nothing is written)
      let at = fx.dir / "carried"
      let cfg = at / "config"
      let f = canonical(writeSpecs(at / "data", "f", [spec(0, 0), spec(0, 1000), spec(0, 2000)]))
      var modified: Time
      var id = quickIdentity(f, modified)
      id.full = fullHash(f)
      id.fullKnown = true
      let store = Store(home: cfg / StoreFolder)
      createDir(store.home)
      var taken: seq[string] = @[]
      for later in [true, false]:
        var d = FileRecord(identity: id, name: "f.sgd", path: f,
          opened: getTime() - initDuration(days = 1),
          modified: if later: modified else: modified - initDuration(hours = 2))
        if later: d.edits.lists[teKilled] = @[0]
        else:
          d.edits.lists[teKilled] = @[1]
          d.treat = TreatAs(kind: some rkReceiverContinuous)
        taken.add freeDocName(id, taken)
        writeFile(store.docPath(taken[^1]), memoryDocument(d))
      proc run(auto: bool): RecordingKind =
        var st = appIn(cfg)
        st.open(f)
        doAssert st.settled(st.idle), "carriedOnce: not settled"
        result = st.treatOf(f).kind.get(rkShotGather)
        if auto:
          st.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "automatic")
          doAssert st.settled(st.idle), "carriedOnce: automatic not written"
          doAssert not st.treatOf(f).isSet
        st.shutdown()
      doAssert run(true) == rkReceiverContinuous, "carriedOnce: the force did not go to the taken"
      var before: seq[string] = @[]
      for _, p in walkDir(store.home):
        if p.endsWith(MemorySuffix): before.add readFile(p)
      doAssert run(false) == rkShotGather, "carriedOnce: the cleared force came back"
      var after: seq[string] = @[]
      for _, p in walkDir(store.home):
        if p.endsWith(MemorySuffix): after.add readFile(p)
      doAssert before == after, "carriedOnce: an open with nothing to carry wrote"
      doAssert docs(cfg).allIt(not it.treat.isSet), "carriedOnce: a force stayed"
    doAssert wrong.len == 0, $wrong.len & " of " & $cells.len & " cells:\n" & wrong.join("\n")
    echo "ttreatmatrix: ", cells.len, " cells"

when isMainModule:
  main()
