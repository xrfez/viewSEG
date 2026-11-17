## The map in `core` and its view models, without a window: the view
## follows the survey (a map at fit fits each new layer, another view stays
## within the new bounds), back returns to the view before a gesture, a view
## sent past the survey is kept inside it, layers hide and show; points
## selected on the map select their traces (replace, add, toggle, remove),
## a trace selection made anew and Esc take them away; the highlight holds
## the points of the hovered trace and of the selection; the point nearest a
## place (and the others on its spot), the points in a box; what the map
## says of a point (station, coordinates, units, the traces and records it
## belongs to, the field records a relation file gives a source); and the
## words of lengths and coordinates.
##
## Seen to fail: with `followed` not called after the inbox is drained, the
## map's limits never took the first file's bounds; with `ckSelectPoints`
## selecting the points but not their traces, "a point's traces" found none
## selected; with `Survey.bounds` starting from a zeroed result, "the
## survey's bounds" were not empty with nothing loaded (and held (0, 0)).

import std/[math, strutils]
import viewSEG/core/state
import viewSEG/view/[maplayers, theme]
import utils/[fixtures, waiting]

func near(a, b: float64; eps = 1e-9): bool = abs(a - b) <= eps * max(1.0, abs(b))

proc layerOf(st: AppState; path: string): int =
  for i, l in st.survey.layers:
    if l.path == path: return i
  -1

