## A SEG-Y trace whose field record number is 0 and that directly follows
## traces of another record joins that record (0 is "not set", not a record
## number), and Messages says so once for the file. A file whose every record
## number is 0 is one record, as before, and says nothing.
##
## Joined only when the run is auxiliary or has the previous record's shot time.
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
    block aShotOfItsOwn:
      # seismic traces of record 0 after a record, with no shot time: a record of their own
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[fx.vibZeroSeismicSegy()])
      doAssert st.settle(st.sessions.len == 1)
      doAssert st.sessions[0].gathers.len == 2, "joined: " & $st.sessions[0].gathers.len
      doAssert st.log.count("field record number 0") == 0
      discard st.shutdown()
    block sameShotTime:
      # the same shot time as the record before: joined, and the row keeps that record's number
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[fx.vibZeroTimedSegy()])
      doAssert st.settle(st.sessions.len == 1)
      doAssert st.sessions[0].gathers.len == 1, "not joined: " & $st.sessions[0].gathers.len
      doAssert st.sessions[0].records[0].record == 7, $st.sessions[0].records[0].record
      doAssert st.log.count("2 traces with field record number 0 were kept") == 1
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
