## Linked highlighting in `core` and its view models, without a window:
## every command that links the plot and the map, on positions from the
## file's own headers, from survey files matched by the headers' stations,
## and from a relation file matched by record and channel:
##
## - `ckHover`: the trace under the plot's pointer comes with its source and
##   receiver points (`hoverAt`), in every layer; a trace with no place on
##   the map, or one role without, says why (`hoverNote`);
## - `ckHoverPoints`: the points under the map's pointer come with the
##   traces recorded there (`hoverTraces`); a point with none, or with
##   traces only in other records, says why;
## - `ckShowPoints`: a source's record shown in the main panel (and nothing
##   when it is on show already);
## - `ckSelectPoints` with a range: the stations along the line from the
##   point clicked last, which stays the anchor;
## - the gather on show's points (`activePoints`), what a click on a point
##   does (`opensRecord`) and the stations `M` selects (`stationsOf`);
## - no hover reads a tile, makes the survey's layers again or asks for a
##   new view; a closed file or an unloaded survey file leaves no hover.
##
## Seen to fail: with `ckHoverPoints` keeping the points but not their
## traces, "the hovered receiver's traces" found none; with `ckHover`
## finding the points from the traces layer only (no keys, so no relation
## file), "matched through the relation file" found no R-file receiver; with
## the range's anchor moved to its first point, "the anchor stays" found the
## second range from 103 to 109.

import std/[algorithm, math, sequtils, strutils]
import viewSEG/core/state
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc layerOf(st: AppState; path: string): int =
  for i, l in st.survey.layers:
    if l.path == path: return i
  -1

proc look(st: var AppState) =
  ## The whole gather on a plot of 800 × 600 pixels: a tile comes.
  let p = st.panel(MainPanel)
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(p.layout, 800, 600))

proc stationAt(st: AppState; path: string; r: PointRole; line, point: float64): PointRef =
  ## Survey file `path`'s point of station `line`/`point`.
  let i = st.layerOf(path)
  doAssert i >= 0, path & " is not loaded"
  let p = st.survey.layers[i].stationPoint(r, Station(line: line, point: point, index: 1))
  doAssert p >= 0, "no station " & $line & "/" & $point & " in " & path
  PointRef(layer: st.survey.layers[i].id, role: r, point: p)

proc ownAt(st: AppState; path: string; r: PointRole; x, y: float64): PointRef =
  ## The open file `path`'s own point of role `r` at (`x`, `y`).
  let i = st.layerOf(path)
  doAssert i >= 0 and st.survey.layers[i].origin == loTraces
  let q = st.survey.layers[i].points[r].index.nearest(x, y, 0.5)
  doAssert q >= 0, "no own " & $r & " at " & $x & ", " & $y
  PointRef(layer: st.survey.layers[i].id, role: r, point: q)

func ids(s: IntSet): seq[int] =
  for t in s: result.add t
  result.sort()

func near(a, b: float64): bool = abs(a - b) <= 1e-6 * max(1.0, abs(b))

proc lastText(log: MessageLog): string = log[log.len - 1].text

