## The name pattern editor's example shows the value of a `{vendor:NAME}` part read from the
## shown file, by a job: the name it renders is the one the output run renders (same
## `vendorValuesOf`, same `render`), for a known field, an unknown field, and a file with no
## vendor map; an answer asked for another key (the pattern changed meanwhile) is not used.
##
## The file is `fx.vendorTraceSegd(77)`: three traces whose vendor block (type 176) holds its
## own type, 176, at byte 32 of every trace.
##
## The window's decision each frame (`vendorPreviewStep`) is tested with a driver that
## submits as the window does: one submit per key and none while it runs, the answer used, a
## changed pattern dropping a stale answer, a key that differs by the edits revision (killing
## traces with killed traces dropped) or by the session (a file reloaded under the same path),
## a cancelled or failed one not asked again, and a job pruned from the history
## (`initJobs(historyLimit = 0)`) still answering.
##
## Seen to fail: with `vendorAnswer` not comparing the key, `stale_answer_dropped` found the
## old pattern's answer used. With the key lacking the revision, `key_revision` failed; lacking
## the session, `key_session` failed; with a cancelled job clearing `asked`,
## `cancel_not_retried` counted a second submit; with the answer read only for a done job, `pruned_job` failed;
## with a failed job clearing `asked`, `failed_not_retried` counted a second submit.

import std/[options, os]
import parseSEG
import viewSEG/core/[edits, jobs, namepreviewjobs, outputnames,
  outputnamevalues, sigtypes,
  vendormaps]
import utils/[fixtures, waiting]

proc patternOf(fields: openArray[string]): OutputPattern =
  result = OutputPattern(name: "V", separator: nsDot, parts: @[NamePart(kind: npStem)])
  for f in fields: result.parts.add NamePart(kind: npVendor, text: f)

proc runName(f: SeismicFile; path: string; p: OutputPattern;
    reg: VendorRegistry): NameResult =
  ## What the output run renders for `f` (as `renderedLeaf` does).
  let values = nameValuesOf(f, path, SignatureFacts(), FileEdits(), true, nil, {
      npStem}, reg)
  render(p, values, ".sgd", vendorValuesOf(f, SignatureFacts(), FileEdits(), true,
    vendorFieldsOf(p), reg))

proc jobName(jobs: Jobs; f: var SeismicFile; path: string; p: OutputPattern;
    reg: VendorRegistry): NameResult =
  ## What the example renders: the values come from the job.
  let fields = vendorFieldsOf(p)
  let key = vendorPreviewKey(path, 1, true, 0, fields, 1)
  let sink = VendorPreview()
  let id = jobs.submit(vendorPreviewSpec("f", path),
    vendorPreviewWork(addr f, SignatureFacts(), FileEdits(), true, fields, reg,
        key, sink))
  doAssert waitUntil(vendorAnswer(sink, key).isSome), "the job did not answer"
  doAssert id != NoJob
  let values = nameValuesOf(f, path, SignatureFacts(), FileEdits(), true, nil, {
      npStem}, reg)
  render(p, values, ".sgd", vendorAnswer(sink, key).get)

type Driver = object
  st: VendorPreviewState
  submits: int
  gate: ptr bool ## when set, the job waits until it is true

proc frame(d: var Driver; jobs: Jobs; f: ptr SeismicFile; path: string;
    key: string; reg: VendorRegistry; fields: seq[string];
        fail = false): VendorStep =
  ## One frame of the window: decide, and submit as the window does.
  result = d.st.vendorPreviewStep(jobs, key)
  if result == vsSubmit:
    inc d.submits
    let gate = d.gate
    let real = vendorPreviewWork(f, SignatureFacts(), FileEdits(), true, fields,
        reg, key,
      d.st.sink)
    let work = proc (ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}:
        if fail: raise newException(ValueError, "no")
        while gate != nil and not gate[]:
          ctx.checkCancelled()
          sleep(1)
      real(ctx)
    d.st.started jobs.submit(vendorPreviewSpec("f", path), work)

proc settle(d: var Driver; jobs: Jobs; f: ptr SeismicFile; path, key: string;
    reg: VendorRegistry; fields: seq[string]): VendorStep =
  ## Frames until the job is over (at most `Patience`), returns the last decision.
  var step = vsSample
  discard waitUntil((step = d.frame(jobs, f, path, key, reg, fields);
      step == vsUse))
  step

