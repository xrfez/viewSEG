## A folder QC table counts every file under its own verdict, apart from
## problems and skips, sorts stably, and filters without dropping the
## profile's problems. A paired file keeps that verdict and names its
## partner. Header weights that differ from the job's are words; nothing
## is rescaled.
##
  ## Seen to fail: with the measure columns untitled, `textAndCsv` does not
  ## find "Average phase (°)". With the totals always saying "files" and
  ## "problems", `plurals` still finds "1 problems". With a problem row's
  ## sentence left empty, `problemSentence` does not find the reason. With
  ## Kind still the shared "vibrator .dat" prefix, `kindLabels` cannot tell
  ## a `.dat` from a `.vib`. With the empty-reference problem left as the
  ## archive sentence, `recordedReference` still finds that fault.

import std/[math, strutils]
import viewSEG/core/[sigtypes, units, vibfolderqc, vibjudge]
import viewSEG/view/vibfolderwords

func row(path: string; outcome: FolderOutcome; verdict: QcVerdict; kind = sgDat;
    pair = ""; sentence = ""; polarity = ""; problem = ""): FolderRow =
  FolderRow(path: path, kind: kind, pair: pair, outcome: outcome, verdict: verdict,
    sentence: sentence, polarity: polarity, problem: problem)

proc main*() =
  block totals:
    let rows = @[
      row("a.dat", foJudged, qvPass),
      row("b.dat", foJudged, qvFail),
      row("c.dat", foJudged, qvNotJudged),
      row("d.dat", foProblem, qvNotJudged, problem = "cannot be read"),
      row("e.dat", foSkipped, qvNotJudged, problem = "Cancelled."),
      row("f.vib", foJudged, qvFail, kind = sgVib, pair = "a.dat")]
    let t = totalsOf(rows)
    doAssert t.files == 6, $t.files
    doAssert t.passed == 1 and t.failed == 2 and t.notJudged == 1, $t
    doAssert t.problems == 1 and t.skipped == 1, $t

  block stable:
    var table = FolderTable(rows: @[
      row("b.dat", foJudged, qvFail, sentence = "FAIL"),
      row("a.dat", foJudged, qvFail, sentence = "FAIL"),
      row("c.dat", foJudged, qvPass, sentence = "PASS")])
    let sorted = sortedBy(table, [fcVerdict, fcPath])
    doAssert sorted.rows[0].path == "a.dat", sorted.rows[0].path
    doAssert sorted.rows[1].path == "b.dat", sorted.rows[1].path
    doAssert sorted.rows[2].path == "c.dat", sorted.rows[2].path
    let same = sortedBy(table, [])
    doAssert same.rows[0].path == "b.dat"

  block filterKeepsProblems:
    var table = FolderTable(problems: @["No 100 % force: the force limits are not judged."],
      rows: @[row("keep.dat", foJudged, qvPass, sentence = "PASS"),
        row("drop.dat", foJudged, qvFail, sentence = "FAIL")])
    let kept = filtered(table, "keep")
    doAssert kept.rows.len == 1 and kept.rows[0].path == "keep.dat"
    doAssert kept.totals.passed == 1 and kept.totals.files == 1
    doAssert kept.problems == table.problems
    let all = filtered(table, "")
    doAssert all.rows.len == 2 and all.totals.files == 2

  block weightsAreWords:
    let header = VibWeights(holdDownLb: 40000, baseplateLb: 6000, massLb: 4000)
    let sameKg = 40000.0 * KgPerLb
    doAssert weightFindings(header, sameKg, 6000.0 * KgPerLb, 4000.0 * KgPerLb).len == 0
    let found = weightFindings(header, 10000, NaN, NaN)
    doAssert found.len == 1, $found
    doAssert "differ" in found[0] and "hold-down" in found[0], found[0]
    doAssert "Nothing is corrected or rescaled" in found[0], found[0]
    doAssert weightFindings(VibWeights(), 10000, 10000, 10000).len == 0

  block pairKeepsOwnVerdict:
    ## A paired `.vib` that fails keeps that verdict, sentence and measures,
    ## and is counted as a failure. Pairing only adds the partner's name.
    ## Seen to fail when the `.vib` was marked contributed and its fail vanished.
    var rows = @[
      row("a.dat", foJudged, qvPass, sentence = "PASS"),
      row("a.vib", foJudged, qvFail, kind = sgVib, pair = "a.dat", polarity = "opposite",
        sentence = "FAIL: peak force")]
    rows[0].pair = "a.vib"
    rows[1].warnings = @["Sweep fit: too few crossings"]
    rows[1].measures = @[FolderMeasure(limit: qlPeakForce, measured: 400.0, bound: 10.0,
      status: qsFail)]
    attachPairs(rows)
    doAssert rows[1].outcome == foJudged, $rows[1].outcome
    doAssert rows[1].verdict == qvFail and rows[1].sentence == "FAIL: peak force"
    doAssert rows[1].measures.len == 1
    doAssert rows[0].outcome == foJudged and rows[0].verdict == qvPass
    doAssert rows[0].extraPolarity == "opposite", rows[0].extraPolarity
    doAssert rows[0].extraWarnings == @["Sweep fit: too few crossings"]
    var vibNamed = false
    var datNamed = false
    for w in rows[1].warnings:
      if w == "Paired with a.dat": vibNamed = true
    for w in rows[0].warnings:
      if w == "Paired with a.vib": datNamed = true
    doAssert vibNamed, $rows[1].warnings
    doAssert datNamed, $rows[0].warnings
    let t = totalsOf(rows)
    doAssert t.passed == 1 and t.failed == 1, $t
    doAssert t.notJudged == 0 and t.problems == 0
    let text = resultsText(FolderTable(rows: rows))
    doAssert "Paired with a.dat" in text and "Paired with a.vib" in text, text
    doAssert "contributed" notin text

  block pairProblemKeepsVerdict:
    ## A problem or a skipped partner does not take the other file's verdict.
    var rows = @[
      row("bad.dat", foProblem, qvNotJudged, pair = "ok.vib", problem = "cannot be read"),
      row("ok.vib", foJudged, qvPass, kind = sgVib, pair = "bad.dat", sentence = "PASS"),
      row("skip.dat", foSkipped, qvNotJudged, pair = "late.vib", problem = "Cancelled."),
      row("late.vib", foJudged, qvFail, kind = sgVib, pair = "skip.dat", sentence = "FAIL")]
    attachPairs(rows)
    doAssert rows[0].outcome == foProblem and rows[0].problem == "cannot be read"
    doAssert rows[1].outcome == foJudged and rows[1].verdict == qvPass
    doAssert rows[1].sentence == "PASS"
    doAssert rows[2].outcome == foSkipped
    doAssert rows[3].outcome == foJudged and rows[3].verdict == qvFail
    doAssert rows[3].sentence == "FAIL"

  block plurals:
    let one = summaryLine(FolderTotals(files: 1, passed: 1, failed: 1,
      notJudged: 1, problems: 1, skipped: 1))
    doAssert "1 file," in one, one
    doAssert "1 pass," in one, one
    doAssert "1 fail," in one, one
    doAssert "1 problem," in one, one
    doAssert "1 skipped" in one, one
    doAssert "1 files" notin one and "1 problems" notin one, one
    let many = summaryLine(FolderTotals(files: 2, passed: 0, failed: 2,
      problems: 2, skipped: 2))
    doAssert "2 files," in many and "0 passes," in many, many
    doAssert "2 fails," in many and "2 problems," in many, many
    doAssert "2 skipped" in many, many

  block problemSentence:
    let bad = row("corrupt.dat", foProblem, qvNotJudged, problem = "it cannot be read")
    doAssert rowCells(bad)[4] == "it cannot be read", rowCells(bad)[4]
    let judged = row("good.dat", foJudged, qvPass, sentence = "PASS: within limits")
    doAssert rowCells(judged)[4] == "PASS: within limits", rowCells(judged)[4]

  block kindLabels:
    let dat = row("a.dat", foJudged, qvPass, kind = sgDat, sentence = "PASS")
    let vib = row("a.vib", foJudged, qvFail, kind = sgVib, sentence = "FAIL")
    doAssert rowCells(dat)[1] != rowCells(vib)[1], rowCells(dat)[1] & " / " & rowCells(vib)[1]
    doAssert ".dat" in rowCells(dat)[1] and "vibrator" notin rowCells(dat)[1], rowCells(dat)[1]
    doAssert ".vib" in rowCells(vib)[1] and rowCells(vib)[1] != "vibrator", rowCells(vib)[1]

  block recordedReference:
    var table = FolderTable(problems: @[
      "The reference is not in the archive.",
      "The reference \"pilot\" is not in the archive."],
      rows: @[row("a.dat", foJudged, qvPass, sentence = "PASS")])
    table.totals = totalsOf(table.rows)
    let text = resultsText(table)
    doAssert "Measured against each file's recorded reference." in text, text
    doAssert "The reference is not in the archive." notin text, text
    doAssert "The reference \"pilot\" is not in the archive." in text, text
    let csv = resultsCsv(table)
    doAssert RecordedReference in csv, csv
    doAssert "pilot" in csv and ArchiveMissing notin csv, csv

  block textAndCsv:
    var measured = FolderRow(path: "/tmp/one.dat", kind: sgDat, outcome: foJudged,
      verdict: qvFail, sentence: "FAIL: peak phase", problem: "a, \"quote\"")
    measured.measures = @[FolderMeasure(limit: qlPeakPhase, measured: 12.0, bound: 10.0,
      status: qsFail)]
    var table = FolderTable(problems: @["No 100 % force: the force limits are not judged."],
      rows: @[measured], weightWords: @["two sets"])
    table.totals = totalsOf(table.rows)
    let text = resultsText(table)
    doAssert text.countLines >= 4, $text.countLines
    doAssert "No 100 % force" in text
    doAssert "Average phase (°)" in text and "one.dat" in text
    doAssert "Peak phase (°)" in text and "Average distortion (%)" in text
    doAssert "Peak distortion (%)" in text and "Average force (%)" in text
    doAssert "Peak force (%)" in text
    doAssert "Average phase (°)" in resultsCsv(table)
    doAssert "1 file, 0 passes, 1 fail" in text
    doAssert "two sets" in text
    let csv = resultsCsv(table)
    doAssert "\"a, \"\"quote\"\"\"" in csv, csv
    doAssert "No 100 % force" in csv

  echo "tvibfolderqc: ok"

when isMainModule:
  main()
