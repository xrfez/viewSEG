## The dependency wiring works: both libraries resolve through nim.cfg, and
## their entry points used by a viewer are visible.

import parseSEG, processSEG

block libraries:
  doAssert parseSEG.PackageVersion.len > 0
  doAssert declared(openSeismic)
  doAssert declared(newPrefetcher)
  doAssert declared(FftPlan)
  doAssert declared(SpectrumPlan)
  doAssert sizeof(FftPlan) > 0
