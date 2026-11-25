## The ground force switch of the Vibrator signature window: "In the record" (the trace
## coded as ground force, as it is) or "Made from mass and baseplate" (`JudgeOn`), for each
## kind of file that has a ground force and the mass and baseplate traces, on made-up sweeps
## with a known true ground force:
##
## - a converter's SEG-Y (traces coded 21, 19, 18, 20): each force channel is mean-removed
##   and divided by its own weight, the fourth trace is the hold-down weight times their equal
##   sum, which is no ground force. Made from mass and baseplate with the two weights as the
##   masses gives the true ground force (the same shape, the same size), In the record gives the
##   fourth trace as it is; the typed weights multiply the trace that the roles say, and the
##   roles can be swapped;
## - a `.dat` (two force channels, weighted already: their plain sum) and a `.vib` (the
##   header's weights times the two accelerations): the switch is offered, both choices give
##   the same ground force and a line says so; typed masses are never applied;
## - an ordinary SEG-Y without masses: the switch is offered, made from mass and baseplate
##   says why it is not made and the recorded ground force is judged;
## - each made signal has its own 100 % force: not set, the force limits are not judged.
##
## Seen to fail: with `vibratorOf` ignoring `roles.judge` for a signature file, the `.dat` and
## `.vib` blocks found no second signal; with the made signal's weights not scaled by the
## window's force scale the scaled block read another ground force; with the typed masses
## multiplying the roles' traces the other way round, the converter block's correlation fell
## below 0.99.

import std/[math, os, strutils]
import viewSEG/core/[analysis, plotoptions, settings, state, vibanalysis]
import utils/[fixtures, sigfiles, vibsynth, waiting]

func curveOf(r: AnalysisResult; name: string): seq[float64] =
  for pl in r.plots:
    for c in pl.curves:
      if c.name == name: return c.ys
  doAssert false, name & " is not drawn"

proc agree(a, b: seq[float64]; sized = true): (float64, float64) =
  ## The correlation of `a` and `b` where both are measured, and the spread of their ratio
  ## (largest over smallest: 1 for a constant ratio). `sized`: the two are also the same size, not only the same shape.
  var (n, sa, sb, saa, sbb, sab) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
  var (lo, hi) = (Inf, 0.0)
  for i in 0 ..< min(a.len, b.len):
    if not (a[i].isNaN or b[i].isNaN):
      n += 1
      sa += a[i]
      sb += b[i]
      saa += a[i] * a[i]
      sbb += b[i] * b[i]
      sab += a[i] * b[i]
      if abs(b[i]) > 1e-9 * abs(a[i]) and abs(a[i]) > 0:
        lo = min(lo, a[i] / b[i])
        hi = max(hi, a[i] / b[i])
  doAssert n > 100, "too few measured points: " & $n
  doAssert not sized or abs(sa / sb - 1) < 1e-4, "the two are not the same size: " & $(sa / sb)
  let cov = sab - sa * sb / n
  ((cov / sqrt((saa - sa * sa / n) * (sbb - sb * sb / n)), hi / lo))

func meanForce(r: AnalysisResult; signal: string): float64 =
  ## The table's "Mean force" of the row of `signal`.
  var at = -1
  for i, c in r.table[0]:
    if c == "Mean force": at = i
  for row in r.table[1 .. ^1]:
    if row[0] == signal and at >= 0: return parseFloat(row[at])
  doAssert false, signal & " is not in the table"

const
  Wm = 3600.0 ## the converter's reaction-mass weight
  Wb = 1400.0
  Wh = 8000.0 ## ... and its hold-down weight

type Converter = object
  reference, truth, record, mass, plate: seq[float32]

proc converterOf(): Converter =
  ## A true ground force g, split into a force channel of the reaction mass m (another phase
  ## and a harmonic) and of the baseplate g - m; the converter's traces: each channel
  ## mean-removed and divided by its weight, the fourth the hold-down weight times their sum.
  let g = SynthSweep(amp: 1000, phaseDeg: 1)
  let m = SynthSweep(amp: 700, phaseDeg: 20, h2: 0.05, burstAtS: 2, burstLenS: 3,
    burstGain: 2.5, burstPhaseDeg: 70)
  result.reference = g.referenceOf.sweepRow
  result.truth = g.sweepRow
  let fm = m.sweepRow
  var fb = newSeq[float32](fm.len)
  var (meanM, meanB) = (0.0, 0.0)
  for i in 0 ..< fm.len:
    fb[i] = result.truth[i] - fm[i]
    meanM += fm[i] / float64(fm.len)
    meanB += fb[i] / float64(fm.len)
  for i in 0 ..< fm.len:
    result.mass.add float32((fm[i] - meanM) / Wm)
    result.plate.add float32((fb[i] - meanB) / Wb)
    result.record.add float32(Wh * (result.mass[i] + result.plate[i]))

