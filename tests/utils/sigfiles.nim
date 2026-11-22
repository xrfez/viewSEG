## Synthetic signature files for the tests: a `.dat` and a `.vib` written into a folder from
## the two libraries' own test generators (`deps/parseSSDAT/tests/datsynth`,
## `deps/parseSSVIB/tests/vibsynth`). Every number is made up.

import std/os
import "../../deps/parseSSDAT/tests/datsynth"
import "../../deps/parseSSVIB/tests/vibsynth"

export datsynth, vibsynth

proc writeBytes*(path: string; b: seq[byte]) =
  var text = newString(b.len)
  for i, x in b: text[i] = char(x)
  writeFile(path, text)

proc datFile*(dir, name: string; s = SynthDat(samples: 12000)): string =
  ## Writes the synthetic `.dat` `s` as `dir/name`; returns the path.
  createDir(dir)
  result = dir / name
  writeBytes(result, synthDat(s))

proc vibFile*(dir, name: string; s = SynthVib()): string =
  ## Writes the synthetic `.vib` `s` as `dir/name`; returns the path.
  createDir(dir)
  result = dir / name
  writeBytes(result, synthVib(s))
