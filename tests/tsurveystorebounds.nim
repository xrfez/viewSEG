## A `survey.bin` whose trailing hash is right (XXH64 is no seal) but whose
## points block claims 2^32-16 records in 0 bytes (`core/surveystore`):
## the read is refused with an IOError and nothing is allocated for the
## claimed count.
##
## Seen to fail: with the count checked against the bytes left in the block
## left out, the read ran out of memory (the sequence was sized for the
## claimed count before any record was read).
import std/os
import viewSEG/core/[identity, jobs, surveystore]
import utils/[fixtures, waiting]

proc raw[T](s: var string; x: T) =
  let at = s.len
  s.setLen at + sizeof(T)
  copyMem(addr s[at], addr x, sizeof(T))

proc main*() =

  withFixtures fx:
    var s = StoreMagic
    s.raw uint32(1)
    s.raw uint8(3) # bkPoints
    s.raw uint32(0xFFFF_FFF0'u32)
    s.raw int64(0)
    s.raw uint8(255)
    s.raw uint32(0)
    s.raw int64(0)
    let h = xxh64(s)
    s.raw h
    let path = fx.dir / "survey.bin"
    writeFile(path, s)
    let jobs = initJobs()
    var failure = ""
    let f = addr failure
    let id = jobs.submit(JobSpec(title: "t", lane: jlBackground), proc (
        ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}:
        try: readStore(path, ctx, StoreReader())
        except IOError as e: f[] = e.msg)
    doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
    doAssert failure == "survey.bin is damaged", "a count larger than the block is refused: " &
      failure
  echo "tsurveystorebounds: done"

when isMainModule:
  main()