proc ask(rows: seq[seq[float32]]; p: AnalysisParams; at: array[VibRole, int]): AnalysisResult =
  result = vibratorOf(rows, @["Ref", "GF", "M", "B"], at, 1.0, p, -1, 100.0)
  doAssert result.problem == "", result.problem

proc converterBlocks() =
  let c = converterOf()
  let at = [vsReference: 0, vsGroundForce: 1, vsMass: 2, vsBaseplate: 3]
  let rows = @[c.reference, c.record, c.mass, c.plate]
  # the true ground force's own fundamental, from a window that holds it as its ground force
  let truth = ask(@[c.reference, c.truth], AnalysisParams(),
    [vsReference: 0, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1])
  let want = truth.curveOf("GF fundamental")
  var p = AnalysisParams(reactionMassKg: Wm, baseplateMassKg: Wb, details: true)
  block inTheRecord:
    let r = ask(rows, p, at)
    doAssert r.canMake and r.bothSignals and r.judged == "GF"
    # the fourth trace as it is: what a window holding only it draws
    let alone = ask(@[c.reference, c.record], AnalysisParams(),
      [vsReference: 0, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1])
    let (corr, ratio) = agree(r.curveOf("GF as recorded fundamental"),
      alone.curveOf("GF fundamental"))
    doAssert corr > 0.999999 and ratio < 1.000001, $(corr, ratio)
    # ... which is not the ground force (an equal-weight sum of two accelerations)
    let (far, _) = agree(r.curveOf("GF as recorded fundamental"), want, sized = false)
    doAssert far < 0.99, "the record's fourth trace was taken for the ground force: " & $far
  block made:
    p.roles.judge = joWeighted
    let r = ask(rows, p, at)
    doAssert r.judged == "GF (M, B)" and r.bothSignals
    let (corr, ratio) = agree(r.curveOf("GF from M and B fundamental"), want)
    doAssert corr > 0.999999, $corr
    doAssert ratio < 1.000001, "the size is not constant: " & $ratio
    # the weights the wrong way round make another signal
    var swapped = p
    swap(swapped.reactionMassKg, swapped.baseplateMassKg)
    let (bad, _) = agree(ask(rows, swapped, at).curveOf("GF from M and B fundamental"), want,
      sized = false)
    doAssert bad < 0.99, $bad
  block ownHundred:
    # the recorded ground force's 100 % force typed: the made signal has none of its own
    var q = p
    q.forceHundredPct = 5.0e7
    let none = ask(rows, q, at)
    doAssert none.qc.rows[ord(qlAvgForce)].status == qsNotJudged and
      none.qc.rows[ord(qlPeakForce)].status == qsNotJudged
    doAssert none.qc.forceNote.len > 0
    q.forceHundredWeighted = 1000.0
    let some = ask(rows, q, at)
    doAssert some.qc.rows[ord(qlPeakForce)].status != qsNotJudged
    q.roles.judge = joRecorded
    doAssert ask(rows, q, at).qc.rows[ord(qlPeakForce)].status != qsNotJudged

proc plainBlocks() =
  block noMasses:
    # a SEG-Y with the traces but no masses typed: the switch is offered, the window says why
    # nothing is made and judges the recorded ground force
    let c = converterOf()
    var p = AnalysisParams()
    p.roles.judge = joWeighted
    let r = ask(@[c.reference, c.record, c.mass, c.plate], p,
      [vsReference: 0, vsGroundForce: 1, vsMass: 2, vsBaseplate: 3])
    doAssert r.canMake and not r.bothSignals and r.judged == "GF"
    doAssert "masses" in r.judgeWarning, r.judgeWarning
    # no mass trace: not offered
    let none = ask(@[c.reference, c.record], p,
      [vsReference: 0, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1])
    doAssert not none.canMake and "no trace in the M or the B role" in none.judgeWarning,
      none.judgeWarning

proc sessionOf(st: AppState; path: string): int =
  result = -1
  for i, s in st.sessions:
    if s.path == path: result = i

