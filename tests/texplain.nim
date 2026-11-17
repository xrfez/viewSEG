## What each plot tells you (`core/explain`), the words of every plot's Explain (right-click):
##
## - every kind of plot has words, in the four parts, none alike: a plot
##   added to `PlotKind` cannot be without them (the `case` is exhaustive),
##   and one with an empty text fails here (as `tshortcuts` does for keys);
## - every analysis view names its plots, and the panes of real results (an
##   envelope, a phase spectrum, a correlation, a vibrator signature on
##   samples/vib) are the kinds the view lists, in order;
## - the words follow the settings they name: the filters on and off, the
##   reference, the units, the picture of the phase, the scale, the display;
## - the user guide's page is these words (`tools/plotspage.nim check`);
## - every file of the toolkit's side that draws a plot has Explain in its menu;
## - the agents' `state` carries the same words, `explain`, for the plot
##   windows and the spectrum windows.
##
## Seen to fail: with the vibrator's force pane named as the force from M and
## B, "pane 1 of the vibrator signature is Vibrator signature: force from M and
## B, not Vibrator signature: force"; with the filters left out of
## `filterClause`, "the filters are not named"; with `plotJson` not adding
## "explain", the key "explain" not found in the state. With the page's first
## section dropped, "docs/user/plots.md is not the explanations' page"; with a
## file that draws a plot and no `explainMenu(`, "... draws a plot and no
## Explain".

import std/[json, os, sets, strutils]
import parseSEG
import viewSEG/core/[analysis, explain, phasepicture, state, units, vibanalysis]
import viewSEG/remote/tools
import ../tools/plotspage
import utils/[fixtures, waiting]

const
  root = currentSourcePath().parentDir.parentDir
  imguiDir = root / "src" / "viewSEG" / "ui" / "imgui"

proc has(text, part: string): bool = part in text

proc windowOf(view: AnalysisView; r: AnalysisResult): AnalysisWindow =
  AnalysisWindow(id: 1, view: view, result: r)

