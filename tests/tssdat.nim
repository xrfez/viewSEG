## The tests of the parseSSDAT package (deps/parseSSDAT/tests), run in this suite's one
## program. The package runs them by itself too (`nim parseSSDATTest`).

import "../deps/parseSSDAT/tests" / [tdecode, timports, tseg, tfuzz]

proc main*() =
  tdecode.main()
  timports.main()
  tseg.main()
  tfuzz.main()

when isMainModule:
  main()
