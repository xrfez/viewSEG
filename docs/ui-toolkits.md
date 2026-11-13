# UI toolkit survey (2026-11-13)

> **Decision (user, 2026-11-13):** imguin + ImPlot, with no prototypes. SDL3 with
> OpenGL 3 is the backend. The GUI must stay swappable: see `architecture.md`.

Desk research only: four passes over GitHub repos (dates, trees, READMEs) and the Nim forum.
Nothing was built. `ui-toolkits.html` beside this file is the full report (same content, with
pros and cons per candidate and sources).

## Requirements

R1 file dialogs · R2 lists/trees · R3 large editable tables · R4 charts · R5 interactive plots
with cursor readout · R6 large colour-mapped raster (3000 x 2000 trace panel) · R7 map with
selectable points/lines · R8 movable windows, panels on other monitors · R9 Windows + Linux.

## Matrix (● built in, ◐ partly or known recipe, ○ build it yourself)

| Candidate | R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 | R9 | Health |
|---|---|---|---|---|---|---|---|---|---|---|
| **imguin** (Dear ImGui docking + ImPlot) | ◐ | ● | ● | ● | ● | ◐ | ◐ | ● | ● | one binding maintainer, regenerated per ImGui release |
| **seaqt** (Qt 6 Widgets) | ● | ● | ● | ○ | ○ | ◐ | ◐ | ● | ◐ | preview, may rebase, no release |
| **Merenda** (pure Nim, GPU) | ◐ | ● | ◐ | ○ | ○ | ◐ | ○ | ◐ | ◐ | v0.31, very active, one dev |
| **retroui** (pure Nim) | ◐ | ● | ● | ● | ◐ | ◐ | ● | ◐ | ● | 1 week old, Win 3.1 look |
| Web hybrid (webui/Neel + JS) | ◐ | ● | ● | ● | ● | ◐ | ● | ◐ | ● | arrays copied over a socket |
| owlkettle (GTK 4) | ● | ◐ | ● | ○ | ○ | ◐ | ◐ | ◐ | ◐ | no docks; GTK runtime on Windows |
| Silky + windy (treeform) | ○ | ○ | ○ | ○ | ○ | ● | ○ | ◐ | ● | young, few widgets |

Set aside: naylib (archived Aug 2026; single window), figuro (paused for Merenda), uirelays
(drawing layer, no widgets), nimgl/imgui (legacy), nimqt (GPL, dormant), nimqml (maintenance),
wNim (Windows only), NiGui/uing/wxnim/nimx/FLTK/Slint (thin or dormant), nimview/nimCEF (dead).

## Conclusion

1. **Recommended: imguin** (github.com/dinau/imguin, MIT, Futhark over cimgui, plain `nim c`
   plus a C++ compiler; GLFW/SDL2/SDL3 with OpenGL3/Vulkan). It is the only option with
   tear-out docking to other monitors (multi-viewport), ImPlot (crosshairs, plot mouse
   position, drag lines, images), and clipped tables, all built in.
   - R6: float32 `R32F` texture plus a shader colour map, shown with `PlotImage`. Not
     `PlotHeatmap`, which is too slow at this size.
   - R7: port implot_demos `demos/maps.cpp`.
   - Cons: looks like a tool, no accessibility, basic IME, needs C++.
   - Multi-viewport is weak on native Wayland, so on Hyprland use the X11 backend under
     Xwayland.
   - Nim 2.4 is not stated as tested.
2. **Runner-up: seaqt + Qt 6 Widgets**, if a native look and accessibility matter most.
   - Plots are custom `QPainter` code: QtCharts and QtGraphs are not bound, and are GPL anyway.
   - Map: a QML `MapView` in a window container.
   - Costs: a hard Windows build, manual `owner = false` ownership, and LGPL DLL shipping.
3. **Watch Merenda** (best future target for Nim widget contributions) **and retroui**
   (read its tileMap and grid for ideas).
4. **The seismic parts are custom in every toolkit**: the trace panel, the trace readout
   and the survey map. Keep viewer state, kernels, tile cache and selection in plain Nim
   modules with no UI imports.

## Unverified (the prototypes test these)

- imguin on Nim 2.4.
- Multi-viewport behaviour at runtime.
- Merenda's large-table performance.
- retroui's own feature claims.
- Whether webui's Nim wrapper exposes its binary calls.
