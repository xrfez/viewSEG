## The main-thread inbox: messages from several threads arrive, each
## thread's in the order it posted them; draining replaces the buffer; and a
## poster outlives the inbox it posts to (the last handle frees the buffer).
## The sanitizer run (`nim asan`) checks the freeing.
##
## Seen to fail: with `drainInto` appending to its buffer instead of
## replacing it, `drainReplaces` found the old messages again; with
## `Poster`'s `=dup`, or its `=copy`, not counting the new handle,
## `postersShare` under `nim asan` freed the buffer while a handle still
## used it (AddressSanitizer: heap-use-after-free).

import std/strutils
import viewSEG/core/[inbox, jobs, log]

proc note(text: string): Msg =
  Msg(job: NoJob, kind: mkLog, entry: LogEntry(severity: sevInfo, source: "test", text: text))

const
  Writers = 4
  PerWriter = 200

proc writer(p: (Poster, int)) {.thread.} =
  for i in 0 ..< PerWriter:
    p[0].post note($p[1] & ":" & $i)

proc keep(into: var seq[Poster]; p: sink Poster) =
  into.add p

proc main*() =

  block manyWriters:
    let box = initInbox()
    var threads: array[Writers, Thread[(Poster, int)]]
    for w in 0 ..< Writers:
      createThread(threads[w], writer, (box.poster, w))
    joinThreads(threads)
    var mail: seq[Msg]
    box.drainInto(mail)
    doAssert mail.len == Writers * PerWriter
    var next: array[Writers, int]
    for m in mail:
      let parts = m.entry.text.split(':')
      let w = parseInt(parts[0])
      doAssert parseInt(parts[1]) == next[w], "a writer's messages arrived out of order"
      inc next[w]

  block drainReplaces:
    let box = initInbox()
    let p = box.poster
    p.post note("first")
    var mail: seq[Msg]
    box.drainInto(mail)
    doAssert mail.len == 1
    p.post note("second")
    box.drainInto(mail)
    doAssert mail.len == 1 and mail[0].entry.text == "second"
    box.drainInto(mail)
    doAssert mail.len == 0

  block postersShare:
    var p: Poster
    var kept: seq[Poster]
    block:
      let box = initInbox()
      p = box.poster
      kept.keep(p) # `=dup`: `p` is used again below
      var copy: Poster
      copy = p # `=copy`
      copy.post note("through a copy")
      let moved = move copy
      moved.post note("through a moved copy")
      p.post note("through the original")
      var mail: seq[Msg]
      box.drainInto(mail)
      doAssert mail.len == 3
    # The inbox is gone; its posters still hold the buffer, until the last.
    kept[0].post note("through the kept one")
    kept.setLen 0
    p.post note("through the last one")
    var again = p
    again = p # `=copy` over a handle to the same buffer
    again.post note("still there")

when isMainModule:
  main()
