## Which sweep a signature file's window is of, in `core`: the identity line (when it was
## triggered, controller, vibrator, and the point and ids only when the file gives them), the
## time of day in the window's title, the copied line, and the controller's limit letters with
## their probable meanings.
##
## - a `.dat` with a point: "2001-02-03 04:05:06.789 UTC · controller 4321 · vibrator 12 ·
##   line 5, station 101 · shot 77 · sweep 3"; without one nothing of a point or of the ids is
##   said (no "not given");
## - a `.vib` alone: "began 04:05:06 UTC"; with its `.dat`: the `.dat`'s trigger to the
##   millisecond, and its controller and vibrator;
## - the title carries the time of day after the file name;
## - the copied line has the file name, the identity, a tripped limit and the verdict;
## - limits: none says nothing, one is "M (mass displacement, probable)", several keep the
##   letters in order and R is "R (meaning not known)".
##
## Seen to fail: with the point said when 0, "no point is told when the file gives none"; with
## R given a meaning, "R stays unknown".

import std/strutils
import viewSEG/core/[analysis, sigtypes]

proc dat(point: bool): SignatureFacts =
  result = SignatureFacts(kind: sgDat)
  result.info = SweepInfo(kind: sgDat, controller: 4321, serialFrom: sfFile, vibrator: 12,
    triggerNs: 981173106_789_000_000'i64)
  if point:
    (result.info.line, result.info.station, result.info.shotId, result.info.sweepId) =
      (5'i64, 101'i64, 77'i64, 3'i64)

proc main*() =
  block dat_with_and_without_a_point:
    let with = identityOf(dat(true)).identityLine
    doAssert with == "2001-02-03 04:05:06.789 UTC · controller 4321 · vibrator 12 · " &
      "line 5, station 101 · shot 77 · sweep 3", with
    let without = identityOf(dat(false)).identityLine
    doAssert without == "2001-02-03 04:05:06.789 UTC · controller 4321 · vibrator 12", without
    doAssert "given" notin without and "line" notin without,
      "no point is told when the file gives none"
    doAssert identityOf(dat(true)).clockOf == "04:05:06.789"

  block vib_alone_and_with_its_pair:
    var f = SignatureFacts(kind: sgVib)
    f.info = SweepInfo(kind: sgVib, triggerNs: 981173106_000_000_000'i64)
    let alone = identityOf(f)
    doAssert alone.identityLine == "began 04:05:06 UTC", alone.identityLine
    doAssert alone.clockOf == "04:05:06"
    f.pair = "x.dat"
    f.pairTriggerNs = 981173107_321_000_000'i64
    f.info.controller = 4321
    f.info.serialFrom = sfPair
    f.info.vibrator = 12
    let paired = identityOf(f)
    doAssert paired.identityLine == "2001-02-03 04:05:07.321 UTC · controller 4321 · vibrator 12",
      paired.identityLine

  block no_identity_for_another_file:
    doAssert identityOf(SignatureFacts()).identityLine == ""
    doAssert identityOf(SignatureFacts()).clockOf == ""

  block title_and_copy:
    var w = AnalysisWindow(id: 2, view: avVibrator, file: "0042.dat", record: "FFID 7001",
      traces: @[0, 1, 2, 3], first: 0)
    doAssert w.title.endsWith("0042.dat"), w.title
    w.sweep = identityOf(dat(false))
    doAssert w.title.endsWith("0042.dat · 04:05:06.789"), w.title
    w.sweep.limits = {qlM}
    let line = w.identityCopy
    doAssert line.startsWith("0042.dat · 2001-02-03 04:05:06.789 UTC · controller 4321"), line
    doAssert "controller tripped M (mass displacement, probable)" in line, line

  block limit_words:
    doAssert limitsWords({}) == ""
    doAssert limitsWords({qlM}) == "M (mass displacement, probable)"
    doAssert limitsWords({qlT, qlV, qlF}) ==
      "T (torque motor, probable), V (valve displacement, probable), F (force, probable)"
    doAssert limitsWords({qlM, qlR}) == "M (mass displacement, probable), R (meaning not known)"
    doAssert "probable" notin limitWords(qlR), "R stays unknown"
    doAssert LimitsProbable.startsWith("Probable meanings")
  echo "tsweepidentity: ok"

when isMainModule:
  main()