proc main*() =
  withFixtures fx:
    let path = fx.vendorTraceSegd(77)
    let dir = fx.dir / "previewmaps"
    createDir(dir)
    writeFile(dir / "own.nif", """(.nif27)
(vendormap "vendor-k" (version 1) (match (format segd) (rev 3.0 3.1) (manufacturer 77))
  (target (kind block) (type 0xB0) (where traceHeader) (name vendorStatus)
    (field kind (at 32) (enc u8))))
""")
    let load = loadVendorFolders([VendorFolder(dir: dir, origin: voProgram)])
    var mapped: VendorRegistry
    for m in load.registry.maps: mapped.addMap m
    let none = VendorRegistry()
    var f = openSeismic(path, keys = true)
    let jobs = initJobs()
    try:
      block known_field:
        let p = patternOf(["kind"])
        let want = runName(f, path, p, mapped)
        doAssert want.problem.len == 0 and want.name ==
            "vendor-trace-77.176.sgd", want.name
        let got = jobName(jobs, f, path, p, mapped)
        doAssert got == want, got.name & got.problem

      block unknown_field:
        let p = patternOf(["nosuch"])
        let want = runName(f, path, p, mapped)
        doAssert want.problem == "Vendor field nosuch is not in this file.", want.problem
        doAssert jobName(jobs, f, path, p, mapped) == want

      block no_vendor_map:
        let p = patternOf(["kind"])
        let want = runName(f, path, p, none)
        doAssert want.problem == "Vendor field kind is not in this file.", want.problem
        doAssert jobName(jobs, f, path, p, none) == want

      block stale_answer_dropped:
        let sink = VendorPreview()
        let old = vendorPreviewKey(path, 1, true, 0, ["kind"], 1)
        let id = jobs.submit(vendorPreviewSpec("f", path),
          vendorPreviewWork(addr f, SignatureFacts(), FileEdits(), true, @[
              "kind"], mapped,
          old, sink))
        doAssert waitUntil(vendorAnswer(sink, old).isSome)
        doAssert id != NoJob
        let changed = vendorPreviewKey(path, 1, true, 0, ["kind", "other"], 1)
        doAssert vendorAnswer(sink, changed).isNone, "an answer for the old pattern was used"
        doAssert vendorAnswer(sink, vendorPreviewKey(path, 1, true, 0, ["kind"],
            2)).isNone,
          "an answer for older vendor maps was used"
        doAssert vendorAnswer(nil, old).isNone

      block one_submit_then_use:
        var d = Driver()
        var open = false
        d.gate = addr open
        let key = vendorPreviewKey(path, 1, true, 0, ["kind"], 1)
        doAssert d.frame(jobs, addr f, path, key, mapped, @["kind"]) == vsSubmit
        doAssert d.frame(jobs, addr f, path, key, mapped, @["kind"]) == vsSample
        open = true
        doAssert d.settle(jobs, addr f, path, key, mapped, @["kind"]) == vsUse
        doAssert d.submits == 1, "asked more than once: " & $d.submits
        doAssert d.st.values.len == 1 and d.st.values[0].name == "kind"
        doAssert d.frame(jobs, addr f, path, key, mapped, @["kind"]) == vsUse
        doAssert d.submits == 1
        doAssert d.st.vendorPreviewStep(jobs, "") == vsSample

      block changed_pattern_drops_answer:
        var d = Driver()
        let k1 = vendorPreviewKey(path, 1, true, 0, ["kind"], 1)
        doAssert d.settle(jobs, addr f, path, k1, mapped, @["kind"]) == vsUse
        let k2 = vendorPreviewKey(path, 1, true, 0, ["kind", "nosuch"], 1)
        doAssert d.frame(jobs, addr f, path, k2, mapped, @["kind", "nosuch"]) ==
            vsSubmit,
          "the old answer was used for a changed pattern"
        doAssert d.settle(jobs, addr f, path, k2, mapped, @["kind",
            "nosuch"]) == vsUse
        doAssert d.submits == 2 and d.st.values.len == 2

      block key_revision:
        var e: FileEdits
        let r0 = vendorPreviewKey(path, 1, true, e.revision, ["kind"], 1)
        discard e.change(teKilled, [0, 1, 2], true)
        let r1 = vendorPreviewKey(path, 1, true, e.revision, ["kind"], 1)
        doAssert r0 != r1, "killing traces did not change the key"
        doAssert vendorPreviewKey(path, 1, false, 0, ["kind"], 1) ==
          vendorPreviewKey(path, 1, false, e.revision, ["kind"], 1),
          "the revision matters when killed traces are not dropped"
        var d = Driver()
        doAssert d.settle(jobs, addr f, path, r0, mapped, @["kind"]) == vsUse
        doAssert d.frame(jobs, addr f, path, r1, mapped, @["kind"]) == vsSubmit

      block key_session:
        var d = Driver()
        let a = vendorPreviewKey(path, 1, true, 0, ["kind"], 1)
        let b = vendorPreviewKey(path, 2, true, 0, ["kind"], 1)
        doAssert a != b
        doAssert d.settle(jobs, addr f, path, a, mapped, @["kind"]) == vsUse
        doAssert d.frame(jobs, addr f, path, b, mapped, @["kind"]) == vsSubmit,
          "a file reloaded under the same path kept the old values"

      block cancel_not_retried:
        var d = Driver()
        var open = false
        d.gate = addr open
        let key = vendorPreviewKey(path, 1, true, 0, ["kind"], 1)
        doAssert d.frame(jobs, addr f, path, key, mapped, @["kind"]) == vsSubmit
        doAssert d.frame(jobs, addr f, path, key, mapped, @["kind"]) == vsSample
        let id = d.st.job
        doAssert jobs.cancel(id)
        doAssert waitUntil(jobs.info(id).isSome and
          jobs.info(id).get.state == jsCancelled), "the job was not cancelled"
        for n in 0 ..< 20:
          doAssert d.frame(jobs, addr f, path, key, mapped, @["kind"]) == vsSample,
            "a cancelled job was asked again or its answer used"
          sleep(1)
        doAssert d.submits == 1, "a cancelled job was submitted again"
        let other = vendorPreviewKey(path, 2, true, 0, ["kind"], 1)
        doAssert d.frame(jobs, addr f, path, other, mapped, @["kind"]) == vsSubmit,
          "a reloaded file was not asked"
        open = true
        doAssert d.settle(jobs, addr f, path, other, mapped, @["kind"]) == vsUse
        doAssert d.submits == 2

      block key_changes_while_running:
        var d = Driver()
        var open = false
        d.gate = addr open
        let k1 = vendorPreviewKey(path, 1, true, 0, ["kind"], 1)
        let k2 = vendorPreviewKey(path, 1, true, 0, ["kind", "nosuch"], 1)
        doAssert d.frame(jobs, addr f, path, k1, mapped, @["kind"]) == vsSubmit
        for n in 0 ..< 5:
          doAssert d.frame(jobs, addr f, path, k2, mapped, @["kind", "nosuch"]) ==
              vsSample, "the key changed while the job ran: not waited for it"
        doAssert d.submits == 1, "submitted while the job ran"
        let first = d.st.job
        open = true
        doAssert waitUntil(jobs.info(first).isSome and
          jobs.info(first).get.state == jsDone), "the first job did not end"
        doAssert d.frame(jobs, addr f, path, k2, mapped, @["kind", "nosuch"]) ==
            vsSubmit, "the first key's answer was used, or k2 not asked"
        doAssert d.settle(jobs, addr f, path, k2, mapped, @["kind", "nosuch"]) == vsUse
        doAssert d.submits == 2, "asked more than once for the new key"
        doAssert d.st.values.len == 2 and d.st.shownKey == k2

      block failed_not_retried:
        var d = Driver()
        let key = vendorPreviewKey(path, 1, true, 0, ["kind"], 1)
        doAssert d.frame(jobs, addr f, path, key, mapped, @["kind"],
            fail = true) == vsSubmit
        let id = d.st.job
        doAssert waitUntil(jobs.info(id).isSome and
          jobs.info(id).get.state == jsFailed), "the job did not fail"
        for n in 0 ..< 20:
          doAssert d.frame(jobs, addr f, path, key, mapped, @["kind"]) == vsSample
          sleep(1)
        doAssert d.submits == 1, "a failed job was retried"

      block pruned_job:
        let none = initJobs(historyLimit = 0)
        var d = Driver()
        let key = vendorPreviewKey(path, 1, true, 0, ["kind"], 1)
        doAssert d.frame(none, addr f, path, key, mapped, @["kind"]) == vsSubmit
        doAssert waitUntil(d.st.sink.ready and none.info(d.st.job).isNone)
        doAssert d.frame(none, addr f, path, key, mapped, @["kind"]) == vsUse,
          "a pruned job's answer was not read"
        doAssert d.submits == 1
        # pruned with no answer: asked again
        var d2 = Driver()
        let big = vendorPreviewKey(path, 1, true, 0, ["x"], 1)
        doAssert d2.frame(none, addr f, path, big, mapped, @["kind"],
            fail = true) == vsSubmit
        doAssert waitUntil(none.info(d2.st.job).isNone)
        doAssert d2.frame(none, addr f, path, big, mapped, @["kind"]) == vsSubmit
        none.stop()
    finally:
      jobs.stop()
      f.close()
  echo "tnamepreviewjobs: ok"

when isMainModule:
  main()
