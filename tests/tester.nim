## Test runner: compiles and runs every `tests/t*.nim` file in a process of
## its own, several files at a time.
##
##   nim c -r tests/tester.nim [--jobs:N] [--runs:N] [--timeout:S] [flags] [files]
##
## - Compiler flags (`-d:release`, `-d:addressSanitizer`, ...) are passed to the
##   compiler for every test, so one runner build serves each mode (the test
##   tasks in config.nims).
## - `--jobs:N` works on N files at a time; the default is the number of CPU
##   cores. `--jobs:1` takes one file after another (`nim testSerial`).
## - `--runs:N`: of those, at most N are test runs (default an eighth of the
##   jobs), the others compiles.
## - `--timeout:S` stops a test whose run takes more than S seconds (default
##   300), or whose compile takes more than four times that, and reports it as
##   failed.
## - File names (`tgui` or `tgui.nim`) run only those files.
##
## What the files do not share:
## - **A display.** Each run gets a new Xvfb server (1920x1080x24, the screen
##   CI's xvfb-run gives), so windows, focus and the pointer are never shared and
##   the pointer starts at the screen's centre. DISPLAY names it; the Wayland
##   desktop, if any, is out of reach (no WAYLAND_DISPLAY, an empty runtime
##   folder), so no window reaches a desktop. Without Xvfb, or off POSIX, files
##   go one at a time in the environment as it is.
## - **Folders and builds.** Tests make their temporary folders per process (the
##   process id in the name, or `tests/utils/fixtures.nim`). Each file has its
##   own executable in `bin/` and its own Nim cache (the compiler's default,
##   named after the file); each compiler gets a share of the cores
##   (`--parallelBuild`), so that the C compilers of all jobs fit the machine.
## - **The CPU.** The GUI tests step in frames, but Dear ImGui keeps time in
##   seconds (key repeat, double clicks), and slow frames change what a test
##   sees. So compilers run at the lowest priority, at most an eighth of the
##   jobs are runs, and a run comes before a compile.
## - **Time.** A file whose header holds a line `## Runs alone: <why>` asserts a
##   time bound, measures times, or counts on frames as fast as an idle
##   machine's: it is compiled with the others and run by itself after all of
##   them, so their load cannot fail it.
##
## A file's output, the compiler's and the test's, is kept and printed whole
## when the file ends, under a line that says how it ended and how long it took.
## The run ends by naming the failed files, with exit code 1 if there are any.
## Ctrl+C stops every process the runner started. `bin/testtimes.txt` keeps how
## long each file took, so that the longest start first next time.
##
## Helper modules must not start with `t` (they live in `tests/utils/`).
##
## **Reject tests**, `tests/reject/r*.nim`, must *fail* to compile (to C, with
## the same flags): each holds a line `## Expect: <text>`, and the compiler's
## output must contain that text. They check contracts that `compiles()` cannot
## see, such as a `=copy` that is an error.

import std/[algorithm, monotimes, os, osproc, sequtils, strutils, tables, tempfiles, times]
when defined(posix):
  import std/posix
else:
  import std/streams

const
  DefaultTimeout = 300        ## seconds a run may take; a compile, four times that
  Screen = "1920x1080x24"
  AloneLine = "## Runs alone:"
  ExpectLine = "## Expect: "
  TimesFile = "testtimes.txt" ## in bin/: "<file> <compile s> <run s>" a line

type
  Step = enum
    compileStep, runStep

  TestFile = object
    path, name, exe, log: string
    reject: bool    ## must fail to compile, printing `want`
    want: string
    alone: bool     ## runs by itself, after the others
    took: array[Step, Duration]
    failure: string ## why it failed; "" while it passes
    done: bool      ## reported

  Options = object
    jobs, runs: int ## steps at a time, of which runs
    timeout: Duration
    flags, only: seq[string]

  Took = tuple[compile, run: float64] ## seconds

  Ended = object    ## how a process ended, once it has
    done: bool
    failure: string ## "" for exit code 0

