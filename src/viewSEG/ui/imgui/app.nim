## The Dear ImGui frontend (imguin + ImPlot on SDL3/OpenGL 3). Only `ui/imgui/`
## may import imguin, ImPlot or SDL (docs/architecture.md). Placeholder until the
## stack is pinned (PLAN.md 0.3).

proc run*(): int =
  ## Runs the frontend's event loop; returns the process exit code.
  echo "viewSEG: the ImGui frontend is not built yet (PLAN.md 0.3)"
  0
