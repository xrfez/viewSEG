## The tests of the parseSSVIB package (deps/parseSSVIB/tests), run in this suite's one
## program. The package runs them by itself too (`nim parseSSVIBTest`).

import "../deps/parseSSVIB/tests" / [tdecode, timports, tseg, tsweep, tunits, tgolden, tfuzz]

proc main*() =
  tdecode.main()
  timports.main()
  tseg.main()
  tsweep.main()
  tunits.main()
  tgolden.main()
  tfuzz.main()

when isMainModule:
  main()
