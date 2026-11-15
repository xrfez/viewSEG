## Survey files at the scale of a real 3D land survey: how long reading,
## loading and importing them takes, how much memory they take, and how
## much of it the UI thread pays. The surveys are written by
## `tests/utils/bigsurvey` (at scale 1: R 200 000 points, S 2 000 000, X
## about 30 million records, 2.5 GB).
##
##   nim surveyBench [dir] [scales...]   (default: a temporary folder, 0.01 0.1)
##   nim c -d:release -o:<bin> tools/surveybench.nim
##   <bin> all <dir> 0.1 0.3 1        each measurement in a process of its own, a table
##   <bin> gen <dir> <scale>          writes the files (kept if there)
##   <bin> parse <file>               parseSEG's readSps (no raw text)
##   <bin> geometry <files...>        parseSEG's addSps of each into one geometry
##   <bin> load <files...>            viewSEG: the files loaded onto the map (ckLoadSurvey)
##   <bin> import <segy> <files...>   viewSEG: the file opened, the survey imported (ckJoin)
##   <bin> cancel <segy> <files...>   viewSEG: the import cancelled in each of its phases
##
## Each measurement prints one line `key=value ...`: wall time (ms), the peak
## resident memory of the process (`peakMB`), what it holds once done
## (`heldMB`, after a full collection), the longest the UI thread spent
## taking in a job's results in one go (`uiMs`: `drainInbox`, what a frame
## pays), and the longest a running job went without a word of progress
## (`quietMs`). The map's drawing is measured by `tools/mapbench.nim`.

import std/[monotimes, os, osproc, strutils, tables, times]
import parseSEG
import ../src/viewSEG/core/[jobs, join, state, survey]
import ../tests/utils/bigsurvey

func ms(d: Duration): float64 = float64(d.inMicroseconds) / 1000

proc statusKb(field: string): int =
  ## A field of /proc/self/status, in KiB.
  for line in lines("/proc/self/status"):
    if line.startsWith(field & ":"):
      return parseInt(line.split(':')[1].strip.split(' ')[0])

proc peakMB(): int = statusKb("VmHWM") div 1024
proc heldMB(): int =
  GC_fullCollect()
  statusKb("VmRSS") div 1024

proc fmt1(x: float64): string = formatFloat(x, ffDecimal, 1)

# ------------------------------------------------------------- parseSEG --

proc parse(path: string) =
  let t0 = getMonoTime()
  let f = readSps(path, SpsOptions(keepRaw: false))
  let t = ms(getMonoTime() - t0)
  echo "parse file=", path.extractFilename, " ms=", fmt1(t), " points=", f.points.len,
    " relations=", f.relations.len, " peakMB=", peakMB(), " heldMB=", heldMB(),
    " MBps=", fmt1(float64(getFileSize(path)) / 1e6 / (t / 1000))

proc geometry(paths: seq[string]) =
  var g = initSurveyGeometry()
  var parts: seq[string]
  let t0 = getMonoTime()
  for p in paths:
    let t1 = getMonoTime()
    g.addSps(p)
    parts.add p.extractFilename & ":" & fmt1(ms(getMonoTime() - t1))
  echo "geometry ms=", fmt1(ms(getMonoTime() - t0)), " each=", parts.join(","),
    " sources=", g.sourceCount, " receivers=", g.receiverCount, " runs=", g.relationCount,
    " peakMB=", peakMB(), " heldMB=", heldMB()

# --------------------------------------------------------------- viewSEG --

type Watch = object
  ## What the UI thread sees of the jobs while it waits for them.
  start: MonoTime
  uiMs: float64           ## the longest drain
  quietMs: float64        ## the longest a running job went without new progress
  phases: seq[(string, float64)] ## each job phase seen, and when (ms from the start)
  seen: Table[JobId, (JobProgress, MonoTime)]

proc look(w: var Watch; st: var AppState) =
  let t0 = getMonoTime()
  discard st.drainInbox()
  let now = getMonoTime()
  w.uiMs = max(w.uiMs, ms(now - t0))
  for j in st.jobs.active:
    if j.state == jsRunning:
      let p = j.progress
      if j.id notin w.seen or w.seen[j.id][0] != p:
        if j.id notin w.seen or w.seen[j.id][0].phase != p.phase:
          w.phases.add (j.spec.title & ": " & p.phase, ms(now - w.start))
        w.seen[j.id] = (p, now)
      else:
        w.quietMs = max(w.quietMs, ms(now - w.seen[j.id][1]))

proc waitFor(w: var Watch; st: var AppState; cond: proc (st: AppState): bool;
    timeout = initDuration(minutes = 30)) =
  let deadline = getMonoTime() + timeout
  while true:
    w.look(st)
    if cond(st) and st.jobs.active.len == 0:
      w.look(st)
      if cond(st): return
    if getMonoTime() > deadline: quit "timed out", 2
    sleep 1

proc phasesText(w: Watch): string =
  var parts: seq[string]
  for (p, t) in w.phases: parts.add "[" & fmt1(t) & "] " & p
  parts.join(" | ")

proc load(paths: seq[string]) =
  var st = initAppState()
  let base = heldMB()
  var w = Watch(start: getMonoTime())
  st.apply Command(kind: ckLoadSurvey, paths: paths)
  w.waitFor(st, proc (st: AppState): bool = st.survey.layers.len == paths.len)
  let t = ms(getMonoTime() - w.start)
  var points = 0
  for l in st.survey.layers:
    for r in PointRole: points += l.points[r].len
  echo "load ms=", fmt1(t), " points=", points, " uiMs=", fmt1(w.uiMs), " quietMs=",
    fmt1(w.quietMs), " peakMB=", peakMB(), " heldMB=", heldMB() - base
  echo "  phases: ", w.phasesText
  st.shutdown()

