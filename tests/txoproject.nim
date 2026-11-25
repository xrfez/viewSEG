## A project's survey holds X records (source domain) and O records (receiver domain)
## at the same time, and says so: a survey of S, R, X and an `.ops` file of O records
## imported in one import is kept whole, counted apart (`StoreInfo.relations` for X,
## `receiverRelations` for O), reloaded with both domains and the same (source station,
## receiver station) pairs; an O file added by a second import leaves the X records
## alone; and a reload takes the domain of a file's X records from what the store kept,
## not from the name of the copy.
##
## Seen to fail: with `writeStore` counting every record as X, `receiverRelations` was 0
## ("both domains are counted apart"); with `receiverRelations` not written to the document,
## the reopened project said 0 O records; with the reload using `relationDomainOf(f.copy)`
## instead of `f.domain`, a store whose first X file was kept as receiver-domain came back
## with its X records in the source domain ("the stored domain is used"); with the second
## import dropping the X files from what it kept, the X count was 0.
##
## Headless.

import std/[os, sequtils, strutils, algorithm]
import parseSEG
import viewSEG/core/[jobs, join, project, projectnif, state, surveystore]
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc surveyLayers(st: AppState): int =
  for l in st.survey.layers:
    if l.origin == loSurveyFile: inc result

proc pairs(g: SurveyGeometry; d: RelationDomain): seq[string] =
  ## Every (source station, receiver station) the domain's relations give, sorted.
  for rec in g.records(d):
    for (_, r) in g.relations(rec, d):
      result.add $r.source.line & ":" & $r.source.point & ":" & $r.source.index & " > " &
        $r.receiver.line & ":" & $r.receiver.point & ":" & $r.receiver.index
  result.sort

proc onSurveyLoaded(st: var AppState; why: string) =
  doAssert st.settle(st.inProject and st.project.survey == srLoaded and
    st.surveyLayers == st.project.doc.survey.len), why & ": " & $st.project.survey & " " &
    st.project.surveyNote & " " & $st.surveyLayers

proc counts(st: AppState): tuple[x, o: int; xPairs, oPairs: seq[string]] =
  ## What the survey files' layers hold, domain by domain.
  for l in st.survey.layers:
    if l.origin == loSurveyFile and not l.relations.isNil:
      result.x += l.relations[].relationCount(rdSource)
      result.o += l.relations[].relationCount(rdReceiver)
      result.xPairs.add l.relations[].pairs(rdSource)
      result.oPairs.add l.relations[].pairs(rdReceiver)
  result.xPairs.sort
  result.oPairs.sort

proc runJob(work: JobWork) =
  let jobs = initJobs()
  let id = jobs.submit(JobSpec(title: "t", lane: jlBackground), work)
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
  doAssert jobs.info(id).get.state == jsDone, $jobs.info(id)

