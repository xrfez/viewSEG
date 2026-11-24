## A folder QC table counts judged rows apart from problems, skips and
## contributed files, sorts stably, and filters without dropping the
## profile's problems. Header weights that differ from the job's are words;
## nothing is rescaled.
##
## Seen to fail: with a contributed row also counted as not judged, `totals`
## names it (notJudged 2, not 1). With the measure columns untitled,
## `textAndCsv` does not find "Average phase (°)".

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
      row("f.vib", foContributed, qvNotJudged, kind = sgVib, pair = "a.dat")]
    let t = totalsOf(rows)
    doAssert t.files == 6, $t.files
    doAssert t.passed == 1 and t.failed == 1 and t.notJudged == 1, $t
    doAssert t.problems == 1 and t.skipped == 1 and t.contributed == 1, $t

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

  block pairContributes:
    var rows = @[
      row("a.dat", foJudged, qvPass, sentence = "PASS"),
      row("a.vib", foJudged, qvFail, kind = sgVib, pair = "a.dat", polarity = "opposite",
        sentence = "FAIL")]
    rows[1].warnings = @["Sweep fit: too few crossings"]
    attachPairs(rows)
    doAssert rows[1].outcome == foContributed and rows[1].sentence.len == 0
    doAssert rows[0].outcome == foJudged and rows[0].verdict == qvPass
    doAssert rows[0].extraPolarity == "opposite", rows[0].extraPolarity
    doAssert rows[0].extraWarnings == @["Sweep fit: too few crossings"]

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
    doAssert "1 files, 0 pass, 1 fail" in text
    doAssert "two sets" in text
    let csv = resultsCsv(table)
    doAssert "\"a, \"\"quote\"\"\"" in csv, csv
    doAssert "No 100 % force" in csv

  echo "tvibfolderqc: ok"

when isMainModule:
  main()
