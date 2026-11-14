# The plot window and the map: design

> **Draft for the user to confirm.** Built from the user's requirements and feedback so
> far. Where a choice was open, the default below is taken and listed under
> [Open choices](#open-choices) at the end; corrections go into this page before the
> trace panel is built on it.

## Layout

```
┌ Plot ──────────────────────────────────────────────────────┐
│ [▒|∿|◢|◣]  [12.5 tr/in]  [200 ms/in]  [fit][back] [⋯]      │  controls
├────────────────────────────────────────────────────────────┤
│ line    100  100  100  100  100  100  100  100  100        │  display header
│ point   101  103  105  107  109  111  113  115  117        │  (thinned to fit)
├────────────────────────────────────────────────────────────┤
│ 0 ms   ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏     │
│        traces across, time down                            │
│ 4000 ms                                                    │
└────────────────────────────────────────────────────────────┘
```

- **Vertical, as seismic is plotted:** time runs down, traces run across. Single traces
  and overlays are vertical too; overlays also offer a horizontal option.
- **Display header along the top:** rows of trace header values over the traces, thinned
  so labels never overlap. Any trace header field can be a row, and there can be several;
  the default is receiver **line** and **point**. Reversed traces are marked there.
- **The window's own controls**, in a slim strip at its top (nothing about a plot sits in
  the main toolbar):
  - display mode (▒ ∿ ◢ ◣ above): density (greyscale), wiggle, wiggle with positive
    fill, wiggle with negative fill; wiggle can be drawn over density. The mode a user picks becomes the
    default for new plot windows and is remembered;
  - **scale boxes: traces per inch and ms per inch**, each a box to type a value into.
    Typing sets the zoom; zooming any other way updates the boxes. Units are a setting
    (per inch or per cm; inches per second for time). Physical size uses 96 dpi times
    the display scale unless the monitor is calibrated in Settings;
  - fit all, back to the previous view, and a "more" popover: trace overlap (the largest
    swing of a wiggle, in trace spacings), the display header's fields, the colours.
