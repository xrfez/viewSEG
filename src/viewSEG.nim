## viewSEG: a high-performance SEG-Y / SEG-D viewer built on parseSEG and processSEG.
##
## The entry point only picks the frontend; see docs/architecture.md for the layers.
## `-d:frontend=imgui` (the default) is the Dear ImGui frontend in `viewSEG/ui/imgui`.

import parseSEG
import viewSEG/platform/winres # Windows: manifest, icon, version info, GUI subsystem

const
  ViewSEGVersion* = "0.1.0"
  frontend {.strdefine.} = "imgui"

when frontend == "imgui":
  import viewSEG/ui/imgui/app
else:
  {.error: "unknown -d:frontend=" & frontend & " (known: imgui)".}

when isMainModule:
  echo "viewSEG ", ViewSEGVersion, " (parseSEG ", parseSEG.PackageVersion, ")"
  quit run()