block fromTheHeaders:
  # The SEG-Y survey: coordinates in every trace header, no stations.
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.layerOf(path) >= 0 and
      st.panel(MainPanel).laidOut)
    st.look()
    let k = st.findPanel(MainPanel)
    doAssert st.settle(st.tiles(k).len > 0)
    let base = st.sessions[0].base
    let taken = st.tilesTaken
    let gen = st.panel(MainPanel).requestGen
    let surveyRev = st.survey.revision
    # the trace under the plot's pointer: its own source and receiver
    st.apply Command(kind: ckHover, trace: base + 4)
    var roles: set[PointRole]
    for p in st.selection.hoverAt:
      roles.incl p.role
      let at = st.positionOf(p)
      if p.role == prReceiver: doAssert near(at.x, rcvX(5)) and near(at.y, OriginY), $at
      else: doAssert near(at.x, srcX(0)), $at
    doAssert roles == {prSource, prReceiver} and st.selection.hoverAt.len == 2,
      $st.selection.hoverAt
    doAssert st.hoverNote == "", st.hoverNote
    let h = st.highlightOf
    doAssert h.hovered == st.selection.hoverAt, "the map lights up what core found"
    st.apply Command(kind: ckHover, trace: -1)
    doAssert st.selection.hoverAt.len == 0 and st.hoverNote == ""
    # the map's pointer on the file's own receiver of channel 5: the traces
    # of all three shots recorded there
    let rcv5 = st.ownAt(path, prReceiver, rcvX(5), OriginY)
    let lit = st.selection.hoveredRevision
    st.apply Command(kind: ckHoverPoints, points: @[rcv5])
    doAssert st.selection.hoverPoints == @[rcv5]
    doAssert ids(st.selection.hoverTraces) == @[base + 4, base + Channels + 4,
      base + 2 * Channels + 4], "the hovered receiver's traces: " & $ids(st.selection.hoverTraces)
    doAssert st.selection.hoveredRevision == lit + 1
    doAssert st.hoverNote == "", st.hoverNote
    # the source of shot 1, whose traces are all in another record
    let src1 = st.ownAt(path, prSource, srcX(1), OriginY)
    st.apply Command(kind: ckHoverPoints, points: @[src1])
    doAssert st.selection.hoverTraces.len == Channels
    doAssert st.hoverNote == "24 traces recorded at this source, none in the record shown " &
      "(FFID 12).", st.hoverNote
    st.apply Command(kind: ckHoverPoints, points: @[])
    doAssert st.selection.hoverPoints.len == 0 and st.selection.hoverTraces.len == 0
    doAssert st.hoverNote == ""
    # none of it read anything, asked for a view or made a layer again
    discard st.drainInbox()
    doAssert st.tilesTaken == taken and st.panel(MainPanel).requestGen == gen and
      st.survey.revision == surveyRev, "a hover read or rebuilt something"
    # the gather on show's points: shot 0's source and its 24 receivers
    var active = st.activePoints
    doAssert active[prSource].len == 1 and active[prReceiver].len == Channels,
      $active[prSource].len & " " & $active[prReceiver].len
    doAssert near(st.positionOf(active[prSource][0]).x, srcX(0))
    # a click on a source shows its record, once
    doAssert st.opensRecord(src1) and not st.opensRecord(rcv5)
    st.apply Command(kind: ckShowPoints, points: @[src1])
    doAssert st.panel(MainPanel).layers[0].source.gather == 1
    doAssert st.selection.activeGather.gather == 1
    let shownGen = st.panel(MainPanel).requestGen
    st.apply Command(kind: ckShowPoints, points: @[src1])
    doAssert st.panel(MainPanel).requestGen == shownGen, "a record on show was shown again"
    active = st.activePoints
    doAssert near(st.positionOf(active[prSource][0]).x, srcX(1))
    # a point no trace was recorded at shows nothing, and says so
    let warnings = st.log.count(sevWarning)
    st.apply Command(kind: ckShowPoints, points: @[])
    doAssert st.log.count(sevWarning) == warnings + 1 and
      st.log.lastText.contains("no trace of the open files"), st.log.lastText
    # `M`: the hovered trace's receiver
    st.apply Command(kind: ckHover, trace: base + Channels + 6)
    let stations = st.stationsOf(@[base + Channels + 6], st.stationRole(k))
    doAssert stations.len == 1 and stations[0].role == prReceiver and
      near(st.positionOf(stations[0]).x, rcvX(7)), $stations
    st.apply Command(kind: ckSelectPoints, points: stations, pointMode: smReplace)
    doAssert st.selection.points == stations and st.selection.selected.len == Shots

