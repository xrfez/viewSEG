## Stepping through files with a survey loaded is quiet:
##
## - a file whose traces are all auxiliary gets no survey check at all: no toast, no
##   warning, no check of its records (`checkedAgainst` stays empty), and its headers' units
##   do not take part in the units judgement, so a survey in feet does not clash with it;
## - what the program starts by itself (the records' check of a seismic file) ends without
##   a toast and without an "is done" line, a job the user started still has both;
## - a seismic file whose headers say other units than the survey still warns, once.
##
## Seen to fail: with `checkRecords` not skipping a file without seismic traces,
## `allAuxiliary` found the check; with `followUnits` counting it, a warning; with the jobs
## not marked `auto`, `autoJobsAreQuiet` found a notice.

import std/[os, strutils]
import viewSEG/core/[jobs, log, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func count(log: MessageLog; part: string): int =
  for e in log:
    if part in e.text: inc result

func opened(st: AppState; path: string): int =
  for i, s in st.sessions:
    if s.path.extractFilename == path.extractFilename: return i
  -1

proc surveyLoaded(fx: Fixtures; st: var AppState) =
  let sps = fx.mapSpsIn("quiet-feet", "Feet", "0.3048")
  st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r, fx.mapXps()])
  doAssert st.settle(st.survey.layers.len == 3 and st.jobs.active.len == 0)

proc main*() =
  withFixtures fx:
    block allAuxiliary:
      var st = initAppState()
      fx.surveyLoaded(st)
      for path in [fx.vibFourSegy(), fx.vibFourAgainSegy(), fx.vibOtherFourSegy()]:
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
        doAssert st.settle(st.opened(path) >= 0 and st.jobs.active.len == 0), path
        doAssert st.sessions[st.opened(path)].checkedAgainst == "", "its records were checked"
      doAssert st.notices.len == 0, "a toast: " & st.notices[0].text
      doAssert st.log.count(sevWarning) == 0, "a warning: " & $st.log.count(sevWarning)
      doAssert st.log.count("Check the records") == 0
      doAssert st.unitsDisagree == "", st.unitsDisagree
      doAssert st.log.count("is switched on") <= 1

    block autoJobsAreQuiet:
      var st = initAppState()
      fx.surveyLoaded(st)
      let path = fx.vibLongSegy()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.opened(path) >= 0 and
        st.sessions[st.opened(path)].checkedAgainst.len > 0 and st.jobs.active.len == 0),
        "the records were not checked"
      doAssert st.notices.len == 0, "a toast: " & st.notices[0].text
      doAssert st.log.count("is done") == 0
      discard st.jobs.submit(JobSpec(title: "Scan line 7", lane: jlBackground),
        proc(ctx: JobContext) {.gcsafe.} = discard)
      doAssert st.settle(st.notices.len == 1), "a user's job gave no toast"
      doAssert st.notices[0].text == "Scan line 7 is done."

    block realDisagreement:
      var st = initAppState()
      fx.surveyLoaded(st)
      let path = fx.surveySegy() # its headers say metres
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.opened(path) >= 0 and st.jobs.active.len == 0)
      doAssert st.settle(st.log.count("units disagree") == 1), "no warning"

  echo "tquietfiles: done"

when isMainModule:
  main()
