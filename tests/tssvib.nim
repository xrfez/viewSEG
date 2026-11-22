## The tests of the parseSSVIB package (deps/parseSSVIB/tests), run in this suite's one
## program. The package runs them by itself too (`nim parseSSVIBTest`). Four of its test files
## share a name with parseSSDAT's, so they come in through `tests/utils/ssvib*`, which include
## them under names of their own.

import "../deps/parseSSVIB/tests" / [tsweep, tunits, tgolden]
import utils/[ssvibdecode, ssvibfuzz, ssvibimports, ssvibseg]

proc main*() =
  ssvibdecode.main()
  ssvibimports.main()
  ssvibseg.main()
  tsweep.main()
  tunits.main()
  tgolden.main()
  ssvibfuzz.main()

when isMainModule:
  main()