proc settle(st: var AppState; w: int): bool =
  st.settle(st.plots[w].result.gen > 0 and not st.plots[w].waiting and
    (st.plots[w].result.plots.len > 0 or st.plots[w].result.problem.len > 0))

proc window(st: var AppState; path: string): int =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessionOf(path) >= 0 and st.panel(MainPanel).laidOut)
  st.apply Command(kind: ckOpenPlot, plotView: avVibrator,
    plotTraces: @[st.sessions[st.sessionOf(path)].base], plotParams: AnalysisParams())
  result = st.plots.high
  doAssert st.settle(result) and st.plots[result].result.problem.len == 0,
    st.plots[result].result.problem

proc change(st: var AppState; w: int; p: AnalysisParams) =
  let before = st.plots[w].result.gen
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p)
  doAssert st.settle(st.plots[w].result.gen > before and not st.plots[w].waiting and
    (st.plots[w].result.plots.len > 0 or st.plots[w].result.problem.len > 0))

proc signatureBlocks() =
  for kind in ["dat", "vib"]:
    withFixtures fx:
      var st = initAppState()
      let path = if kind == "dat": datFile(fx.dir, "a.dat") else: vibFile(fx.dir, "a.vib")
      let w = st.window(path)
      var p = st.plots[w].params
      let first = st.plots[w].result
      doAssert first.canMake and not first.bothSignals and first.judged == "GF", kind
      p.details = true
      # typed masses are never applied to a signature file
      (p.reactionMassKg, p.baseplateMassKg) = (3600.0, 1400.0)
      p.roles.judge = joWeighted
      st.change(w, p)
      let r = st.plots[w].result
      doAssert r.bothSignals and r.judged == "GF (M, B)", kind & ": " & r.judgeWarning
      doAssert "both choices give the same ground force" in r.madeNote, r.madeNote
      doAssert r.sameAsRecorded
      let (corr, ratio) = agree(r.curveOf("GF from M and B fundamental"),
        r.curveOf("GF as recorded fundamental"))
      doAssert corr > 0.999999 and ratio < 1.00001, kind & ": " & $(corr, ratio)
      # the choice is in the window's saved parameters
      doAssert st.plots[w].params.roles.judge == joWeighted
      # with the user's force scale the ground force is in newtons: the made one too, the same
      var settings = st.settings
      settings.forceScale = ForceScale(datCountsPerLbf: 8.0, vibAccMvPerCount: 12.5)
      st.apply Command(kind: ckSettings, settings: settings)
      p.details = false
      st.change(w, p)
      p.details = true
      st.change(w, p)
      let scaled = st.plots[w].result
      doAssert scaled.judgedAxis.endsWith("(N)"), scaled.judgedAxis
      # (the judged force may be drawn in % of a 100 % force the file gives: the table's raw
      # numbers are the same unit for both)
      doAssert abs(meanForce(scaled, "GF (M, B)") / meanForce(scaled, "GF") - 1) < 2e-3,
        kind & ": " & $scaled.table
      st.shutdown()

proc converterFileBlock() =
  withFixtures fx:
    var st = initAppState()
    let c = converterOf()
    let path = fx.dir / "converted.sgy"
    writeVibSegy(path, [c.reference, c.mass, c.plate, c.record], 1.0, [21'i16, 19, 18, 20])
    let w = st.window(path)
    doAssert st.vibConverter(st.plots[w])
    var p = st.plots[w].params
    # the roles by codes (the roles' own rule): M is the trace coded 18, the converter's
    # baseplate channel; the weights follow the roles, so the roles are swapped
    swap(p.roles.mass, p.roles.baseplate)
    (p.reactionMassKg, p.baseplateMassKg, p.details) = (Wm, Wb, true)
    p.roles.judge = joWeighted
    st.change(w, p)
    let r = st.plots[w].result
    doAssert r.judged == "GF (M, B)", r.judgeWarning
    let truth = ask(@[c.reference, c.truth], AnalysisParams(),
      [vsReference: 0, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1])
    let (corr, ratio) = agree(r.curveOf("GF from M and B fundamental"),
      truth.curveOf("GF fundamental"))
    doAssert corr > 0.999999 and ratio < 1.00001, $(corr, ratio)
    st.shutdown()

proc main*() =
  converterBlocks()
  plainBlocks()
  signatureBlocks()
  converterFileBlock()
  echo "tgfswitch: ok"

when isMainModule:
  main()
