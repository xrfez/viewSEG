## The SEG-D channel set of a trace as a header field: its value per trace on
## `samples/vib/vib_signature.sgd` (channel sets 1, 2, 3, 4 cycling), in words
## with its channel type, a sort by it, its readout, the trace table's
## columns, and for SEG-Y (no channel sets) an empty field and the trace ID
## code as a field of its own. The header rows are never chosen by default:
## `defaultFields` does not give either, also for a record of auxiliary traces.
##
## Seen to fail: with `value` giving the channel set's 0-based index, the
## cycling check found 0, 1, 2, 3; with the sort key ignoring the channel set
## (`rows.channelSetIndex` not passed), `sortByIt` found the file's order; with the
## number taken as the place (index + 1), `ownNumbers` found 1, 2, 3.

import std/[math, os, strutils]
import parseSEG
import viewSEG/core/[channelsets, headers, panels, pick, readout, sorting, tracetable]
import viewSEG/view/displayheader
import utils/[fixtures, vibfiles]

const sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" / "vib_signature.sgd"

proc main*() =
  block segdValues:
    doAssert fileExists(sample), sample
    var f = openSeismic(sample, keys = true)
    try:
      doAssert f.len >= 8
      for t in 0 ..< 8:
        let k = f.traceKeys(t)
        let v = k.value(hfChannelSet, t, f.channelSetNumberOf(t))
        doAssert v == float64(t mod 4 + 1), "trace " & $t & ": channel set " & $v
        let text = f.channelSetText(t)
        doAssert text.startsWith($(t mod 4 + 1) & " · "), text
        doAssert text.len > 4, text
        doAssert k.value(hfTraceId, t).isNaN, "SEG-D has no trace ID code"
      doAssert headerLabel(hfChannelSet, 2, f.channelSetText(1)) ==
          f.channelSetText(1)
      doAssert headerLabel(hfChannelSet, 2, "") == "2"
      doAssert tracetable.keyValue(f.traceKeys(2), "keys.channelSet",
          f.channelSetNumberOf(2)) == 3
      doAssert tracetable.keyLabel("keys.channelSet").len > 0
      # the table's catalogue lists both columns
      var names: seq[string]
      for (n, _) in KeyColumns: names.add n
      doAssert "keys.channelSet" in names and "keys.traceCode" in names

      # a sort by it: stable, so each set's traces keep the file's order
      let list = @[0, 1, 2, 3, 4, 5, 6, 7]
      let rows = f.rowsOf(list)
      var got: seq[int]
      doAssert sortRowsInto(rows, [SortKey(field: hfChannelSet)], got)
      doAssert got == @[0, 4, 1, 5, 2, 6, 3, 7], "sortByIt: " & $got
      doAssert sortRowsInto(rows, [SortKey(field: hfChannelSet,
          descending: true)], got)
      doAssert got == @[3, 7, 2, 6, 1, 5, 0, 4], $got

      # the readout
      var p = noPick()
      p.inside = true
      p.found = true
      p.channelSet = f.channelSetText(1)
      doAssert p.text(rfChannelSet) == p.channelSet and p.channelSet.startsWith("2 · ")
      doAssert caption(rfChannelSet) == "set"
    finally:
      f.close()

  block ownNumbers:
    # the file's own channel set numbers (7, 3, 12), not the places 1, 2, 3
    withFixtures fx:
      var f = openSeismic(fx.numberedSetsSegd(), keys = true)
      try:
        doAssert f.len == 3
        let want = [7, 3, 12]
        for t in 0 ..< 3:
          doAssert f.channelSetNumberOf(t) == want[t], $t & ": " & $f.channelSetNumberOf(t)
          doAssert f.traceKeys(t).value(hfChannelSet, t, f.channelSetNumberOf(t)) ==
            float64(want[t])
          doAssert f.channelSetText(t).startsWith($want[t] & " · "), f.channelSetText(t)
          doAssert tracetable.keyValue(f.traceKeys(t), "keys.channelSet",
            f.channelSetNumberOf(t)) == float64(want[t])
        let rows = f.rowsOf(@[0, 1, 2])
        let numberOf = proc (t: int): int {.gcsafe, raises: [].} = f.channelSetNumberOf(t)
        var got: seq[int]
        doAssert sortRowsInto(rows, [SortKey(field: hfChannelSet)], got, setNumber = numberOf)
        doAssert got == @[1, 0, 2], "sorted by the file's numbers 3, 7, 12: " & $got
      finally:
        f.close()

  block segyHasNone:
    withFixtures fx:
      var f = openSeismic(fx.vibThirteenSegy(), keys = true)
      try:
        doAssert f.channelSetNumberOf(1) == 0 and f.channelSetText(1) == ""
        let k = f.traceKeys(1)
        doAssert k.value(hfChannelSet, 1, f.channelSetNumberOf(1)).isNaN
        doAssert k.value(hfTraceId, 1) == 19
        doAssert headerLabel(hfTraceId, 19, "") == "vibrator baseplate (19)"
        doAssert headerLabel(hfTraceId, NaN, "") == ""
      finally:
        f.close()

  block neverByDefault:
    # whatever the file has, the automatic rows do not include either field
    let all = {HeaderField.low .. HeaderField.high}
    for kind in [gkShot, gkReceiver, gkCmp, gkUnknown, gkOther, gkOffset]:
      let rows = defaultFields(all, kind)
      doAssert hfChannelSet notin rows and hfTraceId notin rows, $kind
    doAssert defaultFields({hfChannelSet, hfTraceId}) == @[hfTrace]
  echo "tchannelsets: ok"

when isMainModule: main()
