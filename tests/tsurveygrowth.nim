## How the cost of survey files grows with their size: a survey of
## `tests/utils/bigsurvey` at a thousandth and at a hundredth of a real 3D
## survey's size (X 30 000 and 300 000 records), loaded onto the map, then
## imported for a SEG-Y file whose traces are about ten times as many in the
## larger: ten times the records must not cost more than about twelve times
## the time (the faster of three tries each), and the UI thread never takes
## long over what the jobs hand it (a drain of the inbox, what a frame pays).
##
## A trace's plan (each matched) costs against the larger survey what it
## does against the smaller: it allocates nothing a trace, and takes about
## as long. The checks are made to hold on a busy machine: the fastest of
## several tries, the median of their longest drains, and the plan's cost
## counted as allocations as well as timed.
##
## Seen to fail: with the plan of the join copying the station table for
## each end of each trace (the `addr` taken out in `planJoin`), a trace's plan
## cost 13.8 us against the smaller survey and 54.2 us against the larger
## (the import as a whole grew only 7.6 times: the read is most of it at
## these sizes); counted, 2.0012 and 2.0001 allocations a trace (0.0012 and
## 0.0001 without the copy).
##
## Runs alone: it times reads and bounds the UI thread's drains.

import std/[algorithm, monotimes, os, strutils, times]
import parseSEG
import viewSEG/core/[jobs, join, state, survey]
import utils/[bigsurvey, fixtures, waiting]

type Tried = tuple[loadMs, importMs, drainMs: float64]

func ms(d: Duration): float64 = float64(d.inMicroseconds) / 1000

proc drained(st: var AppState; worst: var float64) =
  let t0 = getMonoTime()
  discard st.drainInbox()
  worst = max(worst, ms(getMonoTime() - t0))

proc waitFor(st: var AppState; worst: var float64; cond: proc (st: AppState): bool) =
  doAssert waitUntil((st.drained(worst); cond(st) and st.jobs.active.len == 0 and
    (st.drained(worst); cond(st)))), "the survey's jobs did not end"

proc tryOnce(f: BigSurveyFiles; segy: string): Tried =
  # Loaded onto the map with no file open.
  block:
    var st = initAppState()
    let t0 = getMonoTime()
    st.apply Command(kind: ckLoadSurvey, paths: @[f.s, f.r, f.x])
    st.waitFor(result.drainMs, proc (st: AppState): bool = st.survey.layers.len == 3)
    result.loadMs = ms(getMonoTime() - t0)
    discard st.shutdown()
  # Imported for an open file: read, planned, joined.
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy)
  st.waitFor(result.drainMs, proc (st: AppState): bool =
    st.sessions.len == 1 and st.survey.findTraces(st.sessions[0].id) >= 0)
  let before = st.joinReport.serial
  var files: seq[JoinFile]
  for p in [f.s, f.r, f.x]: files.add JoinFile(path: p, kind: jkSps)
  let t0 = getMonoTime()
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: files)
  st.waitFor(result.drainMs, proc (st: AppState): bool = st.joinReport.serial > before)
  result.importMs = ms(getMonoTime() - t0)
  doAssert st.joinReport.outcome == joJoined, $st.joinReport.outcome
  doAssert st.joinReport.unmatched == 0
  discard st.shutdown()

proc best(f: BigSurveyFiles; segy: string): Tried =
  ## The fastest of three tries, and the median of their longest drains (a
  ## drain that is slow by its work is slow every time; one preempted on a
  ## busy machine, once).
  result = (Inf, Inf, 0.0)
  var drains: seq[float64]
  for _ in 0 ..< 3:
    let t = tryOnce(f, segy)
    result = (min(result.loadMs, t.loadMs), min(result.importMs, t.importMs), 0.0)
    drains.add t.drainMs
  result.drainMs = drains.sorted[1]

func traces(b: BigSurvey; shots: int): int =
  for (i, k) in b.spreadShots(shots):
    let p = b.patch(i, k)
    result += p.lines.len * p.points.len

