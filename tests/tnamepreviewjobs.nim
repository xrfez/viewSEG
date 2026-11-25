## The name pattern editor's example shows the value of a `{vendor:NAME}` part read from the
## shown file, by a job: the name it renders is the one the output run renders (same
## `vendorValuesOf`, same `render`), for a known field, an unknown field, and a file with no
## vendor map; an answer asked for another key (the pattern changed meanwhile) is not used.
##
## The file is `fx.vendorTraceSegd(77)`: three traces whose vendor block (type 176) holds its
## own type, 176, at byte 32 of every trace.
##
## Seen to fail: with `vendorAnswer` not comparing the key, `stale_answer_dropped` found the
## old pattern's answer used.

import std/[options, os]
import parseSEG
import viewSEG/core/[edits, jobs, namepreviewjobs, outputnames, outputnamevalues, sigtypes,
  vendormaps]
import utils/[fixtures, waiting]

proc patternOf(fields: openArray[string]): OutputPattern =
  result = OutputPattern(name: "V", separator: nsDot, parts: @[NamePart(kind: npStem)])
  for f in fields: result.parts.add NamePart(kind: npVendor, text: f)

proc runName(f: SeismicFile; path: string; p: OutputPattern; reg: VendorRegistry): NameResult =
  ## What the output run renders for `f` (as `renderedLeaf` does).
  let values = nameValuesOf(f, path, SignatureFacts(), FileEdits(), true, nil, {npStem}, reg)
  render(p, values, ".sgd", vendorValuesOf(f, SignatureFacts(), FileEdits(), true,
    vendorFieldsOf(p), reg))

proc jobName(jobs: Jobs; f: var SeismicFile; path: string; p: OutputPattern;
    reg: VendorRegistry): NameResult =
  ## What the example renders: the values come from the job.
  let fields = vendorFieldsOf(p)
  let key = vendorPreviewKey(path, true, fields, 1)
  let sink = VendorPreview()
  let id = jobs.submit(vendorPreviewSpec("f", path),
    vendorPreviewWork(addr f, SignatureFacts(), FileEdits(), true, fields, reg, key, sink))
  doAssert waitUntil(vendorAnswer(sink, key).isSome), "the job did not answer"
  doAssert id != NoJob
  let values = nameValuesOf(f, path, SignatureFacts(), FileEdits(), true, nil, {npStem}, reg)
  render(p, values, ".sgd", vendorAnswer(sink, key).get)

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
        doAssert want.problem.len == 0 and want.name == "vendor-trace-77.176.sgd", want.name
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
        let old = vendorPreviewKey(path, true, ["kind"], 1)
        let id = jobs.submit(vendorPreviewSpec("f", path),
          vendorPreviewWork(addr f, SignatureFacts(), FileEdits(), true, @["kind"], mapped,
          old, sink))
        doAssert waitUntil(vendorAnswer(sink, old).isSome)
        doAssert id != NoJob
        let changed = vendorPreviewKey(path, true, ["kind", "other"], 1)
        doAssert vendorAnswer(sink, changed).isNone, "an answer for the old pattern was used"
        doAssert vendorAnswer(sink, vendorPreviewKey(path, true, ["kind"], 2)).isNone,
          "an answer for older vendor maps was used"
        doAssert vendorAnswer(nil, old).isNone
    finally:
      jobs.stop()
      f.close()
  echo "tnamepreviewjobs: ok"

when isMainModule:
  main()
