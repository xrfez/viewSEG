## A SEG-Y trace whose field record number is 0 and that directly follows
## traces of another record joins that record (0 is "not set", not a record
## number), and Messages says so once for the file. A file whose every record
## number is 0 is one record, as before, and says nothing.
##
## Seen to fail: with the traces left in a gather of their own, `joined` found 2
## records for the four traces and no line in the Messages.

import std/strutils
import viewSEG/core/[log, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func count(log: MessageLog; part: string): int =
  for e in log:
    if part in e.text: inc result

proc main*() =
  withFixtures fx:
    block joined:
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[fx.vibZeroTailSegy()])
      doAssert st.settle(st.sessions.len == 1)
      doAssert st.sessions[0].gathers.len == 1, "records: " & $st.sessions[0].gathers.len
      doAssert st.sessions[0].gathers[0].traces == 0 .. 3
      doAssert st.log.count("1 trace with field record number 0 was kept with the record " &
        "before it.") == 1
      discard st.shutdown()
    block allZero:
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[fx.vibThirteenSegy()])
      doAssert st.settle(st.sessions.len == 1)
      doAssert st.sessions[0].gathers.len == 1
      doAssert st.log.count("field record number 0") == 0
      discard st.shutdown()
  echo "tzerorecord: ok"

when isMainModule:
  main()