proc header(path: string): seq[string] =
  ## The comment lines a test file starts with.
  for line in lines(path):
    if not line.startsWith("#"):
      return
    result.add line

proc expected(path: string): string =
  ## The text after `## Expect: ` in reject test `path`.
  for line in lines(path):
    if line.startsWith(ExpectLine):
      return line[ExpectLine.len .. ^1].strip
  ""

func seconds(d: Duration): string =
  formatFloat(d.inMilliseconds.float64 / 1000, ffDecimal, 1) & " s"

# --------------------------------------------------------------- processes --

var stopSignal: cint ## Ctrl+C, a hang-up or a kill, once one comes

when defined(posix):
  proc strsignal(sig: cint): cstring {.importc, header: "<string.h>".}
  proc setpriority(which: cint; who: Id; prio: cint): cint {.importc,
    header: "<sys/resource.h>".}
  var PRIO_PROCESS {.importc, header: "<sys/resource.h>".}: cint

  proc interrupted(sig: cint) {.noconv.} =
    stopSignal = sig

  proc spawn(argv, env: openArray[string]; log: string): Pid =
    ## Starts `argv` (its first item a path) with the environment `env`, in a
    ## process group of its own, reading nothing and appending its stdout and
    ## stderr to the file `log`.
    var actions: Tposix_spawn_file_actions
    var attr: Tposix_spawnattr
    discard posix_spawn_file_actions_init(actions)
    discard posix_spawn_file_actions_addopen(actions, 0, "/dev/null", O_RDONLY, Mode(0))
    discard posix_spawn_file_actions_addopen(actions, 1, log.cstring,
      O_WRONLY or O_CREAT or O_APPEND, Mode(0o644))
    discard posix_spawn_file_actions_adddup2(actions, 1, 2)
    discard posix_spawnattr_init(attr)
    discard posix_spawnattr_setflags(attr, POSIX_SPAWN_SETPGROUP)
    discard posix_spawnattr_setpgroup(attr, 0)
    let args = allocCStringArray(argv)
    let vars = allocCStringArray(env)
    let err = posix_spawn(result, argv[0].cstring, actions, attr, args, vars)
    deallocCStringArray(args)
    deallocCStringArray(vars)
    discard posix_spawn_file_actions_destroy(actions)
    discard posix_spawnattr_destroy(attr)
    if err != 0:
      raise newException(OSError, "cannot start " & argv[0] & ": " & $strerror(err))

  proc lowPriority(pid: Pid) =
    discard setpriority(PRIO_PROCESS, Id(pid), 19)

  func describe(status: cint): string =
    if WIFSIGNALED(status):
      "killed by signal " & $WTERMSIG(status) & " (" & $strsignal(WTERMSIG(status)) & ")"
    elif WEXITSTATUS(status) != 0:
      "exit code " & $WEXITSTATUS(status)
    else:
      ""

  proc ended(pid: Pid): Ended =
    ## Whether process `pid` has ended, and how.
    var status: cint
    let got = waitpid(pid, status, WNOHANG)
    if got == pid:
      result = Ended(done: true, failure: describe(status))
    elif got < 0:
      result = Ended(done: true, failure: "lost (" & $strerror(errno) & ")")

  proc stop(pid: Pid; sig = SIGKILL) =
    ## Sends `sig` to the process group of `pid`, and waits for `pid` to end:
    ## two seconds, then it is killed.
    discard killpg(pid, sig)
    let deadline = getMonoTime() + initDuration(seconds = 2)
    while not ended(pid).done:
      if getMonoTime() > deadline:
        discard killpg(pid, SIGKILL)
      sleep 5

  # ------------------------------------------------------------ displays --

  type Display = object ## an Xvfb server started for one run
    pid: Pid
    number: int

  var nextDisplay = 500 + int(getpid()) mod 100 * 50
    ## the display number to try next; far from xvfb-run's (99 up), and apart
    ## from another runner's

  proc taken(n: int): bool =
    ## Whether display `n` may be in use: a lock file, or a socket in
    ## /tmp/.X11-unix. That folder may be a host's, shared with a container,
    ## whose servers no lock file here tells of, and a new X server replaces
    ## the socket of its display: so a socket there is never taken over.
    for f in ["/tmp/.X" & $n & "-lock", "/tmp/.X11-unix/X" & $n]:
      if fileExists(f) or symlinkExists(f):
        return true
    false

  proc readLine(fd: cint; timeout: Duration): string =
    ## A line from `fd` within `timeout`; "" if it closes or the time passes.
    let deadline = getMonoTime() + timeout
    var buf: array[16, char]
    while '\n' notin result:
      let left = (deadline - getMonoTime()).inMilliseconds
      if left <= 0:
        return ""
      var p = TPollfd(fd: fd, events: POLLIN)
      let got = poll(addr p, 1, cint(left))
      if got < 0 and errno != EINTR: # a signal only cuts the wait short
        return ""
      if got > 0:
        let n = read(fd, addr buf, buf.len)
        if n <= 0:
          return ""
        for i in 0 ..< n:
          result.add buf[i]
    result = result.strip

  proc startDisplay(prefix: seq[string]; xvfb: string; env: seq[string];
      log: string): Display =
    ## A new Xvfb server on a display nobody uses, once it takes clients. A
    ## display another program takes at the same moment is lost in the race
    ## (the second server cannot listen) and the next number is tried.
    var failures = 0
    while result.pid == 0:
      let n = nextDisplay
      inc nextDisplay
      if not taken(n):
        var fds: array[0..1, cint]
        if pipe(fds) != 0:
          raiseOSError(osLastError(), "a pipe for Xvfb")
        discard fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        let pid = spawn(prefix & @[xvfb, ":" & $n, "-displayfd", $fds[1], "-screen", "0",
          Screen, "-nolisten", "tcp"], env, log)
        discard close(fds[1])
        let ready = readLine(fds[0], initDuration(seconds = 10)) == $n
        discard close(fds[0])
        if ready:
          result = Display(pid: pid, number: n)
        else:
          stop(pid, SIGTERM) # a killed X server leaves its socket behind
          inc failures
          if failures == 20:
            raise newException(OSError, "Xvfb does not start:\n" & readFile(log))

  proc stopDisplay(d: var Display) =
    if d.pid > 0:
      stop(d.pid, SIGTERM) # it removes its socket
      d = Display()

