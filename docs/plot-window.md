# The plot window and the map: design

> **Draft for the user to confirm.** Built from the user's requirements and feedback so
> far. Where a choice was open, the default below is taken and listed under
> [Open choices](#open-choices) at the end; corrections go into this page before the
> trace panel is built on it.

## Layout

```
┌ Seismic ───────────────────────────────────────────────────┐
│ [▒|∿|▒∿][◢|◣][⊢] [gain▾] [-][+0.0][+] dB [12.5] tr/in [200]│  controls (they
│ ms/in [-][+][fit][<] [Line/Station|By Flag|By Component]   │  wrap when narrow)
│ [Custom...] [⋯]                                            │
├────────────────────────────────────────────────────────────┤
│ line    100  100  100  100  100  100  100  100  100        │  display header
│ point   101  103  105  107  109  111  113  115  117        │  (thinned to fit)
│ edits             K              R                         │  (while edited)
├────────────────────────────────────────────────────────────┤
│    0   ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏ ▏   ┃ │  time: values only
│ [1234]──────────────┼ traces across, time down           ┃ │  the cursor's time
│ 4000                                                     ┃ │  line; scroll bars
│        ━━━━━━━━━━                                          │
└────────────────────────────────────────────────────────────┘
```

- **Named for what it shows:** the plot window of seismic traces is **Seismic**; the
  same window showing auxiliary traces (the auxiliary viewer) is **Aux**, and the spectrum
  and f-k windows, built on it, are **FFT** and **F-K**. The name comes from the window's
  trace filter and kind, so a window renamed by a new filter keeps its place; a second
  window of a kind is numbered ("Seismic 2"). Saved layouts name a window by an identity
  of its own (Dear ImGui's `###plot`), never by its title, so a layout saved before a
  rename puts every window back where it was.
- **Vertical, as seismic is plotted:** time runs down, traces run across. Single traces
  and overlays are vertical too; overlays also offer a horizontal option.
- **Never past the data:** every way of moving the view (wheel, keys, drags, box zoom,
  typed scales, the scroll bars, back, a new window size) stops at the first and last
  trace and at the record's start and end. Zoomed out as far as it goes, the record
  fills the plot exactly (in the wiggle modes, as many of its traces as the plot has
  pixel columns: see the display mode below). **The one exception: the edge traces'
  whole wave.** In the wiggle modes the trace axis reaches past the first and the last
  trace by the swing the trace overlap allows beyond their own spacing (overlap 1: half
  a trace spacing on each side; an overlap of a half or less: none), so their outer
  lobes are never cut, and a record of one trace shows whole; fit shows it all.
  Nothing but those lobes is drawn there: no density, no header value, no pick. In the
  density mode there is no such margin. Changing the mode or the overlap keeps the
  view where it is and only moves the limits (a view that showed the whole record
  shows the whole of it again, margins included); the scroll bars, the scale boxes,
  the display header, the pick and the cursor line stay on the traces.
- **The time axis shows tick values only**, no title: the unit is in the ms/in box and
  in the status bar. Every label is as wide as the longest the record can have (its
  first or last time, with the decimals of the finest step a view of it can show), so
  the axis keeps one width and the plot's left edge does not move when the labels grow
  from "999" to "1000" as the view pans.
- **The cursor's time line**, a toggle in the strip after the fills (⊢; off by default,
  remembered between runs): when on, a thin line runs along the pointer's pixel row
  from the pointer across the plot to the time axis, and the pointer's time is written
  at the axis on that row, right-aligned as the tick values are, on a small box over
  them, to the sample interval (whole ms at 1 ms or coarser). It is drawn over the plot's image each
  frame, so it follows the pointer without lag and reads and redraws nothing; it is not
  drawn when the pointer is off the plot. Its colour is the theme's crosshair colour,
  made readable on the plot's background, with a halo of that background on each side,
  so it shows on paper and on the theme's plot, over wiggles and over density.
- **Scroll bars** appear when part of the data is out of view: under the plot when not
  every trace is shown, right of it when not all of the record's time is; none when
  everything is in view. The thumb's length is the share in view. Dragging the thumb
  pans; a click on the track pans by a whole view towards the click (held, it repeats
  until the thumb reaches the pointer); the wheel over a bar pans along it. They move
  the view like any other gesture, so "back" returns to the view before. They sit in
  their own gutters right of and below the plot, never over the data, and the gutters
  are always kept, so the plot does not move or change size (and the scales do not
  jump) when a bar comes or goes.
- **A new window size keeps the scale:** along an axis that shows part of the data the
  plot shows more or less of it from the same top-left corner, as a sheet of paper
  would; an axis that shows the whole record goes on showing all of it.
- **Display header along the top:** rows of trace header values over the traces, thinned
  so labels never overlap. Any trace header field can be a row (among them the component
  of a multi-component station), and there can be several; the default is receiver
  **line** and **point**. While the record has an edited trace, a last row, **edits**,
  marks each one over its trace, as the edits are now: **K** (killed, in the theme's
  error colour), **R** (reversed, in its accent colour), **KR** for both, a thin bar where
  traces are too close for the letters; the row goes when the record has no edit left.
  A right click on the header (its rows of values, or their names left of the plot)
  opens its own menu: automatic fields, or the fields ticked; the gear popover has the
  same.
- **The traces' order** is the file's until a sort is chosen, and belongs to the plot
  window: two windows on the same record can show it in two orders. Sorting never
  changes the file, and it happens off the screen's thread, so a large gather never
  holds up the window: the plot goes on showing the old order (with "Sorting by ..." in
  its top-left corner) until the new one is read, and the view stays where it was. The
  display header, the status bar's readout, the scroll bars and every read follow the
  order shown, and a new gather is shown in the same order.
- **The window's own controls**, in a slim strip at its top (nothing about a plot sits in
  the main toolbar). In a narrow window the strip wraps onto more lines; the window
  itself never scrolls, so no window scroll bar ever covers the plot:
  - **display mode** (▒ ∿ ▒∿ above): greyscale density, wiggles, or wiggles over
    density, and two toggles for the wiggles' fills (◢ ◣): the **positive fill** (the
    lobes right of the trace) and the **negative fill** (left of it), either, both or
    none. The default is **wiggles with the positive fill**, black on white paper.
    **Density is drawn only when it is chosen:** in the density mode, and under the
    wiggles in wiggles over density; the wiggle modes draw wiggles at every zoom. In
    them, **zooming out stops at one pixel a trace**, so every trace in view is drawn
    and none is skipped: a record of more traces than the plot has pixel columns opens
    at that limit from its first trace, with the scroll bar along the traces, and fit
    goes as far as the limit. Every gesture, the typed traces per inch, back and a new
    window size keep to it; the time axis has no such limit (each pixel row keeps its
    samples' peaks). Seeing a whole large record at once is what the density mode is
    for: it zooms out until the record fills the plot. Changing from density to a
    wiggle mode in a wider view narrows the view to the limit, keeping its left edge.
    The mode a user picks becomes the
    default for new plot windows and is remembered between runs, as are the fills, the
    overlap, the colours, the gain type, amount and settings, the order and the display
    header's fields (`Settings.plot`: a new plot starts as the user left the last one;
    polarity is not kept, reversing it being an operation on the data);
  - **scale boxes: traces per inch and ms per inch**, each a box to type a value into.
    Typing a value and pressing Enter sets the zoom, keeping the top-left corner where it
    is (a plot grows from where it starts, as on paper); zooming any other way updates the
    boxes. A value past what the record allows (wider than the record, narrower than four
    traces or eight samples, or in a wiggle mode more traces than the plot has pixel
    columns) stops there, keeping the top-left corner, and the box shows the scale
    reached; a value that
    is not a positive number is refused with a message in the log. Units are a setting
    (per inch or per cm; time also as inches or cm per second). Physical size uses 96 dpi
    times the display scale unless the monitor is calibrated: in the window's "more"
    popover, from the monitor's diagonal, or by making a bar on the screen as long as a
    ruler held to it says. A calibration is kept per monitor (its name and size in
    pixels);
  - the **display gain**: a gain type, with its own settings in the same drop-down,
    and a **gain amount in dB** that every type has: a box, - and + buttons (3 dB a
    step) and keys (`]` or keypad `*` for more, `[` or keypad `/` for less), from -60 to
    +60 dB. The amount rescales the drawing at once and never reads or processes again.
    A *reference* amplitude is drawn full black (or white) at 0 dB; the types differ
    in what they do to the samples and in where the reference comes from:

    | Type | On the samples | Reference (full black at 0 dB) | Settings |
    |---|---|---|---|
    | Automatic (default) | AGC on shot and receiver records, nothing on stacked data | as AGC or None | the AGC window |
    | None | nothing | the record's clip percentile of \|x\| (99 by default), held while panning | |
    | Fixed | nothing | one amplitude, the same for every record and file until changed, so records compare; taken from the record shown when Fixed is chosen | the amplitude; "From this record" |
    | Normalized | each trace to the same level (per trace), or nothing (whole record) | that level: RMS, peak or clip percentile, of each trace or of the record | per trace or the whole record; the level |
    | Exponential | `10^(dB/s · t / 20)`, or `(t / 1 s)^n` | the record's clip percentile after the gain | dB per second (6 by default), or the power of time |
    | Float | nothing | the clip percentile of the data in view, again whenever the view changes | |
    | AGC | AGC | the record's clip percentile after AGC | the window (500 ms) |

    Changing the amount, a Fixed amplitude, or between types that do nothing to the
    samples (None, Fixed, Float, Normalized for the whole record) reads nothing again;
    the others read the view again with the new processing. Under those (AGC,
    Exponential, Normalized per trace), a trace marked dead in the file is drawn blank,
    and a sample that is not a number counts as 0, so such a trace never shows up
    saturated at its raw amplitude among gained ones;
  - **three sort buttons and Custom...**, the button of the order in use drawn selected:

    | Button | Order |
    |---|---|
    | Line/Station | receiver line, then station (point), as the headers give them; a station's traces stay in the file's order |
    | By Flag | receiver line, then station, then component: a station's components side by side, in order |
    | By Component | the traces grouped by component, each group by line, then station |

    Clicking the selected button again goes back to the file's order (each button's tip
    says so). A button whose keys the traces have none of (post-stack data has no receiver
    line, point or component) is greyed out, as it would change nothing. Other orders are
    keys of the user's own, from the fourth button, **Custom...**, drawn selected while
    such an order is in use: a small popover lists the keys, the first first, each a
    display header field (line, point, component, channel, FFID, source line and point,
    offset, CDP, inline, crossline, trace number) and each ascending or descending; "Sort"
    applies them, "File order" goes back. Traces equal in every key keep the file's order,
    and unknown values come last either way. The keys sorted by last are remembered and
    offered again; the buttons themselves are data in the settings (`sortPresets` in
    `settings.nif`), so a site can rename them or add its own;
  - the **record** shown: the previous and next record, and its place ("2 / 120"), which
    opens **Go to record** (a place in the file or an FFID). The next record is shown at
    the same scales as the one before (the same positions and times; the whole record
    along an axis that showed the whole record), with the same display, gain and order;
  - zoom out, zoom in, fit all, back to the view before the last gesture, and a "more"
    popover: the colours, the **trace overlap** (the largest swing of a wiggle, in trace
    spacings), the display header's fields, the scale units and the screen
    calibration.
