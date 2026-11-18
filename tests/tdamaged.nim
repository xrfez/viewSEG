## A SEG-Y file whose binary header says 0 samples per trace and whose first
## trace header says 0 samples gives no trace length: it is refused, not opened as
## thousands of garbage traces. One line in the Messages says what was found and that
## the file looks damaged or is not SEG-Y; nothing is on the map or in Records (no file
## is open). Files that look alike but are fine still open: a binary header of 0 with
## trace headers that give the length, and a rev 1 file of traces of different lengths.
##
## Seen to fail: with the check not raised (`openSession` in `core/filejobs`), the damaged
## file opened ("Opened damaged.sgy: 1 trace in 1 gather") and the check on the line
## "Cannot open" failed.

import std/strutils
import viewSEG/core/[log, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func lines(log: MessageLog; part: string): int =
  for e in log:
    if part in e.text or part in e.source: inc result

proc main*() =
  withFixtures fx:
    var st = initAppState()
    let bad = fx.damagedSegy()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: bad)
    let ok = st.settle(st.log.lines("Cannot open") > 0)
    var all = ""
    for e in st.log: all.add e.text & "\n"
    doAssert ok, all
    doAssert st.sessions.len == 0, "the damaged file was opened"
    doAssert st.log.lines("damaged.sgy") == 1, "more than one line about the file: " &
      $st.log.lines("damaged.sgy")
    var said = ""
    for e in st.log:
      if "Cannot open" in e.text: said = e.text
    doAssert "0 samples" in said and "damaged or is not SEG-Y" in said, said

    for path in [fx.zeroBinarySegy(), fx.variableSegy(), fx.headersOnlySegy(), fx.emptyFirstSegy(),
        fx.laterEmptySegy()]:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == path and
        st.panel(MainPanel).laidOut), "did not open: " & path
      doAssert st.sessions[0].len in 3 .. 4, path & ": " & $st.sessions[0].len
      st.apply Command(kind: ckClose, file: st.sessions[0].id)
      doAssert st.settle(st.sessions.len == 0)
    discard st.shutdown()
  echo "tdamaged: ok"

when isMainModule:
  main()
