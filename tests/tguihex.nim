## The Headers window's header tables in the running frontend, headless,
## with real clicks and keys: Find, the hex pane and the stanzas.
##
## A SEG-Y file with extended textual headers shown (parseSEG's demo
## post-stack line): File headers, Binary. Find "interval" keeps the fields
## that hold it (the sample interval, not the job's number); a click on the
## sample interval's value shows the binary header's bytes below the table,
## the field's highlighted, and its two bytes read every way; a click on it
## again hides them; Clear brings every field back. Stanzas lists the
## extended textual headers' stanzas; a click on
## another shows it. The file is never changed.
##
## The bytes lit in the dump are the field's: the binary header's sample
## interval (file bytes 3216 and 3217) in a big-endian and in a little-endian
## SEG-Y file, and a SEG-D BCD field that starts at a low nibble and takes three
## (general header 1's day of the year: the low nibble of byte 11 and both
## nibbles of byte 12), not the nibble of byte 11 before it; its readings are
## of those nibbles only (`byteReadings`).
##
## Seen to fail: with `covers` always true, the check of `covers`; with the click
## on a value not picking it (`ui.hex` left alone in `drawFieldTable`), "the bytes did not happen"; with Find not
## applied (`filtered` returning the table whole), "Find interval did not
## happen".
##
## The windows are kept inside the main one (`keepInMainWindow`): on a loaded machine a tooltip
## that reaches past the window edge becomes a window of its own in the very frame a click is
## sent, and Dear ImGui's SDL backend takes that window for the one under the pointer, so the
## click opens nothing (seen under `taskset -c 0` with busy loops: 14 of 20 runs failed, with
## no viewport but the main one 0 of 6).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves hex-*.png there.