proc main*() =
  withFixtures fx:
    let field = fx.dir / "field"
    createDir(field)
    let record = field / "stations-only.sgd"
    moveFile(fx.stationsSegd(), record)
    let survey = fx.surveySps()
    # the O records of the survey, as the library derives them, in an .ops file
    var reference = initSurveyGeometry()
    reference.addSps(survey.s)
    reference.addSps(survey.r)
    reference.addSps(survey.x)
    let ops = fx.dir / "survey.ops"
    block:
      var o = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
        data: "SPS 2.1;")], relations: reference.receiverRelations())
      doAssert writeSps(o, ops).len == 0
    var both = reference
    both.addSps(ops)
    let wantX = both.relationCount(rdSource)
    let wantO = both.relationCount(rdReceiver)
    doAssert wantX > 0 and wantO > 0 and wantX != wantO, $(wantX, wantO)
    let js = surveyOf(both, [survey.s, survey.r, survey.x, ops])
    doAssert js.xRelations == wantX and js.oRelations == wantO and
      js.relations == wantX + wantO, "the join's survey counts them apart: " & $js.relations
    let xPairs = both.pairs(rdSource)
    let oPairs = both.pairs(rdReceiver)
    doAssert xPairs.len > 0 and oPairs.len > 0
    let config = fx.dir / "config"
    let job = fx.dir / "Both"

    block oneImport:
      var st = start(config)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: record)
      doAssert st.settle(st.sessions.len >= 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      let before = st.joinReport.serial
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
        JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
        JoinFile(path: survey.x, kind: jkSps), JoinFile(path: ops, kind: jkSps)])
      doAssert st.settle(st.joinReport.serial > before and not st.importing)
      st.onSurveyLoaded "the survey was not kept"
      doAssert st.settle(st.project.doc.hasStore)
      let info = st.project.doc.store
      doAssert info.relations == wantX and info.receiverRelations == wantO,
        "both domains are counted apart: " & $info
      let c = st.counts
      doAssert (c.x, c.o) == (wantX, wantO), "both domains are on the map: " & $(c.x, c.o)
      doAssert c.xPairs == xPairs and c.oPairs == oPairs
      st.flushFiles()
      st.shutdown()
    doAssert "(receiverRelations " & $wantO & ")" in readFile(job / "project.nif")

    block reopened:
      var st = start(config)
      st.apply Command(kind: ckOpenProject, projectPath: job / "project.nif")
      st.onSurveyLoaded "the project's survey did not come back"
      let info = st.project.doc.store
      doAssert info.relations == wantX and info.receiverRelations == wantO, $info
      let c = st.counts
      doAssert (c.x, c.o) == (wantX, wantO), "both domains are back: " & $(c.x, c.o)
      doAssert c.xPairs == xPairs and c.oPairs == oPairs, "the station pairs are the same"
      var said: seq[string] = @[]
      for l in st.survey.layers:
        if l.origin == loSurveyFile: said.add l.summary
      doAssert said.anyIt(" X records for " in it) and said.anyIt(" O records for " in it) and
        said.allIt("relation record" notin it), $said
      st.shutdown()

    block oldDocument:
      # a document of an earlier version has only `(relations n)`: that is the X count
      let nif = readFile(job / "project.nif")
      let old = nif.replace(" (receiverRelations " & $wantO & ")", "")
      doAssert old != nif
      var problems: seq[string] = @[]
      let doc = readProject(old, "project.nif", problems)
      doAssert doc.store.relations == wantX and doc.store.receiverRelations == 0, $doc.store

    block storedDomain:
      # the store keeps the domain of each file's X records; one kept as receiver-domain is
      # reloaded so, whatever the copy is called
      let path = job / "survey" / "survey.bin"
      proc domains(): seq[RelationDomain] =
        var got: seq[RelationDomain]
        let gp = addr got
        proc onFile(f: StoredFile) = gp[].add f.domain
        runJob(proc (ctx: JobContext) {.gcsafe.} =
          {.cast(gcsafe).}: readStore(path, ctx, StoreReader(onFile: onFile)))
        got
      doAssert domains() == @[rdSource, rdSource, rdSource, rdReceiver], $domains()
      # the domain byte of `survey.x`: after its two strings and the three kind bytes
      var bytes = readFile(path)
      var at = 16 + 4
      var patched = false
      while at + 13 <= bytes.len:
        let kind = ord(bytes[at])
        var size = 0'i64
        copyMem(addr size, addr bytes[at + 5], 8)
        if kind == 1:
          var n, m = 0'u32
          copyMem(addr n, addr bytes[at + 13], 4)
          copyMem(addr m, addr bytes[at + 13 + 4 + int(n)], 4)
          if bytes[at + 13 + 4 ..< at + 13 + 4 + int(n)].endsWith("survey.x"):
            bytes[at + 13 + 4 + int(n) + 4 + int(m) + 3] = char(ord(rdReceiver))
            patched = true
        at += 13 + int(size)
        if kind == 255: break
      doAssert patched
      writeFile(path, bytes)
      runJob(proc (ctx: JobContext) {.gcsafe.} =
        {.cast(gcsafe).}:
          let h = storeHash(path, ctx)
          var tail = newString(8)
          copyMem(addr tail[0], unsafeAddr h, 8)
          bytes.setLen(bytes.len - 8)
          writeFile(path, bytes & tail))
      doAssert domains() == @[rdSource, rdSource, rdReceiver, rdReceiver], $domains()
      var st = start(config)
      st.apply Command(kind: ckOpenProject, projectPath: job / "project.nif")
      st.onSurveyLoaded "the project's survey did not come back"
      let c = st.counts
      doAssert c.x == 0 and c.o == wantX + wantO, "the stored domain is used: " & $(c.x, c.o)
      st.shutdown()

    block secondImport:
      let dir = fx.dir / "Second"
      var st = start(config)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: record)
      doAssert st.settle(st.sessions.len >= 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckNewProject, projectPath: dir, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      var before = st.joinReport.serial
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
        JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
        JoinFile(path: survey.x, kind: jkSps)])
      doAssert st.settle(st.joinReport.serial > before and not st.importing)
      st.onSurveyLoaded "the first import did not come"
      doAssert st.settle(st.project.doc.hasStore)
      doAssert st.project.doc.store.relations == wantX and
        st.project.doc.store.receiverRelations == 0, $st.project.doc.store
      before = st.joinReport.serial
      # (the Import survey window lists the files already imported: the import is the whole list)
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
        JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
        JoinFile(path: survey.x, kind: jkSps), JoinFile(path: ops, kind: jkSps)])
      doAssert st.settle(st.joinReport.serial > before and not st.importing)
      doAssert st.settle(st.project.survey == srLoaded and
        st.project.doc.store.receiverRelations == wantO), "the O file was not added: " &
        $st.project.doc.store
      doAssert st.project.doc.store.relations == wantX, "the X records are kept: " &
        $st.project.doc.store
      let c = st.counts
      doAssert c.xPairs == xPairs and c.oPairs == oPairs
      st.flushFiles()
      st.shutdown()
  echo "txoproject: ok"

when isMainModule: main()
