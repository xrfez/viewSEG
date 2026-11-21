## The Trace tab's "From the survey" rows, and the one quiet line that takes
## their place when the survey changed nothing in a trace (`traceTable`,
## `surveyStatus`), on a synthetic Rev 0 file whose headers carry the stations
## times 100 (the shipped map `segy-x100-stations.nif`) and the survey's own
## coordinates:
##
## - a trace whose stations are in the survey and whose headers agree gets the
##   line "From the survey: source 519 / 136 and receiver 100 / 316 are in the
##   project's survey; the headers already agree" (whole numbers whole, a
##   fraction kept: 100.5), and no "From the survey" group;
## - a trace whose source is not in the survey says so;
## - an auxiliary trace is left alone, and says so;
## - when the survey gave some of a trace's values (`joined`), the group of rows
##   shows as before and no line is added;
## - several traces: each line names its trace; a file with no match gets none.
##
## Seen to fail: with `surveyStatus` never reading `plan.unmatched`, "the trace
## not in the survey agrees"; with the group's early return in `traceTable`
## not taking the lines, "no line for a trace that agrees".
import std/[os, strutils]
import parseSEG
import viewSEG/core/[headers, join, openchoice, state, survey, vendormaps]
import viewSEG/view/headerviews
import utils/[fixtures, stations100]

proc detail(f: SeismicFile; t: int): TraceDetail =
  TraceDetail(trace: t, file: "x100.sgy", keys: f.traceKeys(t), rows: traceRows(f, t),
    joined: f.index.joinedGroups(t), dtMs: 1)

proc main*() =
  withFixtures fx:
    let path = fx.dir / "x100.sgy"
    writeFile100(path)
    var reg: VendorRegistry
    reg.addMap loadVendorMap(readFile(MapPath), MapPath)
    var f = openSeismic(path, keys = true, opts = openOptions(OpenChoice(), "", reg))
    let plan = planJoin(addr f, surveyOf(), JoinOptions(), proc (d, n: int): bool = true)
    doAssert plan.unmatched == @[2], $plan.unmatched
    let j = Joined(plan: plan)
    let d = [detail(f, 0), detail(f, 1), detail(f, 2), detail(f, 3)]
    let st = [surveyStatus(j, d[0]), surveyStatus(j, d[1]), surveyStatus(j, d[2]),
      surveyStatus(j, d[3])]
    doAssert st == [ssAgrees, ssAgrees, ssNotIn, ssAux], $st

    func titles(t: FieldTable): seq[string] =
      for r in t.rows:
        if r.title.startsWith(JoinedTitle): result.add r.title

    block agrees:
      let t = traceTable([d[0]], [st[0]])
      doAssert t.titles[0] == "From the survey: source 519 / 136 and receiver 100 / 316 " &
        "are in the project's survey; the headers already agree", "no line for a trace that agrees: " & $t.titles
      doAssert t.rows[0].title == t.titles[0], "the line is the table's first row"
      doAssert traceTable([d[0]], [ssUnmatched]).titles.len == 0
    block fraction:
      let t = traceTable([d[1]], [st[1]])
      doAssert "source 519 / 100.5 and receiver 100 / 317" in t.titles[0], t.titles[0]
    block not_in_the_survey:
      let t = traceTable([d[2]], [st[2]])
      doAssert t.titles[0] == "From the survey: source 777 / 1 and receiver 100 / 316 are " &
        "not both in the project's survey", "the trace not in the survey agrees: " & t.titles[0]
    block auxiliary:
      let t = traceTable([d[3]], [st[3]])
      doAssert t.titles[0] == "From the survey: an auxiliary trace is left alone", t.titles[0]
    block no_match:
      doAssert traceTable([d[0]]).titles.len == 0, "a line without a match"
      doAssert surveyStatus(Joined(), d[0]) == ssUnmatched
    block several:
      let t = traceTable(d, st)
      doAssert t.titles.len == 4 and t.titles[0].startsWith("From the survey, Trace 1: "), $t.titles
    block survey_gave_values:
      var g = d[0]
      g.joined = {jgSourceStation, jgReceiverXy}
      doAssert surveyStatus(j, g) == ssUnmatched
      let t = traceTable([g], [surveyStatus(j, g)])
      doAssert t.titles[0] == JoinedTitle, "the old group is unchanged: " & t.titles[0]
      doAssert t.rows[1].name == "keys.srcLine" and t.rows[1].joined == @[true]
    f.close()
  echo "tsurveyline: ok"

when isMainModule:
  main()
