## A trace's identification code in words: "vibrator baseplate (19)" for a standard
## code, "code 29 (not in the standard)" for one outside it, nothing when it is not set.
## Shown in the readout (the trace identification field, and the note after the
## readout for a trace that is not seismic data) and in the Headers window's Trace
## tab, on a synthetic file with the vibrator codes and one with codes outside the
## standard.
##
## Seen to fail: with the Trace tab's description left as the field's name (`fieldRow`
## not adding the code's words), `traceTab` read "Trace identification code".

import std/[strutils]
import parseSEG
import viewSEG/core/[headers, pick, readout, traceids, zoom]
import utils/[fixtures, vibfiles]

func pickOf(code: int16; status: TraceStatus): Pick =
  result = noPick()
  result.inside = true
  result.found = true
  result.keys.traceCode = code
  result.keys.status = status

proc main*() =
  block names:
    doAssert traceIdText(19) == "vibrator baseplate (19)", traceIdText(19)
    doAssert traceIdText(18) == "vibrator reaction mass (18)"
    doAssert traceIdText(20) == "vibrator estimated ground force (20)"
    doAssert traceIdText(21) == "vibrator reference (21)"
    doAssert traceIdText(1) == "seismic data (1)"
    doAssert traceIdText(29) == "code 29 (not in the standard)", traceIdText(29)
    doAssert traceIdText(33) == "code 33 (not in the standard)"
    doAssert traceIdText(-1) == "other (-1)"
    doAssert traceIdText(29, true) == "electric field, in-line (29)", traceIdText(29, true)
    doAssert traceIdText(41, true) == "rotational sensor, yaw (41)"
    doAssert traceIdText(16396, true) == "interpolated multicomponent seismic sensor, vertical (16396)",
      traceIdText(16396, true)
    doAssert traceIdText(300, true) == "code 300 (optional use)"
    doAssert traceIdText(300) == "code 300 (not in the standard)"
    doAssert traceIdText(0) == ""
    doAssert VibReferenceCode == 21 and VibBaseplateCode == 19 and VibReactionMassCode == 18
    doAssert VibGroundForceCode == 20

  block readoutField:
    doAssert pickOf(19, tsAuxiliary).text(rfTraceId) == "vibrator baseplate (19)"
    doAssert pickOf(29, tsUnknown).text(rfTraceId) == "code 29 (not in the standard)"
    doAssert pickOf(0, tsLive).text(rfTraceId) == ""
    doAssert caption(rfTraceId) == "id"

  block readoutNote:
    # a trace that is not seismic data says what it is beside the readout; a seismic one
    # and a dead one do not
    doAssert pickOf(19, tsAuxiliary).editNote == "vibrator baseplate (19)"
    doAssert pickOf(29, tsUnknown).editNote == "code 29 (not in the standard)"
    doAssert pickOf(1, tsLive).editNote == ""
    doAssert pickOf(2, tsDead).editNote == "dead"
    doAssert pickOf(0, tsUnknown).editNote == ""

  block traceTab:
    withFixtures fx:
      var f = openSeismic(fx.vibThirteenSegy(), keys = true)
      try:
        proc code(trace: int): string =
          for r in traceRows(f, trace):
            if r.field == "traceIdCode": return r.description
        doAssert code(1).endsWith(": vibrator baseplate (19)"), code(1)
        doAssert code(4).endsWith(": code 29 (not in the standard)"), code(4)
        doAssert code(11).endsWith(": seismic data (1)"), code(11)
      finally:
        f.close()
  echo "ttraceids: ok"

when isMainModule:
  main()