else:
  # One process at a time here (`--jobs` is 1): `spawn` runs it to its end.
  type
    Pid = int
    Display = object
      number: int

  var lastEnded: Ended

  proc spawn(argv, env: openArray[string]; log: string): Pid =
    ## Runs `argv` to its end in this environment, appending its output to
    ## `log`.
    let p = startProcess(argv[0], args = argv[1 .. ^1], options = {poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    let f = open(log, fmAppend)
    f.write output
    f.close()
    lastEnded = Ended(done: true, failure: if code == 0: "" else: "exit code " & $code)
    1

  proc lowPriority(pid: Pid) = discard
  proc ended(pid: Pid): Ended = lastEnded
  proc stop(pid: Pid) = discard
  proc stopDisplay(d: var Display) = discard

# ------------------------------------------------------------------ runner --

type
  Job = object ## a step being taken
    file: int
    step: Step
    pid: Pid
    started: MonoTime
    display: Display

  Runner = object
    opts: Options
    files: seq[TestFile]
    nim, testDir, binDir, logDir, xvfb: string
    prefix: seq[string]     ## what a run or a display is started through
    env, runEnv, build: seq[string]
    queue: seq[(int, Step)] ## what can start, the next first
    later: seq[int]         ## compiled, waiting to run alone
    jobs: seq[Job]
    slots, runSlots: int
    reported: int

proc parseOptions(params: seq[string]): Options =
  result = Options(jobs: countProcessors(), timeout: initDuration(seconds = DefaultTimeout))
  for p in params:
    let (key, value) = (p.split(':', 1)[0], p.split(':', 1)[^1])
    if key in ["--jobs", "-j"]:
      result.jobs = parseInt(value)
    elif key == "--runs":
      result.runs = parseInt(value)
    elif key == "--timeout":
      result.timeout = initDuration(seconds = parseInt(value))
    elif p.startsWith("-"):
      result.flags.add p
    else:
      result.only.add p.changeFileExt("nim")
  result.jobs = max(1, result.jobs)
  result.runs = if result.runs > 0: min(result.runs, result.jobs) else: max(1, result.jobs div 8)

proc testFiles(testDir, binDir, logDir: string; only: seq[string]): seq[TestFile] =
  ## The test files (all, or those named in `only`), then the reject tests.
  for f in walkFiles(testDir / "t*.nim"):
    let name = f.extractFilename
    if name != "tester.nim" and (only.len == 0 or name in only):
      result.add TestFile(path: f, name: name, log: logDir / name & ".log",
        exe: binDir / name.changeFileExt(ExeExt),
        alone: header(f).anyIt(it.startsWith(AloneLine)))
  for name in only:
    if not result.anyIt(it.name == name):
      quit "FAILURE no test file " & name & " in " & testDir
  if only.len == 0:
    for f in walkFiles(testDir / "reject" / "r*.nim"):
      result.add TestFile(path: f, name: "reject/" & f.extractFilename, reject: true,
        want: expected(f), log: logDir / f.extractFilename & ".log")

proc readTimes(path: string): Table[string, Took] =
  ## The seconds each file took last time.
  if fileExists(path):
    for line in lines(path):
      let parts = line.splitWhitespace
      if parts.len == 3:
        try:
          result[parts[0]] = (parseFloat(parts[1]), parseFloat(parts[2]))
        except ValueError:
          discard # a damaged line: that file counts as new

proc writeTimes(r: Runner) =
  ## Keeps how long each file took, with the times of the files not run now
  ## (while they exist).
  let path = r.binDir / TimesFile
  var times = readTimes(path)
  for f in r.files:
    if f.done and not f.reject:
      times[f.name] = (f.took[compileStep].inMilliseconds / 1000,
        f.took[runStep].inMilliseconds / 1000)
  var text = ""
  for name in toSeq(times.keys).sorted:
    if fileExists(r.testDir / name):
      text.add name & " " & $times[name].compile & " " & $times[name].run & "\n"
  createDir(r.binDir)
  writeFile(path, text)

proc initRunner(opts: Options): Runner =
  let testDir = currentSourcePath().parentDir
  result = Runner(opts: opts, nim: getCurrentCompilerExe(), testDir: testDir,
    binDir: testDir.parentDir / "bin", logDir: createTempDir("viewseg-tests-", ""))
  result.files = testFiles(testDir, result.binDir, result.logDir, opts.only)
  if result.files.len == 0:
    quit "FAILURE no tests found in " & testDir
  when defined(posix):
    result.xvfb = findExe("Xvfb")
    if defined(linux) and findExe("setpriv").len > 0:
      # a run, or a display, ends when the runner does, even killed outright
      result.prefix = @[findExe("setpriv"), "--pdeathsig", "TERM", "--"]
  result.slots = if result.xvfb.len > 0: min(opts.jobs, result.files.len) else: 1
  result.runSlots = min(opts.runs, result.slots)
  for key, value in envPairs():
    result.env.add key & "=" & value
    if result.xvfb.len == 0 or key notin ["DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]:
      result.runEnv.add key & "=" & value
  if result.xvfb.len > 0:
    # Wayland's default socket is looked for in the runtime folder: an empty
    # one keeps every window on Xvfb, as on CI.
    let runtime = result.logDir / "runtime"
    createDir(runtime)
    setFilePermissions(runtime, {fpUserRead, fpUserWrite, fpUserExec})
    result.runEnv.add "XDG_RUNTIME_DIR=" & runtime
  result.build = @["--hints:off",
    "--parallelBuild:" & $max(1, countProcessors() div result.slots)]
  # The longest runs first (new files count as longest), the files that run
  # alone last: they wait for the others anyway.
  let times = readTimes(result.binDir / TimesFile)
  proc cost(f: TestFile): (bool, float64, float64) =
    let t = times.getOrDefault(f.name, (Inf, Inf))
    (f.alone, -t.run, -t.compile)
  var order = toSeq(0 ..< result.files.len)
  let files = result.files
  order.sort(proc (a, b: int): int = cmp(cost(files[a]), cost(files[b])))
  for i in order:
    result.queue.add (i, compileStep)

proc start(r: Runner; i: int; step: Step): Job =
  let f = r.files[i]
  result = Job(file: i, step: step, started: getMonoTime())
  if step == compileStep:
    let args = if f.reject:
                 @["--compileOnly", "--path:" & r.testDir.parentDir / "src",
                   "--nimcache:" & r.logDir / "cache-" & f.path.extractFilename]
               else: @["--out:" & f.exe]
    result.pid = spawn(@[r.nim, "c"] & r.build & r.opts.flags & args & @[f.path], r.env, f.log)
    lowPriority(result.pid)
  else:
    var env = r.runEnv
    when defined(posix):
      if r.xvfb.len > 0:
        result.display = startDisplay(r.prefix, r.xvfb, r.env, r.logDir / f.name & ".xvfb.log")
        env.add "DISPLAY=:" & $result.display.number
    result.pid = spawn(r.prefix & @[f.exe], env, f.log)

proc report(r: var Runner; f: var TestFile) =
  inc r.reported
  f.done = true
  let output = if fileExists(f.log): readFile(f.log) else: ""
  let took = if f.reject: ""
             else: " (compile " & seconds(f.took[compileStep]) & (if f.took[runStep] >
               Duration(): ", run " & seconds(f.took[runStep]) else: "") & ")"
  echo "[", align($r.reported, len($r.files.len)), "/", r.files.len, "] ", f.name,
    (if f.failure.len == 0: ": passed" else: ": FAILED, " & f.failure), took
  if output.len > 0:
    stdout.write output
    if not output.endsWith("\n"):
      stdout.write "\n"
  elif f.failure.len > 0:
    echo "  (no output)"
  flushFile(stdout)

proc finish(r: var Runner; j: var Job; e: Ended) =
  ## Step `j` ended as `e`: what follows from it.
  let i = j.file
  r.files[i].took[j.step] = getMonoTime() - j.started
  stopDisplay(j.display)
  template f: untyped = r.files[i]
  if j.step == compileStep and f.reject:
    if e.failure.len == 0:
      f.failure = "compiled, but must not"
    elif f.want.len == 0:
      f.failure = "no `" & ExpectLine.strip & "` line"
    elif f.want notin readFile(f.log):
      f.failure = "did not compile, but without `" & f.want & "`"
    r.report(f)
  elif j.step == compileStep and e.failure.len > 0:
    f.failure = "did not compile, " & e.failure
    r.report(f)
  elif j.step == compileStep and f.alone:
    r.later.add i
  elif j.step == compileStep:
    r.queue.insert((i, runStep), 0)
  else:
    f.failure = e.failure
    let xlog = r.logDir / f.name & ".xvfb.log"
    if e.failure.len > 0 and fileExists(xlog) and readFile(xlog).len > 0:
      let output = open(f.log, fmAppend)
      output.write "Xvfb's output:\n" & readFile(xlog)
      output.close()
    r.report(f)

proc next(r: Runner): int =
  ## Where in the queue the next step to start is: a run if one may start,
  ## else a compile; -1 for none.
  let runsFree = r.jobs.countIt(it.step == runStep) < r.runSlots
  for k, (i, step) in r.queue:
    if step == compileStep or runsFree:
      return k
  -1

proc runAll(r: var Runner) =
  ## Runs everything, unless a signal stops the runner.
  while r.reported < r.files.len and stopSignal == 0:
    if r.jobs.len == 0 and r.queue.len == 0:
      # all the others are done: the files that run alone, one by one
      doAssert r.later.len > 0, "nothing left to start"
      for i in r.later:
        r.queue.add (i, runStep)
      r.later.setLen 0
      (r.slots, r.runSlots) = (1, 1)
    var k = r.next
    while r.jobs.len < r.slots and k >= 0:
      let (i, step) = r.queue[k]
      r.queue.delete k
      try:
        r.jobs.add r.start(i, step)
      except OSError as e:
        r.files[i].failure = "could not start: " & e.msg
        r.report(r.files[i])
      k = r.next
    sleep 10
    k = 0
    while k < r.jobs.len:
      var e = ended(r.jobs[k].pid)
      let limit = if r.jobs[k].step == runStep: r.opts.timeout else: r.opts.timeout * 4
      if not e.done and getMonoTime() - r.jobs[k].started > limit:
        stop(r.jobs[k].pid)
        e = Ended(done: true, failure: "timed out after " & $limit.inSeconds & " s, stopped")
      if e.done:
        r.finish(r.jobs[k], e)
        r.jobs.delete k
      else:
        inc k

proc main() =
  var r = initRunner(parseOptions(commandLineParams()))
  when defined(posix):
    for sig in [SIGINT, SIGTERM, SIGHUP]:
      discard signal(sig, interrupted)
  let alone = r.files.countIt(it.alone)
  echo "Testing ", r.files.len, " files", r.opts.flags.mapIt(" " & it).join, " (", r.slots,
    " at a time, ", r.runSlots, (if r.runSlots == 1: " run" else: " runs"),
    (if r.xvfb.len > 0: ", each on a display of its own" else: ""),
    (if alone > 0: "; " & $alone & " run alone at the end" else: ""), ")"
  if r.xvfb.len == 0 and r.opts.jobs > 1:
    echo "  no Xvfb: one file at a time, on the display this environment has"
  let began = getMonoTime()
  try:
    r.runAll()
  finally:
    for j in r.jobs.mitems:
      stop(j.pid)
      stopDisplay(j.display)
    removeDir(r.logDir)
  r.writeTimes()
  if stopSignal != 0:
    quit "Stopped by signal " & $stopSignal & " (" & $r.reported & " of " & $r.files.len &
      " files done)"
  var slowest = r.files.filterIt(not it.reject)
  slowest.sort(proc (a, b: TestFile): int =
    cmp(b.took[compileStep] + b.took[runStep], a.took[compileStep] + a.took[runStep]))
  let aloneRuns = r.files.filterIt(it.alone).mapIt(it.took[runStep])
  echo r.files.len, " test files in ", seconds(getMonoTime() - began),
    (if alone > 0: " (the " & $alone & " run alone: " &
      seconds(aloneRuns.foldl(a + b, Duration())) & ")" else: ""),
    "; the slowest: ", slowest[0 ..< min(3, slowest.len)].mapIt(it.name & " " &
      seconds(it.took[compileStep] + it.took[runStep])).join(", ")
  let failed = r.files.filterIt(it.failure.len > 0)
  for f in failed:
    echo "  FAILED ", f.name, ": ", f.failure
  if failed.len > 0:
    quit "FAILURE " & $failed.len & " of " & $r.files.len & " test files: " &
      failed.mapIt(it.name).join(", ")
  echo "All ", r.files.len, " test files passed."

main()
