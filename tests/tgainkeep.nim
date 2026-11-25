## A signature file's first look (gain Normalized, overlap 0.45, no fills) is never what the
## settings remember: a display change made there keeps only what the user changed.
import std/os
import viewSEG/core/[panels, persist, settings, state]
import utils/[fixtures, sigfiles, waiting]

proc shown(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  var at = -1
  doAssert st.settle((at = -1; (for i, s in st.sessions: (if s.path == path: at = i)); at >= 0) and
    st.panel(MainPanel).laidOut and st.shownFile(st.findPanel(MainPanel)) == at), path

proc change(st: var AppState; d: DisplaySettings) =
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d, origin: coWindow)
  discard st.settle(true)

proc main*() =
  withFixtures fx:
    var st = initAppState()
    let dir = fx.dir / "cfg"
    createDir(dir)
    st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
    let seis = fx.surveySegy()
    let sig = datFile(fx.dir, "a.dat")
    st.shown(seis)
    let user = st.settings.plot.display
    doAssert user.gain == dgAuto
    st.shown(sig)
    var d = st.panel(MainPanel).layers[0].display
    doAssert d.gain == dgNormalized and d.overlap == 0.45 and d.fills == {}
    d.gainDb += 3
    st.change d
    var want = user
    want.gainDb += 3
    let s = st.settings.plot.display
    doAssert s.gain == dgAuto and s.overlap == 1.0 and s.fills == {wfPositive}, "the look leaked"
    doAssert s.gainDb == want.gainDb
    st.shown(seis)
    let q = st.panel(MainPanel).layers[0].display
    doAssert q.gain == dgAuto and q.overlap == 1.0 and q.fills == {wfPositive}, $q.gain
    # a gain picked on a signature file is the user's
    st.shown(sig)
    d = st.panel(MainPanel).layers[0].display
    d.gain = dgNone
    st.change d
    doAssert st.settings.plot.display.gain == dgNone
    doAssert st.settings.plot.display.overlap == 1.0, "the overlap leaked"
    st.shutdown()
    let again = loadSettings(dir / "settings.nif").settings.plot.display
    doAssert again.gain == dgNone and again.overlap == 1.0 and again.fills == {wfPositive}
  echo "tgainkeep: ok"

when isMainModule:
  main()
