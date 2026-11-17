## Edit > Select all traces (Ctrl+A) selects every trace the Seismic window shows, in the
## running frontend, on the fixture of four seismic traces and one auxiliary one: with the
## default (seismic only) the four; with the auxiliary switch on and seismic off, the one;
## clicking the menu item is the real path (the key is the menu's own shortcut, which a
## text box keeps for itself, see `tshortcuts`). The agent's `select` carries the same as
## `all`.
##
## Seen to fail: with the handler selecting the whole file, "four seismic traces" saw 5; with
## the menu item missing, "the menu item did not happen".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, panels, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =
  withFixtures fx:
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    var tries = 0
    proc click(f: FrameInfo; mark: string): bool =
      let r = f.markOf(mark)
      inc tries
      if r.size.x > 0 and tries mod 6 == 3:
        f.moveMouse(r.centre)
        f.pressMouse(r.centre, true)
        f.pressMouse(r.centre, false)
        true
      else: false
    proc selectAllByMenu(what: string; want: int) =
      var opened = false
      step("Edit > Select all traces: " & what, proc (f: FrameInfo) = opened = false,
        proc (f: FrameInfo): bool =
        if not opened:
          if f.markOf("menu.Select all traces").size.x == 0:
            discard f.click("menu.Edit")
          else: opened = f.click("menu.Select all traces")
          return false
        f.core.selection.selectedCount == want)
    step("the record", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and p.shown.len > 0)
    selectAllByMenu("four seismic traces", 4)
    step("the auxiliary one only", proc (f: FrameInfo) =
      f.apply(Command(kind: ckFilter, panel: MainPanel,
        filter: TraceFilter(seismic: false, auxiliary: true))),
      proc (f: FrameInfo): bool =
        let p = f.core.panels[f.core.findPanel(MainPanel)]
        p.shown.len == 1)
    step("clear", proc (f: FrameInfo) = f.apply(Command(kind: ckClearSelection)),
      proc (f: FrameInfo): bool = f.core.selection.selectedCount == 0)
    step("select with `all`", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelect, all: true, mode: smReplace)),
      proc (f: FrameInfo): bool = f.core.selection.selectedCount == 1)

    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
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
    let code = run(RunOptions(openPaths: @[fx.spectrumAuxSegy()],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiselectall: ok"

when isMainModule: main()
