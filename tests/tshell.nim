## The shell's event delivery: Nim threads pushing into a `ShellQueue`, and SDL
## dialog results arriving through the C-side callback from another thread,
## both drained on the main thread in order. No dialog is opened.

import std/strutils
import viewSEG/ui/imgui/shell {.all.}

const
  producers = 4
  perProducer = 250

type Job = tuple[q: ptr ShellQueue; id: int]

proc produce(job: Job) {.thread.} =
  for i in 0 ..< perProducer:
    job.q[].push ShellEvent(kind: sePathsChosen, dialog: dkOpenFiles,
      paths: @[$job.id & ":" & $i])

proc fakeDialogs(unused: int) {.thread.} =
  ## What SDL does on Windows: call the dialog callback from its own thread.
  var chosen = [cstring"/data/a.sgy", cstring"/data/b ü.segd", nil]
  onDialogResult(cast[pointer](dkOpenFiles.int), addr chosen[0], -1)
  var none = [cstring(nil)]
  onDialogResult(cast[pointer](dkOpenFolder.int), addr none[0], -1)
  onDialogResult(cast[pointer](dkOpenFile.int), nil, -1) # error: SDL_GetError()

proc main*() =

  block queueAcrossThreads:
    var q: ShellQueue
    q.initShellQueue()
    defer: q.deinitShellQueue()
    var threads: array[producers, Thread[Job]]
    for i in 0 ..< producers:
      createThread(threads[i], produce, (addr q, i))
    var got: seq[ShellEvent]
    while got.len < producers * perProducer:
      got.add q.drain()
    joinThreads(threads)
    doAssert q.drain().len == 0
    doAssert got.len == producers * perProducer
    # Each producer's events arrive in the order it pushed them.
    var next: array[producers, int]
    for ev in got:
      let parts = ev.paths[0].split(':')
      let (id, i) = (parseInt(parts[0]), parseInt(parts[1]))
      doAssert i == next[id], "producer " & $id & ": got " & $i & ", want " & $next[id]
      inc next[id]

  block dialogResultsFromAnotherThread:
    var t: Thread[int]
    createThread(t, fakeDialogs, 0)
    joinThread(t)
    postShellEvent ShellEvent(kind: seThemeChanged, theme: stLight)
    let evs = pollShellEvents()
    doAssert evs.len == 4, $evs.len
    doAssert evs[0].kind == sePathsChosen and evs[0].dialog == dkOpenFiles
    doAssert evs[0].paths == @["/data/a.sgy", "/data/b ü.segd"], $evs[0].paths
    doAssert evs[1].kind == seCancelled and evs[1].dialog == dkOpenFolder
    doAssert evs[2].kind == seDialogFailed and evs[2].dialog == dkOpenFile
    doAssert evs[2].error.len > 0 # SDL's text, or "unknown error" when it has none
    doAssert evs[3].kind == seThemeChanged and evs[3].theme == stLight
    doAssert pollShellEvents().len == 0

  block dialogParentSetting:
    # Left to the desktop: only an X11 window on a Wayland desktop goes without.
    doAssert wantsParent("", "wayland", true)
    doAssert wantsParent("", "x11", false)
    doAssert wantsParent("", "windows", false)
    doAssert not wantsParent("", "x11", true)
    # The setting overrides the desktop either way.
    doAssert not wantsParent(" None ", "wayland", true)
    doAssert wantsParent("window", "x11", true)

when isMainModule:
  main()
