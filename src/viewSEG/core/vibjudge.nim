## The verdict of a vibrator sweep, judged the way a vibrator controller's own QC
## reports it: statistics per window of the sweep (500 ms by default, `windowStats`
## of processSEG), then the average and the worst window of them against six limits.
##
## | Limit | Measured | Default |
## |---|---|---|
## | Average phase | mean of the windows' mean \|phase\| | at most 5° |
## | Peak phase | the largest window's mean \|phase\| | at most 10° |
## | Average distortion | mean of the windows' mean in-band THD | at most 30 % |
## | Peak distortion | the largest window's mean in-band THD | at most 60 % |
## | Average force | mean of the windows' mean fundamental, % of the target | at least 90 % |
## | Peak force | the largest \|force\| of a window, % of the target | at most 120 % |
##
## - The force is in percent of "100 % force =", a number in the file's own unit that
##   the user types; without it the two force limits are not judged, and the report
##   says why (the others are).
## - The sweep's tapers are left out of the judgement (`judgedPart`): the statistics
##   are over the flat part only.
## - A limit is a failure only when it is measured: a value that is not a number (no
##   window had one) is "not judged", never a pass.
## - The verdict is `qvFail` when any limit fails, `qvPass` when at least one was judged
##   and none failed, else `qvNotJudged`. Its line names the worst failing value
##   (the one furthest past its limit, in proportion) and the time of its window.
## - Against the project's stored reference (the plan), the file's recorded pilot is judged
##   too, with the same two phase limits (`judgePlan`): a pilot that is not the planned sweep
##   fails the file, and `withBasis` says so first. A judged part shorter than the reference
##   sweep is a pass "on the part recorded" only, and holding less than half of it
##   (`LeastSweepShare`) no pass at all: not judged; a file judged against its own pilot says
##   that this shows the vibrator followed its pilot, not that the pilot is the plan.
##
## Pure: numbers in, a report out.

import std/[math, strutils]
import processSEG/vibroseis/vibqc