proc main*() =

  block followsTheSurvey:
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      doAssert st.survey.bounds.isEmpty, "the survey's bounds: nothing loaded"
      st.apply Command(kind: ckLoadSurvey, paths: @[sps.s])
      doAssert st.settle(st.survey.layers.len == 1)
      let s = st.survey.layers[0].bounds
      doAssert st.survey.bounds == s, "the survey's bounds: " & $st.survey.bounds
      doAssert st.map.limits.bounds == s and not st.map.view.isSet # no frontend yet
      st.apply Command(kind: ckMapView, mapView: fitMap(st.map.limits, 400, 300))
      doAssert st.map.view.isSet and st.map.view.showsAll(st.map.limits)
      let jumps = st.map.jumps
      st.apply Command(kind: ckLoadSurvey, paths: @[sps.r])
      doAssert st.settle(st.survey.layers.len == 2)
      let both = st.survey.bounds
      let (rx, ry) = mapRcv(0, 0)
      doAssert both.minX == rx and both.minY == mapSrc(0, 0)[1] and both.maxY == mapRcv(2, 0)[1]
      doAssert st.map.limits.bounds == both
      doAssert st.map.jumps > jumps and st.map.view.showsAll(st.map.limits),
        "the second file refits the map"
      doAssert near(st.map.view.perPixel, st.map.limits.mostPerPixel(400, 300))
      # a gesture, then back
      let fit = st.map.view
      let close = zoomedMap(fit, 4, mapPoint(rx, ry), st.map.limits)
      st.apply Command(kind: ckMapView, mapView: close, mapRemember: true)
      doAssert st.map.view == close and st.map.back.len == 1
      st.apply Command(kind: ckMapBack)
      doAssert sameMapView(st.map.view, fit) and st.map.back.len == 0
      # a view sent far from the survey is kept within it
      var away = close
      away.centre = mapPoint(0, 0)
      st.apply Command(kind: ckMapView, mapView: away)
      let v = st.map.view.visible
      doAssert v.minX >= both.minX - MapMargin * close.perPixel - 1e-6 and v.minX < both.maxX, $v
      # a closer view stays within the bounds when a file goes
      st.apply Command(kind: ckMapView, mapView: close)
      st.apply Command(kind: ckUnloadSurvey, layer: st.survey.layers[st.layerOf(sps.r)].id)
      doAssert st.map.limits.bounds == s
      doAssert st.map.view == keptMap(close, mapLimits(s)), $st.map.view

  block layersHide:
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
      doAssert st.settle(st.survey.layers.len == 2)
      let ink = mapInk(EverforestDark, pcPaper)
      var layers = mapLayers(st, ink)
      doAssert layers.len == 3 and layers[^1].key == HighlightKey
      doAssert layers[0].role == prReceiver and layers[0].name == "Receivers of map.r" and
        layers[0].points == MapRcvLines.len * MapRcvPoints and layers[0].shape == msDisc
      doAssert layers[1].role == prSource and layers[1].points == MapSrcLines.len * MapSrcPoints
      doAssert layers[0].colour == ink.roles[prReceiver] and layers[1].colour == ink.roles[prSource]
      doAssert ink.roles[prSource] != ink.roles[prReceiver] and ink.selected != ink.roles[prReceiver]
      let (x, y) = mapRcv(1, 3)
      doAssert st.pointsAt(mapPoint(x + 1, y), 5).len == 1
      st.apply Command(kind: ckMapLayer, mapLayer: layers[0].key, shown: false)
      layers = mapLayers(st, ink)
      doAssert not layers[0].shown and layers[1].shown
      doAssert st.pointsAt(mapPoint(x + 1, y), 5).len == 0, "a hidden layer's point was found"
      st.apply Command(kind: ckMapLayer, mapLayer: layers[0].key, shown: true)
      doAssert mapLayers(st, ink)[0].shown
      # the points in a box: line 0's first five receivers, no source
      let (x0, y0) = mapRcv(0, 0)
      let (x4, _) = mapRcv(0, 4)
      let inBox = st.pointsIn(Bounds(minX: x0 - 1, minY: y0 - 1, maxX: x4 + 1, maxY: y0 + 1))
      doAssert inBox.len == 5
      for p in inBox: doAssert p.role == prReceiver
      # units, and what is said of a source
      doAssert st.unitsOf == "m"
      let src = st.pointsAt(mapPoint(mapSrc(1, 2)[0], mapSrc(1, 2)[1]), 1)
      let info = st.pointInfo(src[0], "m")
      doAssert info.title == "Source, line 3, point 1003", info.title
      doAssert info.lines[0] == "E 500362.5   N 6000075.0   Z 100.0 m", $info.lines
      doAssert info.lines[1] == "In map.s", $info.lines

  block selectingPoints:
    withFixtures fx:
      let sps = fx.surveySps()
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.surveySegy())
      st.apply Command(kind: ckLoadSurvey, paths: @[sps.r, sps.x])
      doAssert st.settle(st.survey.layers.len == 3 and st.sessions.len == 1)
      let traces = st.layerOf(fx.surveySegy())
      doAssert traces >= 0
      let tl = st.survey.layers[traces]
      # the receiver of channel 5: its traces layer point, and the R file's on the same spot
      let here = st.pointsAt(mapPoint(rcvX(5), OriginY), 1)
      doAssert here.len == 2 and here[0].layer != here[1].layer, $here
      var own: PointRef
      for p in here:
        if p.layer == tl.id: own = p
      doAssert own.role == prReceiver
      let five = st.survey.tracesAt(own)
      doAssert five.len == Shots, "a point's traces: " & $five
      st.apply Command(kind: ckSelectPoints, points: @[own], pointMode: smReplace)
      doAssert st.selection.points == @[own]
      doAssert st.selection.selected.len == Shots, "a point's traces: none selected"
      for t in five: doAssert t in st.selection.selected
      let six = st.pointsAt(mapPoint(rcvX(6), OriginY), 1)
      var other: PointRef
      for p in six:
        if p.layer == tl.id: other = p
      st.apply Command(kind: ckSelectPoints, points: @[other], pointMode: smAdd)
      doAssert st.selection.points.len == 2 and st.selection.selected.len == 2 * Shots
      st.apply Command(kind: ckSelectPoints, points: @[own], pointMode: smToggle)
      doAssert st.selection.points == @[other] and st.selection.selected.len == Shots
      for t in five: doAssert t notin st.selection.selected
      st.apply Command(kind: ckSelectPoints, points: @[own], pointMode: smToggle)
      doAssert st.selection.points.len == 2 and st.selection.selected.len == 2 * Shots
      st.apply Command(kind: ckSelectPoints, points: @[other], pointMode: smRemove)
      doAssert st.selection.points == @[own] and st.selection.selected.len == Shots
      # the highlight: the selected points, and the hovered trace's source and receiver
      st.apply Command(kind: ckHover, trace: five[1])
      let h = st.highlightOf
      doAssert own in h.selected
      var roles: set[PointRole]
      for p in h.hovered:
        doAssert p.layer == tl.id
        roles.incl p.role
      doAssert roles == {prSource, prReceiver}, $h.hovered
      doAssert near(st.positionOf(h.hovered[0]).y, OriginY)
      # what is said of the open file's receiver
      let info = st.pointInfo(own, st.unitsOf)
      doAssert info.title == "Receiver, no station", info.title # the file's keys have none
      doAssert info.lines[0] == "E " & formatFloat(rcvX(5), ffDecimal, 1) & "   N 6000000.0   " &
        "Z 100.0 m", $info.lines # metres: as the file's binary header says
      doAssert info.lines[1] == "In the traces of survey-clean.sgy", $info.lines
      doAssert info.lines[2] == "3 traces in 3 records: FFID 11, 12, 13", $info.lines
      # a selection made anew in the plot takes the points away; Esc takes all
      st.apply Command(kind: ckSelect, traces: @[five[0]], mode: smReplace)
      doAssert st.selection.points.len == 0 and st.selection.selected.len == 1
      st.apply Command(kind: ckSelectPoints, points: @[own], pointMode: smReplace)
      st.apply Command(kind: ckClearSelection)
      doAssert st.selection.points.len == 0 and st.selection.selected.len == 0

  block relationRecords:
    withFixtures fx:
      let sps = fx.surveySps()
      var st = initAppState()
      st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.x])
      doAssert st.settle(st.survey.layers.len == 2)
      let first = st.pointsAt(mapPoint(srcX(0), OriginY), 1)
      doAssert first.len == 1 and first[0].role == prSource
      let info = st.pointInfo(first[0], "")
      doAssert info.title == "Source, line 1, point 1001", info.title
      doAssert "Field record 11 in the relation file" in info.lines, $info.lines
      doAssert info.lines[0].endsWith("Z 100.0"), "no units to write: " & info.lines[0]

  block words:
    doAssert lengthText(500, "ft") == "500 ft"
    doAssert lengthText(1500, "m") == "1.50 km" and lengthText(2000, "m") == "2 km"
    doAssert lengthText(199.74, "m") == "199.7 m" and lengthText(2.5, "") == "2.50 units"
    doAssert coordinatesText(mapPoint(1833476.14, 417000.81), 37, "ft") == "E 1833476   N 417001 ft"
    doAssert coordinatesText(mapPoint(1.26, 2.5), 0.5, "") == "E 1.3   N 2.5  (units not given)"

  echo "tmapstate: ok"

when isMainModule:
  main()
