## What each option of the map window says about itself: one table for the
## filters and the layers that both the window's tooltips and the agent's
## `state` read, so the two cannot differ. An `OptionDoc` is one option: its
## label as the window shows it, what it does, its value now, whether it can be
## used now, and how an agent changes it (or why it cannot).
##
## The window draws a tooltip from `filterTip` and `layerTip`; `filterDocs`
## and `layerDocs` give the same sentences, with the state, to the agent.

import std/strutils
import mapkinds, mapstate, state, survey

type
  OptionDoc* = object
    ## One option of a window, described for the window's tooltip and for the agent.
    id*: string      ## stable, lower case, dotted: "map.filter.dead", "map.layer.highlight"
    label*: string   ## as the window shows it
    explain*: string ## what it does, in the tooltip's words
    unit*: string    ## "" when it has none
    value*: string   ## now, as text: "on", "off", a number
    available*: bool ## it can be used now
    whyNot*: string  ## when it cannot: the reason the window shows
    change*: string
      ## how an agent changes it: the `command` kind and its arguments, as
      ## docs/agent-control.md spells them; "" when none is offered
    refused*: string ## when `change` is "": why no command is offered

const ClearCase = "A station marked both by a first-break filter and by \"header position" &
  " disagrees with the survey\" is the clear case for \"Move this station...\" in the" &
  " station-move menu"
  ## what the position filter's and the first-break filters' tips end with

const filterTips: array[MapFilter, string] = [
  "Traces the file marks dead in their headers",
  "Traces whose samples could not be decoded",
  "Traces you killed (the plot's menu, K)",
  "Traces outside the exclusion area (near the source) whose RMS is far above the others'" &
    " (robust z over 3.5)",
  "Traces with runs of samples at their maximum: a recorder or a conversion that saturated",
  "Traces with samples far above their neighbours (spikes)",
  "Traces whose every sample is the same value, not zero",
  "Traces whose RMS is far below the others' (robust z under -3.5), judged against the traces" &
    " outside the exclusion area",
  "Traces whose mean is large against their deviation",
  "Traces whose every sample is 0, whatever the header says",
  "Traces with a sample that is not a number, or infinite",
  "Stations the template (the relation records) plans for the record that it has no trace of",
  "Traces at stations the template does not list for the record",
  "Stations recorded twice in one component",
  "Traces that are not seismic (time breaks, pilots): counted, they have no place on the map",
  "Seismic traces the map cannot place (no coordinates, and no survey file has their station)",
  "Traces whose polarity you reversed (the plot's menu, R)",
  "Shots whose listed receivers are not those of the template the relation records describe",
  "Traces outside the exclusion area far louder than those either side of them on their own" &
    " line (a station that is loud against its neighbours, not noisy against the record)",
  "Traces whose noise was not judged: inside the exclusion area, whose sensor or station is" &
    " not known, or of a node with a component missing. They are not shown as good",
  "Traces whose own header receiver or source position is not where the survey puts their" &
    " station (a station that moved, or a survey that is not the file's). Any format. In the" &
    " station-move menu, \"Move this station to the position in this trace's headers\"" &
    " follows it. " & ClearCase,
  "Traces whose first-break pick is further from the refraction model fitted to the record" &
    " than the record's own scatter allows (three times the scatter of the picks near the" &
    " model, never less than 12 ms), or whose break was found 100 to 400 ms from it (far off" &
    " the model): the first-break overlay's flags, the same traces it joins with a line on the" &
    " Seismic plot. Ticked with the overlay off, it has the overlay's picks made all the same;" &
    " the overlay stays off. " & ClearCase,
  "Traces whose first-break pick differs from those of the traces beside it on its receiver" &
    " line by more than the record's scatter allows: a wrong station, even where the breaks" &
    " bend away from a straight model. The first-break overlay's flags, as for \"off the" &
    " model\". " & ClearCase]

const FilterOrder* = [mfDead, mfUndecodable, mfKilled, mfNoisy, mfLouder, mfWeak, mfNotJudged,
  mfClipped, mfSpiky, mfConstant, mfDcOffset, mfAllZero, mfNotANumber, mfMissing, mfUnlisted,
  mfDuplicate, mfAuxiliary, mfNoPosition, mfReversed, mfSpreadDiffers, mfPositionOff,
  mfBreakOffModel, mfBreakOffNeighbours]
  ## the order the filters are listed in: the noisy-trace test's findings together
static: doAssert FilterOrder.len == ord(high(MapFilter)) + 1, "a filter is not listed"
static: doAssert FilterOrder.len == ord(high(MapFilter)) + 1, "a filter is not listed"

const
  NoSettingsCommand = "The settings command is not offered to an agent: the user ticks this in" &
    " the Layers list."
  LayerChange = "command \"" & $ckMapLayer & "\": mapLayer (the layer's \"mapLayer\" in" &
    " state's map layers; the highlight's is {\"kind\": \"highlight\"}), shown (true or false," &
    " true when left out)"