type
  QcLimit* = enum
    qlAvgPhase = "average phase"
    qlPeakPhase = "peak phase"
    qlAvgDistortion = "average distortion"
    qlPeakDistortion = "peak distortion"
    qlAvgForce = "average force"
    qlPeakForce = "peak force"

  QcStatus* = enum
    qsPass = "pass"
    qsFail = "fail"
    qsNotJudged = "not judged"

  QcVerdict* = enum
    qvNotJudged = "not judged"
    qvPass = "pass"
    qvFail = "fail"

  QcLimits* = object
    ## The six limits (NaN: that limit is off). The two phases are in degrees, the two
    ## distortions in %, the forces in % of the target ("100 % force =").
    avgPhaseDeg*: float64 = 5
    peakPhaseDeg*: float64 = 10
    avgDistortionPct*: float64 = 30
    peakDistortionPct*: float64 = 60
    avgForcePct*: float64 = 90 ## at least
    peakForcePct*: float64 = 120 ## at most

  QcRow* = object
    ## One limit against what was measured.
    limit*: QcLimit
    measured*: float64 ## NaN: none
    bound*: float64    ## the limit; NaN: off
    atMs*: float64     ## the start of the worst window (a peak's); NaN for an average
    status*: QcStatus
    why*: string       ## when not judged
    ofHundred*, target*: float64 = NaN
      ## the average force row's: the same force in % of the 100 % force, and the target (%) the
      ## measured value is a percent of

  QcStats* = object
    ## The window statistics, as measured (the forces in the file's unit, and in % of
    ## the target when there is one; each with the start of its window).
    windows*: int
    windowMs*: float64
    avgPhaseDeg*, peakPhaseDeg*, peakPhaseAtMs*: float64
    avgDistortionPct*, peakDistortionPct*, peakDistortionAtMs*: float64
    avgForce*, minForce*, minForceAtMs*, peakForce*, peakForceAtMs*: float64
    avgForcePct*, minForcePct*, peakForcePct*: float64
    fundamentalPeak*, fundamentalPeakPct*: float64
      ## the largest window mean of the fundamental and its % of the 100 % force: shown beside
      ## the peak force (the raw envelope's, with the harmonics), never judged

  PlanCheck* = object
    ## The file's recorded pilot (what the vibrator was told to do) against the project's
    ## stored reference (the plan, what it should do), judged with the ground force's own two
    ## phase limits after the same alignment.
    compared*: bool ## a recorded pilot was measured against a stored reference
    rows*: seq[QcRow] ## its average and peak phase (`qlAvgPhase`, `qlPeakPhase`)
    verdict*: QcVerdict ## those two rows' verdict; `qvNotJudged` when not compared
    shiftMs*: float64 = NaN
      ## how far the stored reference was moved to the recorded pilot (`alignStored`); NaN:
      ## not aligned
    sweep*: string
      ## how the two sweeps differ, in words with numbers ("the project reference sweeps
      ## 8-80 Hz in 12.0 s; the recorded pilot sweeps 8-80 Hz in 10.0 s"), or why they could
      ## not be compared ("sweeps not compared: ..."); "" when they are the same sweep
    sameSweep*: bool ## start, end and length agree within the tolerances
    opposite*: bool
      ## the recorded pilot is the plan's sweep with opposite polarity: its average phase to it
      ## lies within the average phase limit of 180°. A finding, said; nothing is reversed
    fileRows*: seq[QcRow]
      ## the judged ground force's average and peak phase against the file's own reference
      ## trace, beside the judged ones against the plan: shown, never judged

  QcReport* = object
    verdict*: QcVerdict
    line*: string        ## "FAIL: peak force 157 % > 120 % at 9.5 s"
    rows*: seq[QcRow]    ## one per limit, in `QcLimit`'s order
    worst*: int          ## the failing row furthest past its limit; -1 for none
    stats*: QcStats
    hundredPct*: float64 ## "100 % force =" in the file's unit; NaN: not given
    forceNote*: string   ## why the force limits are not judged; "" when they are
    plan*: PlanCheck     ## the recorded pilot against the plan (`withBasis`)
    recordedPct*: float64 = NaN
      ## the share of the reference sweep the judged part covers, % (below 100); NaN: all of it
    lengthWords*: string
      ## what of a sweep lies past the other's end and was not judged; "" for nothing
    ownPilot*: bool
      ## judged against the file's own pilot: it shows the vibrator followed its pilot, not
      ## that the pilot is the planned sweep
    forceLine*: string
      ## the ground force's own line, as `judge` wrote it, before `withBasis` added the plan's

func plain*(x: float64; digits = 1): string =
  ## A number for a sentence: up to `digits` decimals, none when it is whole.
  if x.isNaN: return "-"
  if abs(x) == Inf: return (if x < 0: "-" else: "") & "inf"
  result = formatFloat(x, ffDecimal, digits)
  if '.' in result:
    result = result.strip(leading = false, chars = {'0'}).strip(leading = false,
        chars = {'.'})
  if result == "-0": result = "0"

func forceNumber*(x: float64): string =
  ## A force for a table: four significant digits whatever its size (13202, 662.9,
  ## 0.001200), scientific outside 0.001 to 10 million; "–" for none.
  if x.isNaN or abs(x) == Inf: "–"
  elif x == 0: "0"
  elif abs(x) >= 1e-3 and abs(x) < 1e7:
    let decimals = clamp(3 - int(floor(log10(abs(x)))), 0, 6)
    if decimals == 0: $int64(round(x)) else: formatFloat(x, ffDecimal, decimals)
  else: formatFloat(x, ffScientific, 3)

func seconds*(ms: float64): string =
  ## "9.5 s"; "-" for none.
  if ms.isNaN: "-" else: formatFloat(ms / 1000, ffDecimal, 1) & " s"

func unitOf*(l: QcLimit): string =
  case l
  of qlAvgPhase, qlPeakPhase: "°"
  of qlAvgDistortion, qlPeakDistortion, qlAvgForce, qlPeakForce: " %"

func isLowerBound(l: QcLimit): bool {.inline.} = l == qlAvgForce

func boundText*(r: QcRow): string =
  ## "≤ 5°", "≥ 90 % of target", "≤ 120 % of full"; "off" without a limit.
  let of100 = case r.limit
    of qlAvgForce: " of target"
    of qlPeakForce: " of 100 %"
    else: ""
  if r.bound.isNaN: "off"
  else: (if r.limit.isLowerBound: "≥ " else: "≤ ") & plain(r.bound) & r.limit.unitOf & of100