block stationsOnly:
  # A record whose headers name stations, but give no coordinates, with
  # the survey's S and R files: linked both ways by line and station.
  withFixtures fx:
    let path = fx.stationsSegd()
    let sps = fx.surveySps()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
    doAssert st.settle(st.sessions.len == 1 and st.survey.layers.len == 3 and
      st.panel(MainPanel).laidOut)
    st.look()
    let k = st.findPanel(MainPanel)
    doAssert st.settle(st.tiles(k).len > 0)
    let own = st.layerOf(path)
    doAssert st.survey.layers[own].points[prReceiver].len == 0, "the record has coordinates"
    let base = st.sessions[0].base
    # trace 5: line 100, point 105, lit up at the R file's receiver
    st.apply Command(kind: ckHover, trace: base + 5)
    let rcv105 = st.stationAt(sps.r, prReceiver, RcvLine, 105)
    let src = st.stationAt(sps.s, prSource, SrcLine, FirstSrcPoint)
    doAssert st.selection.hoverAt.sortedByIt(it.key) == @[src, rcv105].sortedByIt(it.key),
      $st.selection.hoverAt
    doAssert near(st.positionOf(rcv105).x, rcvX(5))
    doAssert st.hoverNote == "", st.hoverNote
    # the time break has no place on the map
    st.apply Command(kind: ckHover, trace: base)
    doAssert st.selection.hoverAt.len == 0
    doAssert st.hoverNote == "Trace 1 is an auxiliary trace: it has no place on the map.",
      st.hoverNote
    # line 101 is in no survey file: its source is lit, its receiver not
    st.apply Command(kind: ckHover, trace: base + 12 + 5)
    doAssert st.selection.hoverAt == @[src], $st.selection.hoverAt
    doAssert st.hoverNote == "Trace 18's receiver is not on the map: no loaded survey file " &
      "has its receiver station (line 101, point 105).", st.hoverNote
    st.apply Command(kind: ckHover, trace: -1)
    # the map's pointer on the R file's receiver 107: the record's trace 7
    let rcv107 = st.stationAt(sps.r, prReceiver, RcvLine, 107)
    st.apply Command(kind: ckHoverPoints, points: @[rcv107])
    doAssert ids(st.selection.hoverTraces) == @[base + 7], $ids(st.selection.hoverTraces)
    doAssert st.hoverNote == ""
    # receiver 120 is in the R file, but not in the record
    let rcv120 = st.stationAt(sps.r, prReceiver, RcvLine, 120)
    st.apply Command(kind: ckHoverPoints, points: @[rcv120])
    doAssert st.selection.hoverTraces.len == 0
    doAssert st.hoverNote == "No trace of the open files was recorded at this receiver.",
      st.hoverNote
    # a click on the receiver selects its trace; on the source, shows its record
    st.apply Command(kind: ckSelectPoints, points: @[rcv107], pointMode: smReplace)
    doAssert ids(st.selection.selected) == @[base + 7]
    doAssert st.opensRecord(src) and not st.opensRecord(rcv107) and not st.opensRecord(rcv120)
    let src2 = st.stationAt(sps.s, prSource, SrcLine, FirstSrcPoint + 1)
    doAssert not st.opensRecord(src2), "a source with no traces opens a record"
    # the gather on show: its source and the 12 receivers of line 100
    let active = st.activePoints
    doAssert active[prSource] == @[src], $active[prSource]
    doAssert active[prReceiver].len == SegdChannels, $active[prReceiver].len
    for p in active[prReceiver]: doAssert p.layer == rcv107.layer
    # `M` on trace 7: the R file's receiver 107
    st.apply Command(kind: ckHover, trace: base + 7)
    doAssert st.stationsOf(@[base + 7], st.stationRole(k)) == @[rcv107]
    # a range along the line: from 107 to 103, then from 107 again to 109
    proc pointsSelected(st: AppState): seq[float64] =
      for p in st.selection.points:
        result.add st.survey.layers[st.survey.find(p.layer)].points[prReceiver].station[
          p.point].point
    st.apply Command(kind: ckSelectPoints, points: @[rcv107], pointMode: smReplace)
    st.apply Command(kind: ckSelectPoints, points: @[st.stationAt(sps.r, prReceiver, RcvLine,
      103)], pointMode: smRange)
    doAssert st.pointsSelected == @[103.0, 104, 105, 106, 107], $st.pointsSelected
    doAssert ids(st.selection.selected) == @[base + 3, base + 4, base + 5, base + 6, base + 7]
    st.apply Command(kind: ckSelectPoints, points: @[st.stationAt(sps.r, prReceiver, RcvLine,
      109)], pointMode: smRange)
    doAssert st.pointsSelected == @[107.0, 108, 109], "the anchor stays: " & $st.pointsSelected
    # a range to a point of another layer is that point alone
    st.apply Command(kind: ckSelectPoints, points: @[src], pointMode: smRange)
    doAssert st.selection.points == @[src]