func slug(s: string): string =
  ## A word for an id: lower case, spaces as dashes.
  s.toLowerAscii.replace(' ', '-')

func filterLabel*(f: MapFilter; h: FilterHits): string =
  ## A filter's line in the Layers list: its name and what it found,
  ## "noisy  (3)", "missing from the template  (computing...)".
  let name = ($f)[0 .. 0].toUpperAscii & ($f)[1 .. ^1]
  name & (case h.state
    of fsOff: ""
    of fsComputing: "  (computing...)"
    of fsDone: "  (" & $h.count & ")"
    of fsNotChecked: "  (not checked)")

func filterTip*(f: MapFilter; h: FilterHits): string =
  ## A filter's tooltip: what it marks, what it found or why it was not
  ## checked, and how the map marks it.
  filterTips[f] & (if h.note.len > 0 and h.state == fsNotChecked: ".\nNot checked: " &
    h.note & "." elif h.note.len > 0 and h.state == fsDone: " (" & h.note & ")." else: ".") &
    "\nMarked on the map with a " & $f.shapeOf & (if FilterMarks[f].symbol == syNone: ""
    else: " with " & $FilterMarks[f].symbol & " inside") & ": the shape and the colour of " &
    $FilterMarks[f].family & "."

func filterDocs*(st: AppState): seq[OptionDoc] =
  ## The map's filters, in the order the window lists them, with their state now.
  let hits = st.filterHits
  for f in FilterOrder:
    let on = f in st.settings.map.filters
    let h = if on: hits[f] else: FilterHits()
    let blocked = on and h.state == fsNotChecked
    result.add OptionDoc(id: "map.filter." & slug($f),
      label: filterLabel(f, h), explain: filterTip(f, h), value: (if on: "on" else: "off"),
      available: not blocked, whyNot: (if blocked: h.note else: ""),
      refused: NoSettingsCommand)

func roleName*(r: PointRole; many: bool): string =
  ## "Sources", "Receiver": a point's role as the map says it.
  case r
  of prSource: (if many: "Sources" else: "Source")
  of prReceiver: (if many: "Receivers" else: "Receiver")

func layerName*(kind: MapLayerKind; role: PointRole; file: string; joined: bool): string =
  ## A layer's name in the Layers list: "Receivers of line3.rps",
  ## "Sources in a.sgy (joined)".
  case kind
  of mlHighlight: "Highlight: the trace under the pointer, the selection"
  of mlShotLog: "Shots of " & file
  of mlSurveyFile, mlTraces:
    roleName(role, true) & (if kind == mlTraces: " in " else: " of ") & file &
      (if joined: " (joined)" else: "")

func layerLabel*(name: string; points: int): string =
  ## A layer's line in the Layers list: its name and its number of points.
  name & (if points > 0: "  (" & $points & ")" else: "")

func layerTip*(kind: MapLayerKind; role: PointRole): string =
  ## A layer's tooltip: what it draws.
  case kind
  of mlSurveyFile:
    "The " & (if role == prSource: "sources" else: "receivers") & " this survey file (SPS or" &
      " SEG P1) planned, as filled discs. Tick to show or hide them"
  of mlTraces:
    "The " & (if role == prSource: "source" else: "receiver") & " positions the open file's" &
      " trace headers give (or a join made), as rings round the survey's discs: where they" &
      " agree each disc sits in its ring. Tick to show or hide them"
  of mlShotLog:
    "The shots of a loaded shot log, as diamonds. Tick to show or hide them"
  of mlHighlight:
    "The points of the trace under the pointer in the plot, and of the selection. Tick to" &
      " show or hide them"

func layerDocs*(st: AppState): seq[OptionDoc] =
  ## The map's layers as the Layers list shows them, in the order they are
  ## drawn, the highlight last.
  for kind in [loSurveyFile, loTraces, loShotLog]:
    for r in [prReceiver, prSource]:
      for i in 0 ..< st.survey.layers.len:
        # An alias, not a copy: a layer of a million points is 100 MB.
        template l: untyped = st.survey.layers[i]
        if l.origin == kind and l.points[r].len > 0:
          let key = l.keyOf(r)
          let joined = kind == loTraces and st.joinedOf(l.session) >= 0
          let own = st.map.shown(key)
          result.add OptionDoc(id: "map.layer." & slug($key.kind) & "." & $r & "." &
              slug(l.name), label: layerLabel(layerName(key.kind, r, l.name, joined),
              l.points[r].len), explain: layerTip(key.kind, r),
            value: (if not own: "off" elif st.map.drawn(st.settings.map.hiddenGroups, l, r): "on"
            else: "on, hidden with its group"),
            available: true, change: LayerChange)
  let on = st.map.shown(HighlightKey)
  result.add OptionDoc(id: "map.layer.highlight",
    label: layerName(mlHighlight, prSource, "", false),
    explain: layerTip(mlHighlight, prSource), value: (if on: "on" else: "off"),
    available: true, change: LayerChange)