proc main*() =
  block every_kind_has_words_in_four_parts:
    var seen = initHashSet[string]()
    for kind in PlotKind:
      let text = explain(kind)
      doAssert text.len > 200, $kind & " has no words: \"" & text & "\""
      for label in ["Shows: ", "Computed from: ", "Reading it: "]:
        doAssert label in text, $kind & " has no \"" & label & "\" part"
      doAssert text notin seen, $kind & "'s words are another plot's"
      seen.incl text
      doAssert explain(kind, ExplainFacts(live: true)).len > 200, $kind & " live"

  block every_analysis_view_names_its_plots:
    for v in AnalysisView:
      doAssert v.viewKinds.len > 0, $v & " has no plot kind"
      for k in v.viewKinds:
        doAssert kindOfPane(v, "") in v.viewKinds
        doAssert explain(k).len > 0
    doAssert kindsOfSpectrum().len == 2

  block the_panes_of_real_results_are_the_kinds_of_their_views:
    let dt = 2.0
    var x = newSeq[float32](1000)
    for i in 0 ..< x.len: x[i] = float32(sin(float64(i) * 0.1) * exp(-float64(i) / 400))
    let params = AnalysisParams()
    let env = windowOf(avEnvelope, envelopeOf(x, "trace 1", dt, 0))
    let phase = windowOf(avPhase, phaseOf(x, "trace 1", dt, params))
    let corr = windowOf(avCorrelation, correlationOf([("trace 1", x)], x, "the reference", dt,
      params))
    let spec = windowOf(avSpectrogram, spectrogramOf([x], dt, 0, params))
    for w in [env, phase, corr, spec]:
      doAssert w.result.problem.len == 0, w.result.problem
      let want = w.view.viewKinds
      if w.view == avSpectrogram:
        doAssert w.paneKind(0) == pkSpectrogram
      else:
        doAssert w.result.plots.len == want.len, $w.view & " has " & $w.result.plots.len &
          " panes, its kinds are " & $want.len
        for i in 0 ..< want.len:
          doAssert w.paneKind(i) == want[i], "pane " & $i & " of the " & $w.view & " is " &
            $w.paneKind(i) & ", not " & $want[i]
    var rows: seq[seq[float32]] = @[]
    let sgd = root / "samples" / "vib" / "vib_signature.sgd"
    doAssert fileExists(sgd)
    var f = openSeismic(sgd, keys = true)
    for c in 0 ..< 4:
      let t = f.readTraces(c .. c)
      var r = newSeq[float32](t.shape[1])
      for j in 0 ..< r.len: r[j] = t[0, j]
      rows.add r
    f.close()
    var vp = AnalysisParams(reactionMassKg: 3600, baseplateMassKg: 1800, limitsOn: true)
    let vib = vibratorOf(rows, ["R", "GF", "M", "B"], [vsReference: 0, vsGroundForce: 1,
      vsMass: 2, vsBaseplate: 3], 4.0, vp)
    doAssert vib.problem.len == 0, vib.problem
    var w = windowOf(avVibrator, vib)
    w.params = vp
    doAssert w.result.plots.len == avVibrator.viewKinds.len
    for i, kind in avVibrator.viewKinds:
      doAssert w.paneKind(i) == kind, "pane " & $i & " of the vibrator signature is " &
        $w.paneKind(i) & ", not " & $kind
    # the units setting reaches the force axis and the masses
    let metric = w.explainPane(usMetric, 2)
    let imperial = w.explainPane(usImperial, 2)
    doAssert "3600 kg" in metric and "kg" in metric, metric
    doAssert "lb" in imperial and "3600 kg" notin imperial, imperial
    doAssert metric != imperial
    doAssert "Limits are on" in w.explainPane(usMetric, 0), w.explainPane(usMetric, 0)
    w.params.limitsOn = false
    doAssert "Limits are off" in w.explainPane(usMetric, 0)

  block the_words_follow_the_settings:
    var f = ExplainFacts(live: true, label: "trace 12 · FFID 151 · shot.sgd", count: 1)
    let plain = explain(pkSpectrum, f)
    doAssert "As recorded: no filter is on" in plain and "No trace is reversed" in plain, plain
    doAssert "trace 12 · FFID 151 · shot.sgd" in plain
    f.filters = "10-60 Hz"
    doAssert "After your filters (10-60 Hz)" in explain(pkSpectrum, f), "the filters are not named"
    f.own = "Trace 12: own filter, band-pass 10-60 Hz"
    f.reversal = "Trace 12: reversed"
    let edited = explain(pkSpectrum, f)
    doAssert "Trace 12: own filter, band-pass 10-60 Hz." in edited and
      "Trace 12: reversed." in edited, edited
    f.skipped = "the auxiliary trace is not filtered"
    doAssert "The auxiliary trace is not filtered." in explain(pkSpectrum, f)
    # the scale and the curves
    f.db = false
    doAssert "sample units" in explain(pkSpectrum, f) and "dB, 0 dB" notin explain(pkSpectrum, f)
    f.db = true
    f.curves = {scRaw, scProcessed, scResponse}
    doAssert "faint response" in explain(pkSpectrum, f)
    f.logFrequency = true
    doAssert "logarithmic" in explain(pkSpectrum, f)
    f.binHz = 0.5
    doAssert "frequency step is 0.5 Hz" in explain(pkSpectrum, f)
    f.wholeTrace = false
    (f.fromMs, f.toMs) = (100.0, 900.0)
    doAssert "100 to 900 ms" in explain(pkSpectrum, f)
    # the phase's picture
    for p in PhasePicture:
      f.picture = p
      doAssert PhaseMeaning[p] in explain(pkSpectrumPhase, f), $p
      doAssert PhaseMeaning[p] in explain(pkPhase, f), $p
    # the reference
    f = ExplainFacts(live: true, reference: "chirp 8-80 Hz (FFID 1)", lagMs: 120)
    let against = explain(pkCorrelation, f)
    doAssert "Against the reference chirp 8-80 Hz (FFID 1)" in against and
      "±120 ms" in against, against
    f.reference = ""
    doAssert "No reference is chosen" in explain(pkCorrelation, f)
    f.withinDb = 25
    doAssert "within 25 dB" in explain(pkCorrelationRatio, f)
    # the spectrogram's frames
    f = ExplainFacts(live: true, windowMs: 64, overlap: 50, floorDb: -90, count: 3)
    let sg = explain(pkSpectrogram, f)
    doAssert "64 ms frames" in sg and "50 %" in sg and "-90 dB" in sg and "31.25 Hz" in sg and
      "power average" in sg, sg
    # the f-k's box and units
    f = ExplainFacts(live: true, fkFromMs: 200, fkToMs: 1200, fkRaw: true,
      wavenumber: "cycles /km", velocity: "m/s")
    let fk = explain(pkFk, f)
    doAssert "from 200 to 1200 ms" in fk and "left out" in fk and "(m/s)" in fk and
      "cycles /km" in fk, fk
    # the Seismic plot: the display
    f = ExplainFacts(live: true, mode: dmDensity, colourMap: cmViridis, gain: "AGC 500 ms",
      timeDown: false, order: "FFID, then trace", allReversed: true)
    let seis = explain(pkSeismic, f)
    doAssert "One column of colour per trace" in seis and "iridis" in seis and
      "Display gain: AGC 500 ms" in seis and "Time runs across" in seis and
      "FFID, then trace" in seis and "Every trace is reversed" in seis, seis
    doAssert "One wiggle per trace" in explain(pkSeismic, ExplainFacts(live: true))
    # the map's units and the header graph's column
    let map = explain(pkMap, ExplainFacts(live: true, coordinates: "ftUS", lengths: "m",
      marks: @["clipped", "noisy"], hiddenGroups: @["Preplot"]))
    doAssert "Coordinates are in ftUS" in map and "ruler read in m" in map and
      "Marked now: clipped, noisy" in map and "Hidden: Preplot" in map, map
    doAssert "\"Receiver point\"" in explain(pkHeaderGraph, ExplainFacts(live: true,
      column: "Receiver point", scope: "the record shown"))
    # a sweep, a stored reference, a pair of traces
    let g = explain(pkGenerateSignal, ExplainFacts(live: true,
      subject: "a linear sweep from 8 to 80 Hz over 10000 ms", options: "Tapers: 200 ms."))
    doAssert "a linear sweep from 8 to 80 Hz over 10000 ms" in g and "Tapers: 200 ms" in g, g
    doAssert "the reference chirp" in explain(pkReferenceSignal, ExplainFacts(live: true,
      subject: "the reference chirp"))
    doAssert "A: shots.sgy, trace 1" in explain(pkCompareSignal, ExplainFacts(live: true,
      subject: "A: shots.sgy, trace 1; B: shots.sgy, trace 2", options: "Alignment of B: x."))

  block the_guide_is_these_words:
    doAssert checkPage().len == 0, $checkPage()
    let page = explainPage()
    for kind in PlotKind:
      doAssert ("\n## " & $kind & "\n") in page, "the page has no section for " & $kind
      for line in explain(kind).splitLines:
        if line.len == 0: continue
        doAssert line[line.find(": ") + 2 .. ^1] in page, "the page lacks a line of " & $kind

  block every_file_that_draws_a_plot_draws_its_icon:
    var drawing = 0
    for path in walkFiles(imguiDir / "*.nim"):
      let text = readFile(path)
      if "ImPlot_BeginPlot(" in text or "drawCurvePlot(" in text:
        if path.extractFilename == "curveplot.nim": continue # the plot's own, which says its area
        inc drawing
        doAssert "explainMenu(" in text or "explainShow(" in text,
          path.extractFilename & " draws a plot and no Explain in its right-click menu"
    doAssert drawing >= 7, "only " & $drawing & " files draw plots: the source check is blind"

  block the_agents_state_says_it:
    let land = root / "samples" / "land" / "shots.sgy"
    doAssert fileExists(land)
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[land])
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      st.apply Command(kind: ckSelect, traces: @[base, base + 1], mode: smReplace)
      st.apply Command(kind: ckOpenPlot, plotView: avEnvelope)
      st.apply Command(kind: ckOpenPlot, plotView: avSpectrogram)
      st.apply Command(kind: ckSpectrum, spectrumTraces: @[base], spectrumOf: MainPanel)
      doAssert st.settle(st.plots.len == 2 and not st.plots[0].waiting and
        not st.plots[1].waiting and st.spectra.len >= 2 and not st.spectra[1].waiting)
      let report = parseJson(parseJson(st.stateReport(Frontend(),
        """{"parts":["plots","spectra"]}"""))["content"][0]["text"].getStr)
      let plots = report["plots"]
      doAssert plots.len == 2
      for i in 0 ..< plots.len:
        let p = plots[i]
        doAssert p["explain"].getStr == st.explainWindow(st.plots[i]), "state has no " &
          "explain for the plot window"
        for j in 0 ..< p["plots"].len:
          doAssert p["plots"][j]["explain"].getStr == st.explainPane(st.plots[i], j)
      doAssert plots[0]["plots"].len == 3
      doAssert "Instantaneous phase" in plots[0]["explain"].getStr or
        $pkInstPhase in plots[0]["explain"].getStr
      for i in 0 ..< report["spectra"].len:
        let text = report["spectra"][i]["explain"].getStr
        doAssert text.startsWith("Shows: "), text
        doAssert text == st.explainSpectrum(st.spectra[i], false) or
          text.startsWith(st.explainSpectrum(st.spectra[i], false)), "spectrum " & $i
      discard st.shutdown()

  echo "texplain: ok"

when isMainModule: main()
