## A shot log's shots as a layer of the map. The column map says whether the
## log has positions (an X and a Y column); each row that has finite, non-zero
## coordinates becomes a source point of the layer, with its source line and
## shot point as the station when it has them. A row without a position is
## counted (`SurveyLayer.counts`) and left off, as for any layer. Every row
## is treated alike, whatever problem the log lists for it: the Shot log
## window lists every row too, and marks the problems beside them.

import shotlog, survey

func hasPositions*(map: ShotLogMap): bool =
  ## Whether the column map names both an X and a Y column.
  crX in map.roles and crY in map.roles

proc shotLayer*(view: ShotView; map: ShotLogMap): ref SurveyLayer =
  ## The layer of the shots of `view`, read with `map`, with its levels of
  ## detail; nil when `map` has no positions or no row has one. The log's id,
  ## path and name (`SurveyLayer.shotLog`, `path`, `name`) are the caller's to set. Worker-only: a
  ## hundred thousand shots take a few milliseconds.
  result = nil
  if not map.hasPositions: return
  var b = initShotLayerBuilder("", "", 0)
  for s in view.rows: b.addShot(s.sourceLine, s.shotPoint, s.x, s.y, s.z)
  var layer = b.finish()
  if layer.points[prSource].len > 0:
    layer.withLevels()
    new result
    result[] = move layer