block matchedThroughTheRelationFile:
  # The SEG-Y survey, whose headers give a record and a channel but no
  # stations, with S, R and X: the trace finds the survey files' points
  # through the relation file; the other way needs the join.
  withFixtures fx:
    let path = fx.surveySegy()
    let sps = fx.surveySps()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r, sps.x])
    doAssert st.settle(st.sessions.len == 1 and st.survey.layers.len == 4 and
      st.panel(MainPanel).laidOut)
    st.look()
    doAssert st.settle(st.tiles(st.findPanel(MainPanel)).len > 0)
    let base = st.sessions[0].base
    st.apply Command(kind: ckHover, trace: base + 4) # record 11, channel 5
    let rcv105 = st.stationAt(sps.r, prReceiver, RcvLine, 105)
    let src = st.stationAt(sps.s, prSource, SrcLine, FirstSrcPoint)
    doAssert rcv105 in st.selection.hoverAt and src in st.selection.hoverAt,
      "matched through the relation file: " & $st.selection.hoverAt
    doAssert st.selection.hoverAt.len == 4, $st.selection.hoverAt # and its own two
    # the gather on show: the stations the relation file plans for record 11
    let active = st.activePoints
    doAssert src in active[prSource] and rcv105 in active[prReceiver]
    doAssert active[prReceiver].len == 2 * Channels, $active[prReceiver].len # own and R file's
    # not without the join: the R file's receiver finds no trace
    st.apply Command(kind: ckHover, trace: -1)
    st.apply Command(kind: ckHoverPoints, points: @[rcv105])
    doAssert st.selection.hoverTraces.len == 0
    doAssert st.hoverNote == "No trace is matched to this receiver: the open files' headers " &
      "give no receiver stations.", st.hoverNote
    # but the file's own receiver on the same spot does
    let own = st.ownAt(path, prReceiver, rcvX(5), OriginY)
    st.apply Command(kind: ckHoverPoints, points: @[rcv105, own])
    doAssert st.selection.hoverTraces.len == Shots and st.hoverNote == ""

block nothingOpen:
  withFixtures fx:
    let sps = fx.surveySps()
    var st = initAppState()
    st.apply Command(kind: ckLoadSurvey, paths: @[sps.r])
    doAssert st.settle(st.survey.layers.len == 1)
    let rcv = st.stationAt(sps.r, prReceiver, RcvLine, 101)
    st.apply Command(kind: ckHoverPoints, points: @[rcv])
    doAssert st.selection.hoverPoints == @[rcv] and st.selection.hoverTraces.len == 0
    doAssert st.hoverNote == "No trace here: no seismic file is open.", st.hoverNote
    doAssert not st.opensRecord(rcv)
    # the layer goes: so does the hover
    st.apply Command(kind: ckUnloadSurvey, layer: st.survey.layers[0].id)
    doAssert st.selection.hoverPoints.len == 0 and st.hoverNote == ""

block closingLeavesNoHover:
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.layerOf(path) >= 0)
    let rcv = st.ownAt(path, prReceiver, rcvX(2), OriginY)
    st.apply Command(kind: ckHoverPoints, points: @[rcv])
    doAssert st.selection.hoverTraces.len == Shots
    st.apply Command(kind: ckHover, trace: st.sessions[0].base + 1)
    doAssert st.selection.hoverAt.len == 2
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.selection.hoverTraces.len == 0 and st.selection.hover == -1 and
      st.selection.hoverAt.len == 0
    doAssert st.selection.hoverPoints.len == 0, "the closed file's point is still hovered"

echo "tlinking: ok"