withFixtures fx:
  let (small, large) = (bigSurveyShape(0.001), bigSurveyShape(0.01))
  # About ten times the traces in the larger survey's file.
  let few = 2
  var many = 1
  while large.traces(many) < 10 * small.traces(few): inc many
  let (fa, fb) = (writeBigSurvey(fx.dir / "small", small), writeBigSurvey(fx.dir / "large", large))
  let a = best(fa, writeBigSegy(fx.dir / "small", small, few))
  let b = best(fb, writeBigSegy(fx.dir / "large", large, many))
  func f1(x: float64): string = formatFloat(x, ffDecimal, 1)
  echo "tsurveygrowth: X ", getFileSize(fa.x) div 81, " -> ", getFileSize(fb.x) div 81,
    " records, traces ",
    small.traces(few), " -> ", large.traces(many), ": load ", f1(a.loadMs), " -> ", f1(b.loadMs),
    " ms (", f1(b.loadMs / a.loadMs), "x), import ", f1(a.importMs), " -> ", f1(b.importMs),
    " ms (", f1(b.importMs / a.importMs), "x); longest drain ", f1(max(a.drainMs, b.drainMs)), " ms"
  # A little over ten times, and a few ms for what a read costs whatever its
  # size (threads, the first chunk alone).
  doAssert b.loadMs <= 12 * a.loadMs + 20, "the load grew " & f1(b.loadMs / a.loadMs) & "x"
  doAssert b.importMs <= 12 * a.importMs + 20, "the import grew " &
    f1(b.importMs / a.importMs) & "x"
  doAssert b.drainMs < 20, "a drain of the inbox took " & f1(b.drainMs) & " ms"
  # The plan of each survey's file: what a trace costs (each matched) does
  # not grow with the survey (a lookup by station). Counted as allocations,
  # which a busy machine does not change: a copy of a station table (the
  # mistake this was written for) is one or more a lookup, two a trace;
  # timed too (the fastest of five tries, the two surveys in turn), within
  # three times and 2 us (a larger table misses the caches more: 1.1 to 1.9
  # times here).
  var perTrace: array[2, float64] = [Inf, Inf]
  var allocsPerTrace: array[2, float64]
  proc allocs(): int = cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs
  var files: array[2, SeismicFile]
  var geometry: array[2, SurveyGeometry]
  for k, (f, segy) in [(fa, writeBigSegy(fx.dir / "small", small, few)),
      (fb, writeBigSegy(fx.dir / "large", large, many))]:
    files[k] = openSeismic(segy, keys = true)
    geometry[k] = initSurveyGeometry()
    for p in [f.s, f.r, f.x]: geometry[k].addSps(p)
  for _ in 0 ..< 5:
    for k in 0 .. 1:
      let a0 = allocs()
      let t0 = getMonoTime()
      let plan = planJoin(addr files[k], geometry[k], JoinOptions(),
        proc (done, total: int): bool = true)
      perTrace[k] = min(perTrace[k], 1000 * ms(getMonoTime() - t0) / float64(files[k].len))
      allocsPerTrace[k] = float64(allocs() - a0) / float64(files[k].len)
      doAssert plan.traces == files[k].len and plan.matched == files[k].len, $plan.matched
  for f in files.mitems: f.close()
  echo "tsurveygrowth: a trace's plan ", f1(perTrace[0]), " us against the smaller survey, ",
    f1(perTrace[1]), " us against the larger; allocations a trace ",
    formatFloat(allocsPerTrace[0], ffDecimal, 4), " and ",
    formatFloat(allocsPerTrace[1], ffDecimal, 4)
  for k in 0 .. 1:
    doAssert allocsPerTrace[k] < 0.5, "a trace's plan allocates: " &
      formatFloat(allocsPerTrace[k], ffDecimal, 4) & " a trace (a table copied?)"
  doAssert perTrace[1] <= 3 * perTrace[0] + 2, "a trace's plan grew with the survey: " &
    f1(perTrace[0]) & " -> " & f1(perTrace[1]) & " us"