func measuredText*(r: QcRow): string =
  ## "7.2°"; "-" for none. With decimals added (up to 4, none stripped at the last) when
  ## fewer would read the same as the limit ("5.0001° > 5°", not "5° > 5°").
  if r.measured.isNaN: return "-"
  var digits = 1
  if not r.bound.isNaN:
    while digits < 4 and plain(r.measured, digits) == plain(r.bound): inc digits
  let text = if digits == 4 and plain(r.measured, 4) == plain(r.bound):
               formatFloat(r.measured, ffDecimal, 4)
             else: plain(r.measured, digits)
  result = text & r.limit.unitOf
  if r.limit == qlAvgForce and not r.ofHundred.isNaN and not r.target.isNaN and
      r.target != 100:
    # both bases in one place: the plot's axis is % of the 100 % force, the limit a % of target
    result = plain(r.ofHundred) & " % of 100 % force = " & result & " of the " &
      plain(r.target) & " % target"

func markText*(r: QcRow): string =
  ## The mark as text, never colour alone: "✓", "✗", or "–" (not judged).
  case r.status
  of qsPass: "✓"
  of qsFail: "✗"
  of qsNotJudged: "–"

func atText*(r: QcRow): string =
  ## Where the worst window starts: "at 9.5 s"; "" for an average or none.
  if r.atMs.isNaN: "" else: "at " & seconds(r.atMs)

func excess(r: QcRow): float64 =
  ## How far past its limit, as a ratio (1 at the limit).
  if r.bound.isNaN or r.measured.isNaN: 0.0
  elif r.limit.isLowerBound: (if r.measured > 0: r.bound / r.measured else: Inf)
  elif r.bound > 0: r.measured / r.bound
  else: Inf

func rowOf(l: QcLimit; measured, bound, atMs: float64; why: string): QcRow =
  result = QcRow(limit: l, measured: measured, bound: bound, atMs: atMs,
    status: qsNotJudged, why: why)
  if bound.isNaN:
    result.why = "limit off"
  elif result.why.len == 0 and measured.isNaN:
    result.why = "no measurement in the judged part"
  elif result.why.len == 0:
    let failed = if l.isLowerBound: measured < bound else: measured > bound
    result.status = if failed: qsFail else: qsPass

func percent(x, hundred: float64): float64 {.inline.} =
  if hundred.isNaN or not (hundred > 0): NaN else: 100 * x / hundred