import std/[math, monotimes, options, os, times]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import parseSEG
import viewSEG/view/byteview
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =

  block readings:
    # a field of three nibbles from the low nibble of its first byte
    let b = [0x11'u8, 0x23, 0x45]
    let own = byteReadings(b[0 .. 1], 1, 3)
    doAssert ("BCD", "123") in own, $own
    # SEG-D's all-F nibble field means "see the extended field", not a bad BCD.
    # Seen to fail: with every nibble read as BCD, "not BCD (a nibble past 9)".
    let extended = byteReadings([0x8F'u8, 0xFF], 1, 3)
    doAssert ("BCD", "all F (see the extended field)") in extended, $extended
    doAssert ("Nibbles", "123 (3 nibbles)") in own, $own
    doAssert ("Unsigned, binary", "291") in own, $own
    doAssert ("Integer, big-endian", "4387") notin own, "a whole-bytes reading of a nibble field"
    doAssert ("BCD", "112345") in byteReadings(b[0 .. 2]), $byteReadings(b[0 .. 2])
    let signed = byteReadings([0xFE'u8, 0xFF, 0xFF])
    doAssert ("Integer, little-endian", "-2") in signed, $signed
    doAssert ("Unsigned, little-endian", "16777214") in signed, $signed
    doAssert ("Integer, big-endian", "-65537") in signed, $signed
    doAssert covers(1, 3, 0, 0) == false and covers(1, 3, 0, 1) and covers(1, 3, 1, 1)
    doAssert covers(0, 0, 3, 1), "whole bytes"

  withFixtures fx:
    let path = fx.demoFile("survey.sgy")
    let little = fx.dir / "little.sgy"
    block:
      var w = openSeismicWriter(little, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
        byteOrder: boLittle))
      var k = initTraceKeys()
      (k.record, k.channel, k.intervalUs, k.status) = (1.0, 1.0, 2000.0, tsLive)
      for i in 0 ..< 3: w.writeTrace(k, newSeq[float32](20))
      doAssert w.close().len == 0
    let segd = fx.twoSetSegd()
    let before = (readFile(path), getLastModificationTime(path))
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    if shots.len > 0: createDir(shots)

    proc shoot(f: FrameInfo; file: string) =
      if shots.len > 0: doAssert f.savePng(shots / file), "cannot save " & file

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc click(f: FrameInfo; q: Vec2) =
      f.pressMouse(q, true, 1)
      f.pressMouse(q, false, 1)

    proc clickOn(name, mark: string; done: proc (f: FrameInfo): bool) =
      step(name & ": point", proc (f: FrameInfo) = f.moveMouse(f.markOf(mark).centre),
        proc (f: FrameInfo): bool = wait > 2 and f.markOf(mark).size.x > 0)
      step(name, proc (f: FrameInfo) = f.click(f.markOf(mark).centre), done)

    func shown(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

    const interval = "headers.binary binary.sampleInterval 0"
    step("shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len == 1 and f.shown("headers"))
    clickOn("File headers", "headers.tab file", proc (f: FrameInfo): bool =
      f.shown("headers.file tab Binary"))
    clickOn("Binary", "headers.file tab Binary", proc (f: FrameInfo): bool = f.shown(interval))
    clickOn("Find", "headers.binary find", proc (f: FrameInfo): bool = wait > 3)
    step("Find interval", proc (f: FrameInfo) = f.typeText("interval"),
      proc (f: FrameInfo): bool =
      result = wait > 3 and f.shown(interval) and not f.shown("headers.binary binary.jobId 0")
      if result: f.shoot("hex-find.png"))
    clickOn("the bytes", interval, proc (f: FrameInfo): bool =
      result = wait > 3 and f.shown("headers.hex field") and
        f.shown("headers.hex read Integer, big-endian")
      if result: f.shoot("hex-binary.png"))
    clickOn("hidden", interval, proc (f: FrameInfo): bool =
      wait > 3 and not f.shown("headers.hex"))
    clickOn("Clear", "headers.binary find clear", proc (f: FrameInfo): bool =
      wait > 3 and f.shown("headers.binary binary.jobId 0"))
    clickOn("Stanzas", "headers.file tab Stanzas", proc (f: FrameInfo): bool =
      result = wait > 3 and f.shown("headers.stanza") and f.shown("headers.stanzas 0")
      if result: f.shoot("hex-stanzas.png"))
    step("another stanza", noop, proc (f: FrameInfo): bool = wait > 1)
    clickOn("the second stanza", "headers.stanzas 1", proc (f: FrameInfo): bool =
      wait > 3 and f.shown("headers.stanza"))

    proc lit(f: FrameInfo): seq[string] =
      ## The bytes (and nibbles) lit in the dump, by file offset.
      for n in f.markNames("headers.hex lit "): result.add n["headers.hex lit ".len .. ^1]

    proc showFile(path: string) =
      step("show " & path.extractFilename, proc (f: FrameInfo) =
        f.apply(Command(kind: ckShowFile, panel: MainPanel, path: path)),
        proc (f: FrameInfo): bool =
        f.core.sessions.len >= 1 and f.core.sessions[^1].path == path and f.shown("headers"))

    const interval2 = "headers.binary binary.sampleInterval 0"
    # the big-endian file's interval, lit again, and the little-endian file's
    clickOn("the bytes again", "headers.file tab Binary", proc (f: FrameInfo): bool = wait > 3)
    clickOn("the interval's bytes", interval2, proc (f: FrameInfo): bool =
      result = wait > 3 and f.shown("headers.hex field")
      if result: doAssert f.lit == @["3216", "3217"], "the big-endian file lights " & $f.lit)
    showFile(little)
    # (the field stays picked across files: the dump lights it in this file's bytes)
    step("the little-endian interval's bytes", noop, proc (f: FrameInfo): bool =
      result = wait > 3 and f.shown("headers.hex field")
      if result: doAssert f.lit == @["3216", "3217"], "the little-endian file lights " & $f.lit)
    showFile(segd)
    const day = "headers.general gh1.julianDay 0"
    const blocks = "headers.general gh1.additionalGhBlocks 0"
    step("the SEG-D tab", noop, proc (f: FrameInfo): bool = f.shown(day))
    clickOn("the extra header blocks (one nibble)", blocks, proc (f: FrameInfo): bool =
      result = wait > 3 and f.shown("headers.hex field")
      if result: doAssert f.lit == @["11.0"], "the header blocks light " & $f.lit)
    clickOn("Find", "headers.general find", proc (f: FrameInfo): bool = wait > 3)
    step("Find julian", proc (f: FrameInfo) = f.typeText("julian"),
      proc (f: FrameInfo): bool = wait > 3 and f.shown(day) and not f.shown(blocks))
    clickOn("the day of the year", day, proc (f: FrameInfo): bool =
      result = wait > 3 and f.shown("headers.hex field") and f.lit.len > 1
      if result:
        doAssert f.lit == @["11.1", "12.0", "12.1"], "the day of the year lights " & $f.lit
        f.shoot("hex-segd-nibbles.png"))

    proc onFrame(f: FrameInfo) =
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if f.index == 0: f.keepInMainWindow # (see the module doc)
      if not started:
        steps[at].act(f)
        started = true
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(persist: false, logDir: some(fx.dir / "logs"), openPaths: @[path],
      windowSize: (1600, 1000), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
    echo "tguihex: ", steps.len, " steps"

when isMainModule:
  main()
