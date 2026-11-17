## The map's filters "not in the template" and "recorded twice" on a record's
## traces against its relation records (`core/recordqc.placeTraces`), from
## keys made here, without a file:
##
## - a receiver gather against its O record: a source recorded twice is
##   counted once (one source), its two traces marked; a source the O record
##   does not list is counted and marked; the planned sources the gather
##   lacks are listed;
## - a station decoded from a binary fraction (SEG-D: 101.1 read as
##   101.09999...) is the relation file's 101.1, as parseSEG keys stations:
##   not "not in the template", and its trace and one of 101.1 itself are
##   the same station recorded twice.
##
## Seen to fail: with the receiver gather's duplicates counted as before
## (`dup.len div 2` of the first traces), "recorded twice" counted 0 sources;
## with the headers' stations taken as they are (not keyed to 1/100), the
## binary fraction was "not in the template".

import std/[algorithm, sets]
import parseSEG
import viewSEG/core/recordqc

proc keysOf(stations: openArray[(float64, float64)]; receiver: bool): seq[TraceKeys] =
  ## A trace per station: its source (`receiver`: a receiver gather) or
  ## receiver (a shot) there.
  for (line, point) in stations:
    var k = initTraceKeys()
    k.status = tsLive
    if receiver:
      (k.srcLine, k.srcPoint, k.srcIndex) = (line, point, 1'i16)
      (k.rcvLine, k.rcvPoint, k.rcvIndex) = (500.0, 7.0, 1'i16)
    else:
      (k.rcvLine, k.rcvPoint, k.rcvIndex) = (line, point, 1'i16)
      (k.srcLine, k.srcPoint, k.srcIndex) = (10.0, 5.0, 1'i16)
    result.add k

func relation(kind: char; record: int64; fixed: (float64, float64); line, first, last: float64;
    channel: int64): SpsRelation =
  SpsRelation(recordType: kind, fieldRecord: record, srcLine: fixed[0], srcPoint: fixed[1],
    srcIndex: 1, fromChannel: channel, toChannel: channel + int64(last - first),
    channelIncrement: 1, rcvLine: line, fromReceiver: first, toReceiver: last, rcvIndex: 1)

proc main*() =

  block receiverGather:
    # O record 7 of receiver 500/7: sources 101 .. 110 of source line 20.
    var g = initSurveyGeometry()
    g.addSps(SpsFile(relations: @[relation('O', 7, (500.0, 7.0), 20, 101, 110, 1)]), rdReceiver)
    var stations: seq[(float64, float64)]
    for p in 101 .. 108: stations.add (20.0, float64(p)) # 109 and 110 not recorded
    stations.add (20.0, 104.0) # 104 recorded twice
    stations.add (21.0, 101.0) # not in the O record
    let keys = keysOf(stations, receiver = true)
    var hits: array[MapFilter, FilterHits]
    hits.placeTraces(keys, 1000, 0 .. keys.high, g, 7, rdReceiver)
    doAssert hits[mfDuplicate].count == 1, "recorded twice: " & $hits[mfDuplicate].count &
      " sources"
    doAssert sorted(hits[mfDuplicate].traces) == @[1003, 1008], $hits[mfDuplicate].traces
    doAssert hits[mfUnlisted].count == 1 and hits[mfUnlisted].traces == @[1009],
      $hits[mfUnlisted]
    var missing: seq[float64]
    for st in hits[mfMissing].stations: missing.add st.point
    doAssert hits[mfMissing].count == 2 and sorted(missing) == @[109.0, 110.0], $missing

  block binaryFraction:
    # X record 3 of source 10/5: receivers 101.1 .. 105.1 of receiver line 30.
    var g = initSurveyGeometry()
    g.addSps(SpsFile(relations: @[relation('X', 3, (10.0, 5.0), 30, 101.1, 105.1, 1)]), rdSource)
    let decoded = 101.0 + float64(uint16(0.1 * 65536)) / 65536         # SEG-D's 2-byte fraction
    doAssert decoded != 101.1
    let keys = keysOf([(30.0, decoded), (30.0, 101.1), (30.0, 102.1)], receiver = false)
    var hits: array[MapFilter, FilterHits]
    hits.placeTraces(keys, 0, 0 .. keys.high, g, 3, rdSource)
    doAssert hits[mfUnlisted].traces.len == 0, "not in the template: " & $hits[mfUnlisted].traces
    doAssert sorted(hits[mfDuplicate].traces) == @[0, 1], $hits[mfDuplicate].traces

  echo "trecordqc: ok"

when isMainModule:
  main()