func judge*(s: WindowSummary; windowMs: float64; limits: QcLimits;
    hundredPct: float64; targetPct = 100.0; on = ""): QcReport =
  ## The report of the window statistics `s` (of windows of `windowMs`) against
  ## `limits`, the forces turned to % of `hundredPct` (the file's unit; NaN or not above
  ## 0: not given, the force limits not judged). The average and the minimum force are
  ## % of the target, `hundredPct` times `targetPct` / 100 (the drive level the vibrator
  ## was set to: 60 % of full scale, say); the peak force is % of `hundredPct` itself (the
  ## hold-down's full scale). `on` names the signal judged when there is a choice
  ## ("GF (M, B)"): the verdict line says so.
  let hundred = if hundredPct.isNaN or not (hundredPct >
      0): NaN else: hundredPct
  let target = if targetPct.isNaN or not (targetPct > 0): 100.0 else: targetPct
  let st = QcStats(windows: s.windows, windowMs: windowMs,
    avgPhaseDeg: s.meanAbsPhaseDeg,
    peakPhaseDeg: s.maxAbsPhaseDeg, peakPhaseAtMs: s.maxAbsPhaseAtMs,
    avgDistortionPct: s.meanThdPct, peakDistortionPct: s.maxThdPct,
    peakDistortionAtMs: s.maxThdAtMs, avgForce: s.meanForce,
    minForce: s.minForce,
    minForceAtMs: s.minForceAtMs, peakForce: s.maxPeak,
    peakForceAtMs: s.maxPeakAtMs, fundamentalPeak: s.maxForce,
    fundamentalPeakPct: percent(s.maxForce, hundred),
    avgForcePct: percent(s.meanForce, hundred * target / 100),
    minForcePct: percent(s.minForce, hundred * target / 100),
    peakForcePct: percent(s.maxPeak, hundred))
  let noScale = if hundred.isNaN: "type the force that is 100 % in the \"100 % force =\" " &
                  "box (the file's unit) to judge the force" else: ""
  result = QcReport(verdict: qvNotJudged, worst: -1, stats: st,
    hundredPct: hundred,
    forceNote: noScale)
  result.rows = @[
    rowOf(qlAvgPhase, st.avgPhaseDeg, limits.avgPhaseDeg, NaN, ""),
    rowOf(qlPeakPhase, st.peakPhaseDeg, limits.peakPhaseDeg, st.peakPhaseAtMs, ""),
    rowOf(qlAvgDistortion, st.avgDistortionPct, limits.avgDistortionPct, NaN, ""),
    rowOf(qlPeakDistortion, st.peakDistortionPct, limits.peakDistortionPct,
      st.peakDistortionAtMs, ""),
    rowOf(qlAvgForce, st.avgForcePct, limits.avgForcePct, NaN, noScale),
    rowOf(qlPeakForce, st.peakForcePct, limits.peakForcePct, st.peakForceAtMs, noScale)]
  result.rows[ord(qlAvgForce)].ofHundred = percent(s.meanForce, hundred)
  result.rows[ord(qlAvgForce)].target = target
  let onWords = if on.len > 0: " on " & on else: ""
  var failed, passed = 0
  var worst = 0.0
  for i, r in result.rows:
    case r.status
    of qsFail:
      inc failed
      if result.worst < 0 or r.excess > worst: (result.worst, worst) = (i, r.excess)
    of qsPass: inc passed
    of qsNotJudged: discard
  if s.windows == 0:
    result.line = "NOT JUDGED: no window of the sweep's flat part has a measurement"
  elif failed > 0:
    result.verdict = qvFail
    let w = result.rows[result.worst]
    let cmp = if w.limit.isLowerBound: " < " else: " > "
    let at = w.atText
    result.line = "✗ FAIL" & onWords & ": " & $w.limit & " " & w.measuredText & cmp &
      plain(w.bound) & w.limit.unitOf & (if at.len > 0: " " & at else: "") &
      (if failed > 1: " (and " & $(failed - 1) & " more)" else: "")
  elif passed > 0:
    result.verdict = qvPass
    result.line = "✓ PASS" & onWords & ": " & $passed & " of " & $result.rows.len &
        " limits met" &
      (if passed < result.rows.len: " (" & $(result.rows.len - passed) &
          " not judged" &
       (if noScale.len > 0 and hundred.isNaN: ": " & noScale else: "") & ")" else: "")
  else:
    result.line = "NOT JUDGED: no limit could be judged" &
      (if noScale.len > 0: " (" & noScale & ")" else: "")

const
  OwnPilotWords* = "judged against the file's own pilot: this shows the vibrator followed " &
    "its pilot, not that the pilot is the planned sweep"
    ## said in every verdict judged against the file's own pilot (no project reference, the
    ## switch off, or a reference that is a trace of each record)
  PlanRowPrefix* = "recorded pilot to the plan: "
    ## the limits table's label of a plan row, before the limit ("recorded pilot to the plan:
    ## average phase")
  LeastSweepShare* = 0.5
    ## the least share of the reference sweep a file's judged part holds for the file to pass:
    ## below it the file is not judged (its limits still listed), never a pass; from it up it
    ## passes "on the part recorded"
  FileRowPrefix* = "ground force to the file's reference (not judged): "
    ## the limits table's label of a row of the ground force against the file's own reference
    ## trace, shown beside the judged one against the plan

func judgePlan*(s: WindowSummary; windowMs: float64; limits: QcLimits;
    shiftMs = NaN): PlanCheck =
  ## The recorded pilot's window statistics `s` (measured against the stored reference) judged
  ## with the phase limits of `limits` alone, the ground force's: no limit of its own.
  let phases = QcLimits(avgPhaseDeg: limits.avgPhaseDeg, peakPhaseDeg: limits.peakPhaseDeg,
    avgDistortionPct: NaN, peakDistortionPct: NaN, avgForcePct: NaN, peakForcePct: NaN)
  let q = judge(s, windowMs, phases, NaN)
  PlanCheck(compared: true, rows: q.rows[ord(qlAvgPhase) .. ord(qlPeakPhase)],
    verdict: q.verdict, shiftMs: shiftMs)

