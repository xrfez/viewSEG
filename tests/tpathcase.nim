## Which paths name one file (`core/state.samePath`), on the host's own rules:
## on Windows names that differ in case only do, so a write to `C:\DATA\A.SGY`
## is refused while `c:\data\a.sgy` is open; on Linux and macOS (case-sensitive
## drives, as the program takes them) they are two files. `canonical` makes a
## path absolute and normalized: `./a.sgy` and the full name come out equal on
## every host, and on Windows `/` and `\` too.
##
## Seen to fail: with `samePath` as `a == b` on Windows, "a drive's names are
## not case-sensitive" fails (the Windows job runs it).

import std/os
import viewSEG/core/state

proc main*() =

  block names_differing_in_case:
    when defined(windows):
      doAssert samePath(r"C:\Data\A.SGY", r"c:\data\a.sgy"),
        "a drive's names are not case-sensitive"
    else:
      doAssert not samePath("/data/A.SGY", "/data/a.sgy"), "two files on a case-sensitive drive"
    doAssert samePath("/data/a.sgy", "/data/a.sgy")
    doAssert not samePath("/data/a.sgy", "/data/b.sgy")

  block canonical_is_one_spelling:
    let here = getCurrentDir()
    doAssert canonical("a.sgy") == canonical("./a.sgy")
    doAssert canonical("a.sgy") == canonical("sub" / ".." / "a.sgy")
    doAssert canonical("a.sgy") == here / "a.sgy"
    when defined(windows):
      doAssert canonical("sub/a.sgy") == canonical(r"sub\a.sgy")

when isMainModule:
  main()
