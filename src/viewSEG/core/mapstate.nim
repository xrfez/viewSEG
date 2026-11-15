## The map window's state in `core`: the view it shows and the views before
## it (for back), and the layers the user hid. Changed only by commands
## (`core/state`: `ckMapView`, `ckMapBack`, `ckMapLayer`).
##
## **Layers.** The map draws one layer per role of each survey layer that
## has points (a survey file's sources or receivers, an open file's own
## sources or receivers) and the highlight on top. A hidden layer is named
## by its file and role (`MapLayerKey`), not by the survey layer's id, so it
## stays hidden when its file is loaded again.
##
## **The survey changes** (a file loaded, one closed): a map that showed the
## whole survey shows the whole new one; another view stays where it is,
## kept within the new bounds (`followed`).

import mapview, survey

export mapview

const MaxMapBack* = 50 ## views kept for back

type
  MapLayerKind* = enum
    mlSurveyFile = "survey file" ## an SPS or P1 file's points
    mlTraces = "traces"          ## an open file's own positions
    mlHighlight = "highlight"    ## the hovered and selected points

  MapLayerKey* = object
    ## Names a layer of the map.
    kind*: MapLayerKind
    path*: string    ## the file; "" for the highlight
    role*: PointRole ## sources or receivers (the highlight: sources)

  MapState* = object
    view*: MapView       ## what the map shows; not set until the frontend gives its size
    back*: seq[MapView]  ## the views before the last gestures, for back
    jumps*: int          ## bumped when `core` sets the view itself (back, a new survey)
    hidden*: seq[MapLayerKey]
    surveyRevision*: int ## the survey's revision the view last followed
    limits*: MapLimits   ## the limits the view was kept within then
    revision*: int       ## bumped on every change

const HighlightKey* = MapLayerKey(kind: mlHighlight)

func keyOf*(l: SurveyLayer; r: PointRole): MapLayerKey =
  ## The map layer of role `r` of survey layer `l`.
  MapLayerKey(kind: (if l.origin == loTraces: mlTraces else: mlSurveyFile), path: l.path,
    role: r)

func shown*(m: MapState; key: MapLayerKey): bool =
  ## Whether the map draws the layer `key` names.
  key notin m.hidden

proc show*(m: var MapState; key: MapLayerKey; on: bool) =
  ## Shows or hides layer `key`.
  let at = m.hidden.find(key)
  if on and at >= 0: m.hidden.delete(at)
  elif not on and at < 0: m.hidden.add key
  inc m.revision

proc setView*(m: var MapState; v: MapView; remember: bool) =
  ## The view the frontend shows now; with `remember` (a gesture starts),
  ## the one it replaces is kept for back.
  if remember and m.view.isSet and not sameMapView(m.view, v):
    m.back.add m.view
    if m.back.len > MaxMapBack: m.back.delete(0)
  if v != m.view:
    m.view = v
    inc m.revision

proc goBack*(m: var MapState): bool =
  ## The view before the last gesture, at the plot's size; false when there
  ## is none.
  result = m.back.len > 0
  if result:
    var v = m.back.pop()
    (v.columns, v.rows) = (m.view.columns, m.view.rows)
    m.view = keptMap(v, m.limits)
    inc m.jumps
    inc m.revision

proc followed*(m: var MapState; s: Survey) =
  ## Follows a change of the survey: a view of the whole survey shows the
  ## whole new one; another stays, within the new bounds.
  if s.revision == m.surveyRevision: return
  m.surveyRevision = s.revision
  let now = mapLimits(s.bounds)
  if m.view.isSet and not now.bounds.isEmpty:
    let v = if m.view.showsAll(m.limits) or m.limits.bounds.isEmpty:
        fitMap(now, m.view.columns, m.view.rows)
      else: keptMap(m.view, now)
    if v != m.view:
      m.view = v
      inc m.jumps
  m.limits = now
  inc m.revision