func planWords*(p: PlanCheck): string =
  ## "the recorded pilot is not the project's reference sweep (average phase N°)": the
  ## sentence a failing plan check opens the verdict with; for a pilot of opposite polarity
  ## (`opposite`) "the recorded pilot is the project's reference sweep with opposite polarity
  ## (average phase N°)".
  let avg = p.rows[ord(qlAvgPhase)]
  let phase = "(average phase " &
    (if avg.measured.isNaN: "not measured" else: plain(avg.measured) & "°") & ")"
  if p.opposite: "the recorded pilot is the project's reference sweep with opposite polarity " &
    phase
  else: "the recorded pilot is not the project's reference sweep " & phase

func unsigned(line: string): string =
  ## `line` without the sign `judge` opens it with ("✓ ", "✗ ").
  for sign in ["✓ ", "✗ "]:
    if line.startsWith(sign): return line[sign.len .. ^1]
  line

func withBasis*(q: var QcReport) =
  ## The verdict and its line with what the reference is: a recorded pilot that is not the
  ## plan fails the file, its sentence first; a judged part shorter than the reference sweep
  ## passes only "on the part recorded", and is not judged under `LeastSweepShare` of it; how
  ## the sweeps differ, and what was not judged, is
  ## said; a file judged against its own pilot says what that shows. Call once, after `judge`.
  q.forceLine = q.line
  var parts: seq[string] = @[]
  let failed = q.plan.compared and q.plan.verdict == qvFail
  if failed:
    q.verdict = qvFail
    parts.add "✗ FAIL: " & planWords(q.plan) &
      (if q.plan.sweep.len > 0: ": " & q.plan.sweep else: "")
    parts.add "ground force " & unsigned(q.line)
  elif q.verdict == qvPass and not q.recordedPct.isNaN:
    let rest = if q.line.startsWith("✓ PASS"): q.line["✓ PASS".len .. ^1] else: ""
    let pct = plain(floor(q.recordedPct), 0)
    if q.recordedPct < 100 * LeastSweepShare:
      # too little of the sweep to stand for it: no pass, the limits measured still listed
      q.verdict = qvNotJudged
      parts.add "not judged: only " & pct & " % of the reference sweep is in this file's " &
        "traces (a pass needs half of it)" &
        (if rest.startsWith(": "): "; on that part " & rest[2 .. ^1] else: "")
    else:
      parts.add "✓ pass on the part recorded (" & pct & " % of the reference sweep)" & rest
  else: parts.add q.line
  if q.plan.sweep.len > 0 and not failed: parts.add q.plan.sweep
  if q.lengthWords.len > 0: parts.add q.lengthWords
  if q.ownPilot: parts.add OwnPilotWords
  q.line = parts.join("; ")

func tableOf*(r: QcReport): seq[seq[string]] =
  ## The limits table: a header, then a row per limit: the mark (first, so a narrow window never
  ## cuts it off), what, measured, limit, where; then the recorded pilot's rows against the
  ## plan, when it was compared (`allRows` gives the rows in the same order).
  result = @[@["Met", "Limit", "Measured", "Limit value", "Worst window"]]
  for row in r.rows:
    result.add @[row.markText, $row.limit, row.measuredText, row.boundText,
      (if row.status == qsNotJudged: row.why else: row.atText)]
  for row in r.plan.rows:
    result.add @[row.markText, PlanRowPrefix & $row.limit, row.measuredText, row.boundText,
      (if row.status == qsNotJudged: row.why else: row.atText)]
  for row in r.plan.fileRows:
    result.add @[row.markText, FileRowPrefix & $row.limit, row.measuredText, row.boundText,
      (if row.status == qsNotJudged: row.why else: row.atText)]

func allRows*(r: QcReport): seq[QcRow] =
  ## The rows of `tableOf` after its header: the limits, then the plan's.
  r.rows & r.plan.rows & r.plan.fileRows