- **The status bar** (the main window's bottom edge) reads out the cursor: time, trace
  and channel, receiver point, source point, FFID, offset, amplitude and the shot time.
  The fields and their order are the user's choice. Unknown values are left blank.

## Colours

- **"Paper", the default:** white background, black wiggles and black fill, whatever the
  UI theme. Density uses its own grey colour map. Alternatives: **"Follow theme"** (the
  plot takes the theme's window and text colours) and **custom** colours.
- **Highlighting recolours the traces themselves:** the hovered trace and the selected
  traces are redrawn in their colours (line and fill), never marked with a band behind
  them. Hover is orange; the selection uses the theme's selection colour, so the two
  never look alike.
- **Components** of multi-component units each have a colour and can be shown or
  hidden one by one.
- **Killed traces** are drawn blank (or hidden: a setting).

## Mouse and keys

**One gesture, one action.** Each row is one input; no input appears twice for the same
window. Keys act on the focused window (the plot, the map or the file list); the
application keys work everywhere. Every action is also in a menu or on a control, with
its shortcut shown there.

### The plot

| Input | Action |
|---|---|
| Move the mouse | **Hover:** the trace under the cursor is drawn in the hover colour, its source and receiver light up on the map, and the status bar reads it out |
| Left click | **Select** that trace (replaces the selection) |
| Shift + left click | Add the trace to the selection, or take it out |
| Left drag | **Pan** |
| Shift + left drag | **Box select:** the traces and time window in the box become the selection; the spectrum and f-k windows follow the box while it is drawn, and show it once released |
| Ctrl + left drag | **Velocity ruler:** a line from press to release; its apparent velocity is shown beside it until Esc |
| Ctrl + left click | Add a point to the mute being edited (only while the mute editor is open; otherwise nothing) |
| Right drag | **Box zoom** to the dragged rectangle |
| Right click | **Context menu** of the trace under the cursor (see below) |
| Middle drag | Pan (always, also while a ruler or mute is being drawn) |
| Wheel | **Zoom** in or out about the cursor, in time and traces together |
| Ctrl + wheel | Zoom in time only, about the cursor |
| Shift + wheel, or the sideways wheel | Zoom in traces only, about the cursor (some systems send Shift + wheel as the sideways wheel) |
| `+` / `-` (main keys or keypad) | Zoom in or out about the cursor (or the centre), both axes |
| Ctrl + Up / Ctrl + Down | Zoom in / out in time only |
| Ctrl + Right / Ctrl + Left | Zoom in / out in traces only |
| Arrow keys | Pan by a tenth of the view; with Shift, by a whole view |
| Ctrl + `0` | Fit all (also a button in the controls) |
| Backspace, or Alt + Left | Back to the previous view |
| Page Down / Page Up | Next / previous gather |
| Home / End | First / last gather |
| Ctrl + G | Go to a record number |
| Space | Raw ↔ processed |
| `K` | Kill or restore the hovered trace (or the selection) |
| `R` | Reverse the polarity of the hovered trace (or the selection) |
| `F` | Amplitude spectrum (FFT) of the hovered trace (or the selection) in a new window |
| `H` | Show the trace's headers |
| `M` | Select the trace's station on the map |
| Ctrl + Z | Undo the last kill, restore or polarity change |
| Esc | Cancel, innermost first: the drag in progress, else the ruler, else the selection |

### The map

The map uses the same gestures wherever the meaning carries over, always at equal aspect.

| Input | Action |
|---|---|
| Move the mouse | **Hover:** the point under the cursor shows its line, point, coordinates and the records or traces it belongs to (in a popup or in a strip along the map's bottom, as the user chooses); a receiver's traces light up in the plot; the status bar shows the cursor's coordinates with their units |
| Left click on a source | Open its gather in the plot |
| Left click on a receiver | Select its traces |
| Shift + left click | Add the point's traces to the selection, or take them out |
| Left drag | **Pan** |
| Shift + left drag | **Box select:** the traces of every point in the box |
| Ctrl + left drag | **Measure** a distance (with units) until Esc |
| Right drag | **Box zoom** |
| Right click | **Context menu** of the point under the cursor (open its gather, select its traces, show its information) or of the map (layers, fit) |
| Middle drag | Pan |
| Wheel | **Zoom** about the cursor |
| `+` / `-` | Zoom in or out about the cursor (or the centre) |
| Arrow keys | Pan by a tenth of the view; with Shift, by a whole view |
| Ctrl + `0` | Fit all |
| Backspace, or Alt + Left | Back to the previous view |
| Esc | Cancel, innermost first: the drag in progress, else the measurement, else the selection |

The map always keeps equal aspect, so it has no zoom along one axis: Ctrl and Shift
with the wheel, the sideways wheel and Ctrl with the arrow keys do nothing there.

### Everywhere

| Input | Action |
|---|---|
| Ctrl + O | Open file |
| Ctrl + Shift + O | Open files |
| Ctrl + Alt + O | Open folder |
| Ctrl + Q | Quit |
| Up / Down, Tab / Shift + Tab (file list focused) | Step to the next / previous file and open it in the same plot, keeping the display settings |

## The trace context menu

Right-click a trace. If it is in the selection, the menu acts on the whole selection;
otherwise on that trace alone, and the selection stays as it was.

| Item | Key | |
|---|---|---|
| Kill / Restore | `K` | drawn blank, left out of processing, spectra and statistics; remembered for the file |
| Reverse polarity | `R` | marked in the display header; remembered for the file |
| FFT in a new window | `F` | amplitude spectrum, raw and processed; several can be open |
| Show headers | `H` | the trace's header in the header table |
| Select its station on the map | `M` | |

Edits to traces are lists kept beside the file, never written into it: each is undone by
its inverse, Ctrl + Z reverts the last one, and "Clear all edits for this file" returns to
the file as it is on disk.

Right-clicking an empty part of the plot opens the plot's own menu: display mode,
colours, display header fields, fit all.

## Empty and first-run state

With no file open, the plot area shows a start screen instead of an empty dock:

- **Open a file…** (Ctrl + O) and **Open a folder…** (Ctrl + Alt + O), as large buttons;
- the recent folders and files, newest first, each one click away;
- a line saying that files can also be dropped on the window.

The first run starts the same way, with the default layout (plot, map, file list,
messages) and every setting at its default.

## Performance targets

The machines are mostly servers with many cores at half a desktop's clock and a weak GPU,
sometimes a laptop with integrated graphics; plan for 16 GB of RAM and files over 30 GB.

| Target | Value |
|---|---|
| Largest file | 30 GB and more; memory-mapped, never loaded |
| RAM | 16 GB; caches within a budget (2 GB by default, a setting) |
| Trace keys | built on demand above a few million traces (about 184 bytes a trace) |
| Index cache on disk | within a budget (4 GiB by default) |
| GPU | OpenGL 3.3; a few textured quads and line buffers; processing on CPU threads |
| Floor | software OpenGL (Mesa llvmpipe), as in CI |
| Frame time while panning or zooming | under 16 ms on a GPU; under 33 ms on software OpenGL |
| Frame watchdog | a frame whose UI-thread work passes 50 ms is logged as a stall |
| Response to a zoom or pan | the view moves at once with what is already drawn; new data replaces it as it arrives |
| Work per view | only the traces and samples on screen (plus a small read-ahead and the filter margin); zoomed out past a trace per pixel, only the traces drawn |
| Open | progress and Cancel at once; a second open of an unchanged file reads its index cache |

## Open choices

Defaults taken in this draft, for the user to confirm or change:

1. **Wheel zooms** and drag pans. On a laptop touchpad, two-finger scrolling then
   zooms; the alternative is wheel = scroll in time, Ctrl + wheel = zoom.
2. **Shift + drag selects a box; Ctrl + drag draws a ruler** (velocity in the plot,
   distance on the map). Alt is left alone: several Linux desktops move windows with
   Alt + drag, and on Windows Alt opens the menu.
3. **Right drag is box zoom**, right click the context menu (they are told apart by
   whether the mouse moved).
4. **Single keys** (`K`, `R`, `F`, `H`, `M`, Space) act on the hovered trace or the
   selection when the plot has focus.
5. **Hover orange, selection in the theme's selection colour.**
6. **Fit all is Ctrl + `0` (and a button); back is Backspace or Alt + Left**, since
   Home and End step to the first and last gather.
7. **A double-click does nothing extra.** Its first click already selects a trace (or,
   on the map, opens a source's gather), so "double-click to fit" would do two things.
8. **Zoom along one axis from the keyboard is Ctrl + arrow keys**, not Shift + `+`: on
   many layouts `+` itself needs Shift.
