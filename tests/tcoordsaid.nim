## What Messages says of a file's coordinates when its headers give them on
## auxiliary traces only, and when only some of its traces have any:
##
## - a file whose only coordinates are on its auxiliary traces does not "carry no
##   coordinates": the line says that only auxiliary traces carry them and that
##   they are not placed on the map, once for the folder;
## - a file with coordinates on some seismic traces says how many traces are left off the
##   map, in one line, and a second file of the same kind in that folder does not
##   say the same again.
##
## Seen to fail: with the old wording, `onlyAux` found "carries no source or receiver
## coordinates"; with the line said at every file, `sameKind` found two lines.

import std/[os, strutils]
import viewSEG/core/[log, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func count(log: MessageLog; part: string): int =
  for e in log:
    if part in e.text: inc result

proc main*() =
  withFixtures fx:
    block onlyAux:
      var st = initAppState()
      let path = fx.vibFourSegy()
      st.apply Command(kind: ckOpen, paths: @[path])
      doAssert st.settle(st.sessions.len == 1 and st.survey.layers.len == 1)
      doAssert st.log.count("carries no source or receiver coordinates") == 0
      doAssert st.log.count("Only auxiliary traces of vib-four.sgy carry coordinates (4 traces)," &
        " and auxiliary traces are not placed on the map.") == 1
      discard st.shutdown()

    block sameKind:
      var st = initAppState()
      let first = fx.vibThirteenSegy()
      let third = fx.dir / "vib-thirteen-again.sgy"
      copyFile(first, third)
      st.apply Command(kind: ckOpen, paths: @[first])
      doAssert st.settle(st.sessions.len == 1 and st.survey.layers.len == 1)
      doAssert st.log.count("6 traces without source coordinates") == 1
      st.apply Command(kind: ckOpen, paths: @[third])
      doAssert st.settle(st.sessions.len == 2 and st.survey.layers.len == 2)
      doAssert st.log.count("6 traces without source coordinates") == 1,
        "the same words said again for the same folder"
      discard st.shutdown()
  echo "tcoordsaid: ok"

when isMainModule:
  main()