- **The status bar** (the main window's bottom edge) reads out what lies under the
  pointer in the plot: the time at the cursor, trace (its number in the file) and
  channel, receiver line / point, source line / point, FFID, offset, amplitude and the
  shot time (the record's UTC time). The amplitude is the value drawn there: after the
  display's processing and gain, and zoomed out the largest of the samples drawn at that
  pixel ("peak of 4"). Right-click the bar to choose the fields and their order; any of
  the trace's keys can be added (sample number, UTC at the cursor, CDP, inline,
  crossline, source, receiver and midpoint coordinates, elevations, component, trace
  status). Unknown values are left blank. Whatever the fields, the bar says "killed",
  "polarity reversed" or both, in the theme's warning colour, over an edited trace.

## Wiggles

- **At every zoom** the wiggle modes draw wiggles, never density in their place: the
  view stops at one pixel a trace (above), where each trace has a pixel column of its
  own.
- **The line** runs through each trace's samples, straight between them. Zoomed out in
  time, where a pixel row holds more samples than one, it runs through each column's
  smallest and largest sample, in the order they occur, so no peak or trough is lost.
- **The swing.** The amplitude the gain draws full black in density swings a trace the
  **trace overlap** (1 by default: to the next trace's baseline), in trace spacings;
  stronger amplitudes are clipped there, flat. The gain amount and every gain type act
  on wiggles as on density, and the gain amount reads nothing again.
- **The fills** cover the area between the trace's baseline and its line, on the side
  chosen, edge to edge with the line.
- **Order:** each trace is drawn over the one before it; the hovered and selected traces
  once more, on top, so a neighbour's fill never hides a highlight. The line is one pixel
  wide (at 100 %), two for a hovered or selected trace.

## Colours

- **"Paper", the default:** white background, black wiggles and black positive fill, the
  theme's red (darkened to read on white) for the negative fill, whatever the UI theme.
  Density uses its own grey colour map. Alternatives: **"Follow the theme"** (the plot
  takes the theme's plot background, trace and fill colours) and **custom** colours:
  background, line, positive and negative fill, hovered and selected trace, each picked
  in the "more" popover, starting from the colours shown.
- **Highlighting recolours the traces themselves:** the hovered trace and the selected
  traces are redrawn in their colours (line and fill), never marked with a band behind
  them; under density alone, their columns are tinted. Hover is the theme's highlight
  colour (orange); the selection is the theme's accent colour (the colour of a selected
  button), so the two never look alike. The theme's own "selection" colour is a
  background tint, which would not show as a line on paper. Each is darkened or
  lightened just enough to read on the plot's background. A trace both hovered and
  selected shows the hover. Hover and selection are survey-wide trace ids, shared with
  the map.
- **Components** of multi-component units each have a colour and can be shown or
  hidden one by one.
- **Killed traces** are drawn blank: the plot's background shows where the trace was, in
  every mode (no line and no fill among wiggles, no grey under density), with only the
  hover's tint under density alone. Hiding them instead (the traces closing up) is a
  setting to come.

## Polarity

Reversing the polarity turns the trace data 180 degrees out of phase: an operation on the
samples, not a way of colouring them. **Reverse polarity of all traces**, in the plot's
right-click menu (ticked while it is on), runs processSEG's `polarityOp` first on every
trace the window reads, before its gain, so the picture, the gain's statistics, the status
bar's amplitude and whatever is later computed from the window (a spectrum, an overlay
comparison, an export) see the reversed data. Turning it on or off reads the view again;
the picture before stays until the reversed one is drawn. It holds for the next record and
file shown in the window, and is never kept as a setting: a new plot shows the data as
recorded.

**Reverse polarity** of a single trace, or of the selection that holds it (`R`, or the
plot's menu), is an edit of the file's traces (see [Edits](#edits-to-traces)): those
traces' samples are negated (processSEG's `reversePolarity` on their live samples, as
`polarityOp` does) where the window's reader prepares them, before the pipeline and the
gain. A trace reversed both ways is as recorded. A trace the file marks dead is reversed
too: under the gain None it is drawn as recorded, so reversed it is drawn reversed (under
the gains that run on the samples it is blank either way).

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
| Right click | **The plot's menu:** the trace operations, on the trace under the cursor or the selection (see below) |
| Right click on the display header (its values, or their names at the left) | **The display header's menu:** automatic fields, or the fields ticked |
| Left click or drag on the display header | Nothing |
| Middle drag | Pan (always, also while a ruler or mute is being drawn) |
| Drag a scroll bar's thumb | Pan along that bar |
| Click a scroll bar's track | Pan by a whole view towards the click; held, it repeats |
| Wheel over a scroll bar | Pan along that bar, a tenth of the view per notch |
| Wheel | **Zoom** in or out about the cursor, in time and traces together |
| Ctrl + wheel | Zoom in time only, about the cursor |
| Shift + wheel, or the sideways wheel | Zoom in traces only, about the cursor (some systems send Shift + wheel as the sideways wheel) |
| `+` / `-` (main keys or keypad) | Zoom in or out about the cursor (or the centre), both axes |
| Ctrl + Up / Ctrl + Down | Zoom in / out in time only |
| Ctrl + Right / Ctrl + Left | Zoom in / out in traces only |
| Arrow keys | Pan by a tenth of the view; with Shift, by a whole view |
| Ctrl + `0` | Fit all (also a button in the controls) |
| `]` or keypad `*` / `[` or keypad `/` | More / less gain amount, 3 dB a step |
| Backspace, or Alt + Left | Back to the previous view |
| Page Down / Page Up | Next / previous gather |
| Home / End | First / last gather |
| Ctrl + G | Go to a record number |
| Space | Raw ↔ processed |
| `K` | Kill or restore the hovered trace (or the selection, when it holds that trace) |
| `R` | Reverse the polarity of the hovered trace, or put it back (or the selection, when it holds that trace) |
| `F` | Amplitude spectrum (FFT) of the hovered trace (or the selection) in a new window |
| `H` | Show the trace's headers |
| `M` | Select the trace's station on the map |
| Ctrl + Z | Undo the last kill, restore or polarity change of the file shown (or its clearing) |
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
| Ctrl + W | Close the file the plot shows |
| Ctrl + Q | Quit |
| Drop files or a folder on the window | A folder: list it and show its first file; one file: show it and list its folder; several files: list them and show the first |
| Up / Down, Tab / Shift + Tab (file list focused) | Step to the next / previous file and show it in the same plot, keeping the display settings and the scales |
| Page Down / Page Up, Home / End (file list focused) | Ten files on / back; the first / last file |
| Click a file in the file list | Show it in the plot, in place of the one shown |
| Up / Down, Page Up / Page Down, Home / End (record list focused) | The next / previous record, a page on / back, the first / last record, shown in the plot |
| Click a record in the record list | Show it in the plot |

## The plot's menu: functions on the data

Right-click the plot. The menu holds only what acts on the data; how the plot looks is in
the strip (display modes, gain, sort, zoom, fit, back) and in the gear popover (colours,
trace overlap, display header, scales), and the display header has its own menu (a right
click on it).

Its first line says what the trace operations act on: the trace under the pointer
("Trace 37"), or, when that trace is in the selection, the whole selection ("12 selected
traces"); the selection stays as it was. Over no trace it says "No trace here".

| Item | Key | |
|---|---|---|
| Reverse polarity | `R` | that trace or the selection, 180 degrees out of phase; ticked while the trace under the pointer is reversed, and then it puts the polarity back |
| Kill / Restore | `K` | drawn blank, left out of the processing and of the levels the gain computes over the record; "Restore" over a killed trace |
| FFT in a new window | `F` | amplitude spectrum, raw and processed; several can be open (greyed out, "not available yet") |
| Reverse polarity of all traces | | every trace of the window, ticked while on ([Polarity](#polarity)) |
| Undo last edit (*what it was*) | Ctrl + Z | reverts the file's last kill, restore, polarity change or clearing |
| Clear all edits for this file | | the traces as the file has them; Undo brings the edits back |

On a selection, a trace operation does to every selected trace what it does to the one
under the pointer: Kill kills them all (Restore, over a killed trace, restores them all),
Reverse polarity reverses them all, or puts them all back when that trace is reversed.
Later: show headers (`H`), select its station on the map (`M`), and, perhaps, a filter on
one trace (as a layer of its own, with the overlays).

### Edits to traces

Killing a trace and reversing its polarity are edits: lists kept per file, by the trace's
index in the file, beside the file and never in it (the file is opened read-only). They
hold while viewSEG runs, through another record, a sort, a gain change, and stepping to
another file and back; keeping them across a restart, with the rest of what is
remembered about a file, is still to come. Each change is its own inverse (kill and
restore, reverse and reverse again), so Ctrl + Z reverts the last change and no deeper
history is kept; "Clear all edits for this file" takes them all away, and is undone the
same way. Messages lists every change.

An edit must show at once. The window's reader keeps the samples it last read from the
file (as decoded, up to 128 MiB), so an edit of traces in view, a gain change, or a
slightly shorter view, makes the picture again from them, off the screen's thread, with
nothing read from the file; the picture before stays until the new one is drawn (on the
Morgantown record, zoomed in on 40 traces, about 30 ms from the key under software
OpenGL). Otherwise only the view's tiles are made again. A kill, or a restore, also has
the record's level taken again, so that the gain leaves the killed trace out.

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
| Work per view | only the traces and samples on screen (plus a small read-ahead and the filter margin); in density zoomed out past a trace per pixel, only the traces drawn; in the wiggle modes at most a trace per pixel column, every one of them read |
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
5. **Hover orange (the theme's highlight), selection in the theme's accent colour**
   (not its "selection" colour, a background tint that does not show as a line on
   paper), each made readable on the plot's background; a trace both hovered and
   selected shows the hover.
6. **Fit all is Ctrl + `0` (and a button); back is Backspace or Alt + Left**, since
   Home and End step to the first and last gather.
7. **A double-click does nothing extra.** Its first click already selects a trace (or,
   on the map, opens a source's gather), so "double-click to fit" would do two things.
8. **Zoom along one axis from the keyboard is Ctrl + arrow keys**, not Shift + `+`: on
   many layouts `+` itself needs Shift.
9. **The display gain starts automatic:** a pre-stack gather (a shot or receiver
   record) opens with AGC over 500 ms, so every trace and every time is visible; stacked
   data opens with none, so amplitudes compare. The plot window says which is in use.
   **Float** is read as "the scale follows the data in view"; **Exponential** is the
   dB-per-second gain (6 dB/s offered), with a power of time beside it. Normalized
   draws the chosen level full black and defaults to each trace's clip percentile.
   The gain amount steps by 3 dB and its keys are `]` / `[` (keypad `*` / `/`).
10. **A typed scale keeps the top-left corner** of the view, not its centre, so the
    record's start stays in place as on a paper plot.
11. **One wheel notch zooms by 1.25, a key press or button by 1.5**; wheel turns or key
    presses less than 0.6 s apart count as one gesture for "back". The sideways wheel
    zooms in traces when tilted left (or Shift + wheel up), out when tilted right.
12. **The status bar's shot time is the record's UTC time**; the cursor's time within
    the record is its first field. "UTC at the cursor" (the shot time plus the cursor's
    time) can be added.
13. **The amplitude read out is the displayed value** (after processing and gain), not
    the raw sample in the file.
14. **A new window size keeps the scale** (traces and ms per pixel) and the top-left
    corner, so the scale boxes keep what was typed; an axis that showed the whole record
    goes on showing all of it. The alternative stretches the same data over the new
    size.
15. **A click on a scroll bar's track pans by a whole view** towards the click (as on
    Windows), rather than jumping the thumb to the pointer.
16. **Line/Station and By Flag differ only within a station:** Line/Station keeps a
    station's traces in the file's order, By Flag puts its components in order. Clicking
    the selected sort button goes back to the file's order (there is no button for it;
    the Custom... popover also has "File order").
17. **A sort keeps the view** (the same positions and times, so the scale boxes keep
    their values) rather than fitting the whole gather; "back" is not changed by a sort.
18. **Sort keys are the display header's fields** (the trace keys parseSEG reads for
    every format alike), not raw header words; sorting by any raw header field comes with
    the gather domains. No key has a shortcut yet (open choice 4's single keys come
    first).
19. **Decided by the user:** the plot opens in wiggles with the positive fill, black on
    white paper, and **density is drawn only in the modes that name it** ("it should
    only be on if the user is asking for it"); there is no hand-over to density where
    traces are close. In the wiggle modes zooming out stops at one pixel a trace (the
    user: "maybe dont allow a zoom out that far?"), so a whole shot of thousands of
    traces opens at that limit from its first trace; the density mode shows it whole.
20. **The trace overlap is 1** (the strongest amplitudes reach the next trace's
    baseline), from 0.1 to 10, and the wiggles' clip is the same reference as density's
    full black, so the gain amount moves both alike.
21. **Shift + click adds a trace to the selection or takes it out**; a plain click
    replaces the selection; a click is a press and release without moving (a drag still
    pans).
22. **The negative fill is the theme's red** on paper and on the theme's plot.