proc opened(st: var AppState; w: var Watch; segy: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy)
  w.waitFor(st, proc (st: AppState): bool =
    st.sessions.len == 1 and st.survey.findTraces(st.sessions[0].id) >= 0)

proc joinFiles(paths: seq[string]): seq[JoinFile] =
  for p in paths: result.add JoinFile(path: p, kind: jkSps)

proc importSurvey(segy: string; paths: seq[string]) =
  var st = initAppState()
  var w = Watch(start: getMonoTime())
  st.opened(w, segy)
  let base = heldMB()
  w = Watch(start: getMonoTime())
  let before = st.joinReport.serial
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: joinFiles(paths))
  w.waitFor(st, proc (st: AppState): bool = st.joinReport.serial > before)
  let t = ms(getMonoTime() - w.start)
  echo "import ms=", fmt1(t), " outcome=", st.joinReport.outcome, " traces=",
    st.sessions[0].file.len, " uiMs=", fmt1(w.uiMs), " quietMs=", fmt1(w.quietMs),
    " peakMB=", peakMB(), " heldMB=", heldMB() - base
  echo "  phases: ", w.phasesText
  echo "  words: ", st.joinReport.words.join(" ")
  st.shutdown()

proc cancelIn(segy: string; paths: seq[string]) =
  ## The import cancelled once in each phase it goes through: from the
  ## cancel to the end of the import, and whether the map and the file are
  ## as they were.
  var phases: seq[string]
  block:
    # The phases, from an import left to finish.
    var st = initAppState()
    var w = Watch(start: getMonoTime())
    st.opened(w, segy)
    w = Watch(start: getMonoTime())
    let before = st.joinReport.serial
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: joinFiles(paths))
    w.waitFor(st, proc (st: AppState): bool = st.joinReport.serial > before)
    for (p, _) in w.phases:
      if p notin phases: phases.add p
    st.shutdown()
  for phase in phases:
    var st = initAppState()
    var w = Watch(start: getMonoTime())
    st.opened(w, segy)
    let layers = st.survey.layers.len
    let before = st.joinReport.serial
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: joinFiles(paths))
    var asked = MonoTime()
    var cancelled: seq[JobId]
    while st.joinReport.serial == before or st.jobs.active.len > 0:
      w.look(st)
      if asked == MonoTime():
        for j in st.jobs.active:
          if j.state == jsRunning and j.spec.title & ": " & j.progress.phase == phase:
            asked = getMonoTime()
        if asked != MonoTime():
          for j in st.jobs.active:
            cancelled.add j.id
            st.apply Command(kind: ckCancelJob, job: j.id)
      sleep 1
    let t = if asked == MonoTime(): -1.0 else: ms(getMonoTime() - asked)
    echo "cancel phase=\"", phase, "\" endMs=", fmt1(t), " outcome=", st.joinReport.outcome,
      " layersAfter=", st.survey.layers.len - layers, " keysRevision=",
      st.sessions[0].file.keysRevision, " uiMs=", fmt1(w.uiMs)
    st.shutdown()

# ------------------------------------------------------------------- all --

proc run(exe: string; args: seq[string]): seq[string] =
  let p = startProcess(exe, args = args, options = {poStdErrToStdOut})
  for line in p.lines: result.add line
  discard p.waitForExit()
  p.close()

func field(line, key: string): string =
  for part in line.splitWhitespace:
    if part.startsWith(key & "="): return part[key.len + 1 .. ^1]
  "-"

proc all(dir: string; scales: seq[float64]) =
  let exe = getAppFilename()
  for scale in scales:
    let shape = bigSurveyShape(scale)
    let t0 = getMonoTime()
    let f = writeBigSurvey(dir, shape)
    let segy = writeBigSegy(dir, shape)
    echo "## scale ", scale, ": R ", shape.receivers, ", S ", shape.sources, ", X ",
      getFileSize(f.x) div 81, " records (", getFileSize(f.x) div 1_000_000, " MB); written in ",
      fmt1(ms(getMonoTime() - t0)), " ms"
    for p in [f.s, f.r, f.x]:
      for line in run(exe, @["parse", p]): echo line
    for line in run(exe, @["geometry", f.s, f.r, f.x]): echo line
    for line in run(exe, @["load", f.s, f.r, f.x]): echo line
    for line in run(exe, @["import", segy, f.s, f.r, f.x]): echo line
    for line in run(exe, @["cancel", segy, f.s, f.r, f.x]): echo line

proc main() =
  let args = commandLineParams()
  if args.len < 1: quit "usage: surveybench all|gen|parse|geometry|load|import|cancel ..."
  case args[0]
  of "all":
    let dir = if args.len > 1: args[1] else: getTempDir() / "viewseg-surveybench"
    var scales: seq[float64]
    for s in args[min(2, args.len) .. ^1]: scales.add parseFloat(s)
    if scales.len == 0: scales = @[0.01, 0.1]
    all(dir, scales)
  of "gen":
    let shape = bigSurveyShape(parseFloat(args[2]))
    let f = writeBigSurvey(args[1], shape)
    echo f, " ", writeBigSegy(args[1], shape)
  of "parse": parse(args[1])
  of "geometry": geometry(args[1 .. ^1])
  of "load": load(args[1 .. ^1])
  of "import": importSurvey(args[1], args[2 .. ^1])
  of "cancel": cancelIn(args[1], args[2 .. ^1])
  else: quit "unknown measurement " & args[0]

main()
