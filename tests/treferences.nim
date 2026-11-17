## The reference archive (`core/references`): a folder of one-trace SEG-Y
## files and an index, for the program's own archive and for a project's.
##
## Store, list, rename, delete, a name already used, a damaged index, a
## missing SEG-Y file, an atomic write, a copy from one archive into
## another, and a sweep generated against processSEG called by hand.
##
## Seen to fail: with the stored window taken as samples past `toMs` as well
## (`cutSamples` keeping `i1` exclusive of the sample at `toMs` dropped),
## "the window keeps the sample at 4 ms"; with a damaged index read as
## empty and silent, "a damaged index is said".

import std/[math, os, strutils]
import parseSEG
import processSEG/vibroseis/[sweep, taper]
import viewSEG/core/references

proc tempDir(): string =
  result = getTempDir() / "viewSEG-treferences-" & $getCurrentProcessId()
  createDir(result)

proc removeTemp(dir: string) =
  if dirExists(dir): removeDir(dir)

proc main*() =

  block cut_keeps_both_ends:
    let x = @[1'f32, 2, 3, 4, 5]
    let cut = cutSamples(x, 2000, 2, 6) # 2 ms samples: times 0, 2, 4, 6, 8
    doAssert cut == @[2'f32, 3, 4], "the window keeps the sample at 4 ms, got " & $cut
    doAssert cutSamples(x, 2000, 0, -1) == x

  block store_list_rename_delete:
    let dir = tempDir()
    let folder = referencesFolder(dir)
    var origin = ReferenceOrigin(generated: false, fileName: "shot.sgy", record: 12,
      trace: 3, fromMs: 0, toMs: 4)
    let samples = @[0.5'f32, -0.25, 0.125]
    let id = storeSamples(folder, "pilot A", 2000, samples, origin)
    let index = loadIndex(folder)
    doAssert index.entries.len == 1, $index.problems
    doAssert index.entries[0].id == id
    doAssert index.entries[0].name == "pilot A"
    doAssert index.entries[0].samples == 3
    doAssert index.entries[0].intervalUs == 2000
    doAssert not index.entries[0].missing
    doAssert index.entries[0].origin.fileName == "shot.sgy"
    doAssert index.entries[0].origin.trace == 3
    let back = readReferenceFile(folder / index.entries[0].file)
    doAssert back.samples == samples, "the SEG-Y is not the samples stored"
    doAssert abs(back.intervalUs - 2000) < 1e-3, $back.intervalUs
    var f = openSeismic(folder / index.entries[0].file, keys = true)
    let text = f.textHeader
    f.close()
    doAssert "pilot A" in text, "the name is not in the textual header: " & text
    doAssertRaises ValueError: discard storeSamples(folder, "pilot A", 2000, samples, origin)
    renameIn(folder, id, "pilot B")
    doAssert loadIndex(folder).entries[0].name == "pilot B"
    doAssertRaises ValueError: renameIn(folder, id, "")
    # a second name, then the first cannot take it
    let id2 = storeSamples(folder, "other", 2000, samples, origin)
    doAssertRaises ValueError: renameIn(folder, id, "other")
    let gone = deleteIn(folder, id)
    doAssert gone == "pilot B"
    let left = loadIndex(folder)
    doAssert left.entries.len == 1 and left.entries[0].id == id2
    doAssert not fileExists(folder / (id & ".sgy")), "the SEG-Y was not removed"
    removeTemp(dir)

  block damaged_index_and_missing_file:
    let dir = tempDir()
    let folder = referencesFolder(dir)
    createDir(folder)
    writeFile(indexPath(folder), "this is not nif")
    let bad = loadIndex(folder)
    doAssert bad.damaged, "a damaged index is said"
    doAssert bad.entries.len == 0
    doAssert bad.problems.len > 0, "a damaged index is said"
    doAssert readFile(indexPath(folder)) == "this is not nif", "a damaged index was overwritten"
    # a document with one usable entry and one without a name
    writeFile(indexPath(folder), """(.nif27)
(.vendor "viewSEG")
(references
  (version 1)
  (entry (id "r1") (name "kept") (intervalUs 2000.0) (samples 1) (date "2026-01-01T00:00:00Z") (file "r1.sgy")
    (source (generated false) (fileName "a.sgy") (trace 1) (fromMs 0.0) (toMs 2.0)))
  (entry (id "r2") (samples 1)))
""")
    let partial = loadIndex(folder)
    doAssert not partial.damaged
    doAssert partial.entries.len == 1 and partial.entries[0].name == "kept"
    doAssert partial.entries[0].missing, "a missing SEG-Y is marked"
    doAssert partial.problems.len > 0, "an entry with no name is said"
    removeTemp(dir)

  block atomic_write:
    let dir = tempDir()
    let folder = referencesFolder(dir)
    var index = ReferenceIndex(version: 1)
    index.entries.add ReferenceEntry(id: "r1", name: "one", intervalUs: 2000, samples: 1,
      date: "2026-01-01T00:00:00Z", file: "r1.sgy",
      origin: ReferenceOrigin(generated: false, fileName: "a.sgy", trace: 1, fromMs: 0, toMs: 2))
    writeIndex(folder, index)
    doAssert fileExists(indexPath(folder))
    for kind, p in walkDir(folder):
      doAssert not p.endsWith(".tmp"), "a temporary file was left: " & p
    let back = loadIndex(folder)
    doAssert back.entries.len == 1 and back.entries[0].name == "one"
    # a second write replaces the file whole
    index.entries[0].name = "two"
    writeIndex(folder, index)
    doAssert loadIndex(folder).entries[0].name == "two"
    removeTemp(dir)

  block copy_between_archives:
    let dir = tempDir()
    let main = referencesFolder(dir / "main")
    let proj = referencesFolder(dir / "project")
    let origin = ReferenceOrigin(generated: false, fileName: "a.sgy", record: 1, trace: 1,
      fromMs: 0, toMs: 2)
    let id = storeSamples(main, "shared", 4000, @[1'f32, 2, 3], origin)
    let copied = copyInto(main, proj, id)
    doAssert copied.len > 0
    let there = loadIndex(proj)
    doAssert there.entries.len == 1 and there.entries[0].name == "shared"
    doAssert there.entries[0].id == copied
    doAssert readReferenceFile(proj / there.entries[0].file).samples == @[1'f32, 2, 3]
    doAssertRaises ValueError: discard copyInto(main, proj, id)
    removeTemp(dir)

  block generate_matches_processSEG:
    let g = GeneratedReference(name: "", law: rlLinear, f1Hz: 8, f2Hz: 80, durationMs: 8000,
      dtMs: 2, taperStartMs: 200, taperEndMs: 300, amplitude: 1)
    doAssert defaultGenerateName(g) == "Linear 8-80 Hz 8 s"
    let made = generateSamples(g)
    let spec = linearSweep(8, 80, 8000, 2, initSweepTaper(200, 300), amplitude = 1)
    let hand = spec.sweepSamples(float32)
    doAssert made == hand, "generate is not processSEG's sweep"
    let dir = tempDir()
    let folder = referencesFolder(dir)
    let id = storeSamples(folder, defaultGenerateName(g), g.dtMs * 1000, made,
      ReferenceOrigin(generated: true, law: g.law, f1Hz: g.f1Hz, f2Hz: g.f2Hz,
        durationMs: g.durationMs, dtMs: g.dtMs, taperStartMs: 200, taperEndMs: 300, amplitude: 1))
    let e = loadIndex(folder).entries[0]
    doAssert e.id == id and e.origin.generated and e.origin.f1Hz == 8 and e.origin.f2Hz == 80
    doAssert frequencyText(e) == "8-80 Hz"
    removeTemp(dir)

  block a_bad_file_is_left:
    # Seen to fail: with `deleteIn` joining `file` onto the folder, the file
    # outside the archive was removed.
    let dir = tempDir()
    let folder = referencesFolder(dir)
    let outside = dir / "outside.sgy"
    writeFile(outside, "keep")
    createDir(folder)
    writeFile(indexPath(folder), """(.nif27)
(references
  (version 1)
  (entry (id "rbad") (name "bad") (intervalUs 2000.0) (samples 1)
    (date "2026-01-01T00:00:00Z") (file "../outside.sgy")
    (source (generated false) (fileName "a.sgy") (trace 1) (fromMs 0.0) (toMs 2.0))))
""")
    let index = loadIndex(folder)
    doAssert index.entries.len == 1 and index.entries[0].blocked
    doAssert index.problems.len > 0, "a bad file name is said"
    doAssertRaises ValueError: discard deleteIn(folder, "rbad")
    doAssertRaises ValueError: renameIn(folder, "rbad", "other")
    doAssert readFile(outside) == "keep", "a bad entry was deleted through"
    doAssert fileExists(indexPath(folder))
    removeTemp(dir)

  block orphans_are_said_and_left:
    # Seen to fail: with no word about a SEG-Y the index does not name,
    # the message was empty and the file was removed.
    let dir = tempDir()
    let folder = referencesFolder(dir)
    createDir(folder)
    writeFile(folder / "left.sgy", "orphan")
    writeFile(indexPath(folder), """(.nif27)
(references (version 1))
""")
    let index = loadIndex(folder)
    doAssert index.problems.len == 1 and "1 reference file is not in the index" in index.problems[0],
      $index.problems
    doAssert readFile(folder / "left.sgy") == "orphan", "an unlisted file was deleted"
    removeTemp(dir)

  block sweep_too_long_is_refused:
    # Seen to fail: with no check before generateSamples, a sweep past 2³¹
    # samples was started.
    let g = GeneratedReference(law: rlLinear, f1Hz: 8, f2Hz: 80, durationMs: 1e12, dtMs: 0.001,
      amplitude: 1)
    let why = sweepTooLong(g)
    doAssert "over 2" in why and "samples" in why, why
    doAssert sweepTooLong(GeneratedReference(law: rlLinear, f1Hz: 8, f2Hz: 80,
      durationMs: 1000, dtMs: 2, amplitude: 1)).len == 0
    let shown = previewGenerate(GeneratedReference(law: rlLinear, f1Hz: 8, f2Hz: 80,
      durationMs: 100_000, dtMs: 2, amplitude: 1))
    doAssert shown.durationMs == 100_000, "a preview is the whole sweep, not its start"

  block the_lock_is_the_per_user_one:
    # Seen to fail: with no lock around the index write, files.lock was not made.
    let dir = tempDir()
    let folder = referencesFolder(dir)
    doAssert archiveLockPath(folder).endsWith("files.lock"), archiveLockPath(folder)
    let origin = ReferenceOrigin(generated: false, fileName: "a.sgy", trace: 1, fromMs: 0,
      toMs: 2)
    discard storeSamples(folder, "one", 2000, @[1'f32, 2], origin)
    doAssert fileExists(archiveLockPath(folder)), "the per-user lock was not taken"
    # a second writer re-reads: an entry written before the call is kept
    discard storeSamples(folder, "two", 2000, @[1'f32, 2], origin)
    var names: seq[string] = @[]
    for e in loadIndex(folder).entries: names.add e.name
    doAssert names == @["one", "two"], $names
    removeTemp(dir)

  echo "treferences: ok"

when isMainModule:
  main()
