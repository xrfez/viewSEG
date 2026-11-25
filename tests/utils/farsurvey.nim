## A survey whose receivers lie 50 m east of where `fixtures`' headers put them, for the
## tests of the station moves.

import std/os
import parseSEG
import fixtures

proc surveyFarther*(fx: Fixtures): tuple[s, r, x: string] =
  ## `surveySps`'s source and relation files, and a receiver file with every receiver of
  ## line 100 50 m east of the position the headers give.
  let base = fx.surveySps()
  var r = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")])
  for channel in 1 .. Channels:
    r.points.add SpsPoint(kind: pkReceiver, line: RcvLine,
      point: FirstRcvPoint + float64(channel - 1), index: 1, code: "G1",
      easting: rcvX(channel) + 50.0, northing: OriginY, elevation: Elevation, dayOfYear: -1,
      hour: -1, minute: -1, second: -1)
  let path = fx.dir / "farther.r"
  doAssert writeSps(r, path).len == 0
  (base.s, path, base.x)
