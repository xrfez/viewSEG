## Windows are named for what they show: a panel of seismic traces is
## "Seismic", of auxiliary traces "Aux", of both "Seismic + Aux", of spectra
## "FFT", of an f-k plot "F-K"; a second window of a name is numbered from 2,
## and a panel names itself again when its filter changes. A panel with no
## layer yet is named for the filter a new layer gets (seismic).
##
## Seen to fail: with `windowTitle` numbering every panel (not those of one
## name), "Aux" came out "Aux 2"; with `contentName` reading a fixed string,
## the auxiliary panel was "Seismic".

import viewSEG/core/state

func traces(id: int; seismic = true; auxiliary = false): Panel =
  var layer = recordLayer(NoSession, 0)
  layer.filter = TraceFilter(seismic: seismic, auxiliary: auxiliary)
  Panel(id: PanelId(id), layers: @[layer])

block names:
  doAssert contentName(Panel(id: PanelId(1))) == "Seismic", "an empty panel"
  doAssert contentName(traces(1)) == "Seismic"
  doAssert contentName(traces(1, seismic = false, auxiliary = true)) == "Aux"
  doAssert contentName(traces(1, auxiliary = true)) == "Seismic + Aux"
  doAssert contentName(traces(1, seismic = false)) == "Traces"
  doAssert contentName(Panel(id: PanelId(1), shows: psSpectrum)) == "FFT"
  doAssert contentName(Panel(id: PanelId(1), shows: psFk)) == "F-K"

block numbered:
  let panels = @[traces(1), traces(2, seismic = false, auxiliary = true), traces(3),
    Panel(id: PanelId(4), shows: psSpectrum), traces(5), Panel(id: PanelId(6), shows: psSpectrum)]
  var titles: seq[string]
  for k in 0 ..< panels.len: titles.add windowTitle(panels, k)
  doAssert titles == @["Seismic", "Aux", "Seismic 2", "FFT", "Seismic 3", "FFT 2"], $titles

block reused:
  # The same panel names itself for what it shows now.
  var panels = @[traces(1), traces(2)]
  doAssert windowTitle(panels, 1) == "Seismic 2"
  panels[1].layers[0].filter = TraceFilter(seismic: false, auxiliary: true)
  doAssert windowTitle(panels, 1) == "Aux"

block appState:
  var st = initAppState()
  doAssert st.windowTitle(MainPanel) == "Seismic"
  st.shutdown()
