# The plot window and the map: design

> **Confirmed by the user** (2026-11-14). Built from the user's requirements and feedback;
> every choice that was open in the draft is now the user's decision, as
> [Decisions](#decisions) at the end lists, with what the user changed.

## Layout

```
┌ Seismic ───────────────────────────────────────────────────┐
│ [▒|∿|▒∿][◢|◣][⊢] [-][1.00][+] overlap [gain▾] [-][+0.0][+] dB│  controls (they
│ [12.5] tr/in [200] ms/in [-][+][fit][<] [◂ 1 / 1 ▸]        │  wrap when narrow)
│ [Line/Station|By Flag|By Component] [Custom...] [⋯]        │
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
  so it shows on paper and on the theme's plot, over wiggles and over density. **With
  it, the display header's values of the trace under the pointer** stand in a box over
  each of the header's rows, at that trace's column, in the style of the time box: a
  trace's line and point can be read where the rows are thinned because the traces are
  close (the user: "a box displaying the header like the one that gives the time would
  be nice for when not all headers are shown"). No vertical line: the trace's highlight
  marks the trace.
- **Scroll bars** appear when part of the data is out of view: under the plot when not
  every trace is shown, right of it when not all of the record's time is; none when
  everything is in view. The thumb's length is the share in view. Dragging the thumb
  pans; a click on the track pans by a whole view towards the click (held, it repeats
  until the thumb reaches the pointer); the wheel over a bar pans along it. They move
  the view like any other gesture, so "back" returns to the view before. They sit in
  their own gutters right of and below the plot, never over the data, and the gutters
  are always kept, so the plot does not move or change size (and the scales do not
  jump) when a bar comes or goes.
- **A new window size always keeps the scale** (traces and ms per inch) **and the
  top-left corner**, whatever changed the size (the window's own edge, a neighbour such
  as the Files window, the main window, a layout): a smaller plot shows less of the
  record, from the same corner, with scroll bars for the rest; a larger one shows more,
  as a sheet of paper would. Only when the plot becomes larger than the whole record
  at that scale does the scale grow, as far as fills the plot (never a view past the
  data).
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
    Beside them, the **trace overlap** (the largest swing of a wiggle, in trace spacings:
    see [Wiggles](#wiggles)), as the gain amount is shown: a box to type into, and - and
    + stepping through 0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8 and 10;
    greyed in the density mode, so the strip keeps its shape when the mode changes.
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
  - **Seismic and Aux** (the user, asked whether auxiliary traces should wait for an
    Aux window: "filter toggle"), two toggles shown when the record holds auxiliary
    traces (a time break, a pilot, an uphole): Seismic is on at first; with Aux on too,
    the auxiliary traces are drawn in the same plot, in the file's order among the
    seismic ones (`TraceFilter`, `ckFilter`), at the same scales, and the window is
    titled "Seismic + Aux"; with Seismic off, "Aux" shows them alone. At least one stays
    on. Shorter traces are drawn as long as they are; an auxiliary trace whose sample
    interval differs from the seismic traces' is drawn at theirs, and the log says so
    (their times are then not to scale). Sorts, gain, edits, the display header and the
    readout work on them as on the others. The Aux window of its own, with its own
    filters, is still to come;
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
    step, 12 dB with Shift; held, they repeat) and keys (`]` or keypad `*` for more, `[`
    or keypad `/` for less; the same steps, repeating while held), from -300 to +300 dB
    (a factor of 10^15 either way: raw records span far more than 60 dB between the
    first breaks and the late times). The amount rescales the drawing at once and never
    reads or processes again; where the scale passes what the GPU's numbers hold, every
    sample that is not 0 is drawn full black or white.
    A *reference* amplitude is drawn full black (or white) at 0 dB; the types differ
    in what they do to the samples and in where the reference comes from:

    | Type | On the samples | Reference (full black at 0 dB) | Settings |
    |---|---|---|---|
    | Automatic (default) | AGC on shot and receiver records, nothing on stacked data | as AGC or None | the AGC window |
    | None | nothing | the record's clip percentile of \|x\| (99 by default), held while panning | |
    | Fixed | nothing | one amplitude, the same for every record and file until changed, so records compare; taken from the record shown when Fixed is chosen | the amplitude; "From this record" |
    | Normalized | each trace to the same level (per trace), or nothing (whole record) | that level: RMS, peak or clip percentile, of each trace or of the record | per trace or the whole record; the level |
    | Exponential | `10^(dB/s · t / 20)`, or `(t / 1 s)^n`, rising until a cutoff time and held at its value after it | the record's clip percentile after the gain | dB per second (6 by default), or the power of time (2); the cutoff, "until" (2 000 ms by default) |
    | Float | nothing | the clip percentile of the data in view, again whenever the view changes | |
    | AGC | AGC | the record's clip percentile after AGC | the window (500 ms) |

    **Every setting of the drop-down is remembered** (the user: "everything setup in the
    gain settings dropdown should remember its last settings and have sane defaults for
    new installations"), for every type, not only the one in use: the AGC window,
    Fixed's amplitude (typed, or taken from a record), Normalized's scope and level,
    Exponential's shape, dB per second, power of time and cutoff, and the gain amount.
    They are kept in the settings (`settings.nif`, with the rest of a new plot's
    display) and come back in the next run; a settings file of an earlier build gives
    what it does not hold its default. A new installation starts with settings meant
    for land shot records:

    | Setting | Default |
    |---|---|
    | Gain type | Automatic: AGC on shot and receiver records, none on stacked data |
    | AGC window | 500 ms |
    | Fixed amplitude | none until Fixed is chosen: then the record's clip percentile |
    | Normalized | each trace, to its clip percentile |
    | Exponential | 6 dB per second (the power of time: 2), until 2 000 ms |
    | Clip percentile | 99 (of \|x\|) |
    | Gain amount | 0 dB, in steps of 3 dB (12 dB with Shift), -300 to +300 dB |

    **Exponential's cutoff** (the user: "with exponential the basemet gets pretty blown
    out. maybe there should be a cutoff time"): the gain rises with time until the time
    in its "until" box and holds the value it reached there for the rest of the record,
    for dB per second and the power of time alike. It is processSEG's gain curve
    (`gainCurveOp` with knots: two for dB per second, which is a straight line in dB;
    one every 2 % of time for the power of time, within 0.001 dB of it).

    Changing the amount, a Fixed amplitude, or between types that do nothing to the
    samples (None, Fixed, Float, Normalized for the whole record) reads nothing again;
    the others read the view again with the new processing. **A trace the file marks
    dead is never drawn**, under any gain type and in every display mode: it is blank,
    as a killed trace is, and left out of the levels every type takes its reference
    from (the user: "it looks like the are not drawn under none. and they shouldnt
    be"); the status bar says "dead" over it. A sample that is not a number counts as
    0, so its trace never shows up saturated at its raw amplitude among gained ones,
    and the log says once, for the first record of a file that has such samples, how
    many of the traces shown hold them;
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
    popover: the colours, the trace overlap again, the display header's fields, the
    scale units and the screen calibration.
  - The strip's groups wrap as the window narrows: two lines in the default layout on a
    1920-pixel screen, three on a 1366-pixel laptop screen.
- **The status bar** (the main window's bottom edge) reads out what lies under the
  pointer in the plot: the time at the cursor, trace (its number in the file) and
  channel, receiver line / point, source line / point, FFID, offset, amplitude and the
  shot time (the record's UTC time). The amplitude is the value drawn there: after the
  display's processing and gain, and zoomed out the largest of the samples drawn at that
  pixel ("peak of 4"). Right-click the bar to choose the fields and their order; any of
  the trace's keys can be added (sample number, UTC at the cursor, CDP, inline,
  crossline, source, receiver and midpoint coordinates, elevations, component, trace
  status), and the **raw amplitude** (the user: "ok but off by default"): the sample as
  it is in the file at the cursor, before polarity, edits, processing and gain (zoomed
  out, the largest of the samples there, as the amplitude). It is off until chosen;
  while it is on, each tile carries the file's samples beside the drawn ones, cut the
  same way, so the readout takes them from what is on hand and nothing is read for it
  on the screen's thread. Unknown values are left blank. Whatever the fields, the bar says "dead" over a
  trace the file marks dead, and "killed", "polarity reversed" or both over an edited
  trace, in the theme's warning colour.

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
  wide (at 100 %), two for a hovered or selected trace, and never wider than a quarter of
  the trace spacing: where traces are a few pixels apart a full line would cover the
  fills, and at one pixel a trace every column would be line, a black plot; a thinner
  line shows as a light grey, so a whole shot reads as a variable-area section.

## Colours

- **Every colour of the plot is the user's**, and all six are in plain sight: the gear
  popover's **Colours** section always shows a swatch for each, with its name:
  **background, wiggle line, positive fill, negative fill, the trace under the pointer,
  selected traces**. A click on a swatch opens a colour picker with a box for
  `#rrggbb`; changing a colour there makes the scheme **"My own"**, starting from the
  colours shown, with that one changed. Above the swatches, the schemes: **"Paper"**
  (the default) and **"Follow the theme"**, the two ready-made ones, which also put the
  ready-made colours back, and "My own", which brings the user's own back unchanged.
  The six and the scheme are remembered between runs. Density keeps its own grey colour
  map (a choice of colour maps is to come).
- **"Paper":** white background, black wiggles and black positive fill, the theme's red
  (darkened to read on white) for the negative fill, whatever the UI theme. **"Follow
  the theme":** the theme's plot background, trace and fill colours.
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
- **Killed traces, and traces the file marks dead,** are drawn blank: the plot's
  background shows where the trace was, in every mode (no line and no fill among wiggles,
  no grey under density), with only the hover's tint under density alone. Hiding them instead (the traces closing up) is a
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
gain. A trace reversed both ways is as recorded. A trace the file marks dead stays blank,
reversed or not (it is never drawn); the display header and the status bar still say it is
reversed.

## Mouse and keys

**One gesture, one action.** Each row is one input; no input appears twice for the same
window. Keys act on the focused window (the plot, the map or the file list); the
application keys work everywhere. **The click that brings a window forward does only
that** (the user: "should be only when window i already active"): a click selects a
trace, shows a file or shows a record only in a window that had the focus already; the
first click in another window gives it the focus and nothing else. Every action is also in a menu or on a control, with
its shortcut shown there.

### The plot

| Input | Action |
|---|---|
| Move the mouse | **Hover:** the trace under the cursor is drawn in the hover colour, its source and receiver light up on the map, and the status bar reads it out |
| Left click | **Select** that trace (replaces the selection) |
| Ctrl + left click | Add the trace to the selection, or take it out; the rest stays |
| Shift + left click | Select every trace from the one clicked last to this one, in the order shown (replaces the selection) |
| Left drag | **Pan** |
| Shift + left drag | **Box select:** the traces and time window in the box become the selection; the spectrum and f-k windows follow the box while it is drawn, and show it once released |
| Ctrl + left drag | **Velocity ruler:** a line from press to release; its apparent velocity is shown beside it until Esc |
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
| `]` or keypad `*` / `[` or keypad `/` | More / less gain amount, 3 dB a step; with Shift, 12 dB |
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

The map uses the same gestures wherever the meaning carries over, always at equal aspect
([The map window](#the-map-window) says how it looks).

| Input | Action |
|---|---|
| Move the mouse | **Hover:** the point under the cursor (within 7 pixels) is drawn in the hover colour and described: source or receiver, line and point, coordinates and elevation with their units, its file, the traces of the open files recorded there and their records, and for a survey file's source the field records the loaded relation file gives it; in a box beside the pointer or in a strip along the map's bottom, as the map's settings say. Points of other layers on the same spot (an SPS receiver and the open file's own) are described together. The status bar shows the cursor's coordinates with their units |
| Left click on a point | **Select** it and its traces (replaces the selection); opening a source's record from a click, and a receiver's traces lighting up in the plot as the pointer passes over it, are still to come |
| Ctrl + left click | Add the point (and its traces) to the selection, or take it out |
| Left drag | **Pan** |
| Shift + left drag | **Box select:** every point of a shown layer in the box, and their traces (replaces the selection; with Ctrl too, adds to it) |
| Ctrl + left drag | **Measure:** a line from press to release, its length (in the survey's units) and grid bearing beside it, until Esc |
| Right drag | **Box zoom:** as close as shows the whole box, at equal aspect |
| Right click | **The menu of the point under the cursor:** select it and its traces, add it to the selection or take it out, hide its layer; over no point, "No point here". Layers and fit are in the strip |
| Middle drag | Pan |
| Wheel | **Zoom** about the cursor |
| `+` / `-` (main keys or keypad) | Zoom in or out about the cursor (or the centre) |
| Arrow keys | Pan by a tenth of the view; with Shift, by a whole view |
| Ctrl + `0` | Fit all (also a button in the strip) |
| Backspace, or Alt + Left | Back to the previous view (also a button) |
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
| Up / Down (file list focused) | Step to the next / previous file and show it in the same plot, keeping the display settings and the scales (wherever the focus is in the window, but in the filter box) |
| Tab / Shift + Tab | Move between the controls of the window that has the focus, as in every window (the user: "tab should move between options in the window not files"): in the file list the folder's drop-down, its buttons, the filter, "Latest" and the list (one stop, at the file shown); Space or Enter acts on the control reached |
| Page Down / Page Up, Home / End (file list focused) | Ten files on / back; the first / last file |
| Click a file in the file list (focused) | Show it in the plot, in place of the one shown |
| Up / Down, Page Up / Page Down, Home / End (record list focused) | The next / previous record, a page on / back, the first / last record, in the order the list shows (a click on a column's header sorts it), shown in the plot |
| Click a record in the record list (focused) | Show it in the plot |

## The map window

```
┌ Map ──────────────────────────────────────┐
│ [Layers] [-][+][fit][<] [⚙]               │  controls (they wrap when narrow)
├───────────────────────────────────────────┤
│ 446000 ┤ ·  ·  ·  ·  ·  ·  ·  ·  ·     ▲ │  survey coordinates, north up,
│        │   •     •        •          N │  equal aspect; tick values only
│ 445000 ┤ ·  ·  ◉  ·  ·  ·  ·  ·  ·       │  · receivers   • sources
│        │ ┌──────────────────────┐        │  ◯ the open file's own positions
│ 444000 ┤ │ Receiver, line 104, … │       │  the point under the pointer
│        │ └──────────────────────┘        │
│        │ 2000 US ft                      │  scale bar
│        └┬──────┬──────┬──────┬───────────│
│      1834000 1836000 1838000             │
└───────────────────────────────────────────┘
```

- **Named "Map"**, with an identity of its own (Dear ImGui's `###map`) that layouts keep.
  At a first start it stands right of the plot, over the Headers window; a layout saved
  before the map existed names no map, and the map then joins the Headers window's place.
  The presets place it too, and **Plot and map** puts the plot and the map side by side.
- **Layers:** each loaded survey file's sources and receivers, as filled discs, sources
  over receivers; each open file's own sources and receivers (its trace headers'
  coordinates), as rings, so where the headers and the survey files agree each disc sits
  in its ring and where they do not both show; and the **highlight** on top: the selected
  points (the selection's colour) and the hovered ones (the hover colour), larger and
  outlined. Each layer can be hidden (**Layers** in the strip, or the right-click menu of
  one of its points). A layer's points get smaller as they crowd on the screen (from 5
  pixels across down to 2, from how far apart its points typically are), so lines of
  stations stay lines when zoomed out; a ring that small is drawn as a disc.
- **Colours:** the plot's background (the plot window's colour scheme: paper by default);
  sources in the theme's red, receivers in its blue, or its green where the blue is the
  accent that marks the selection (as in the Everforest themes), each made readable on
  the background; the highlight in the plot's hover and selection colours. Hover and
  selection are shared with the plot: a selection made on the map selects the points'
  traces, and the trace under the pointer in the plot lights up its source and receiver.
- **No basemap**, nothing fetched: survey coordinates as the files give them (SPS
  easting and northing, the trace headers' X and Y with their scalar).
- **Equal aspect, always, and the survey never lost:** zoomed out as far as it goes, the
  whole survey fits the plot (with a margin of 12 pixels for the markers on its edges);
  along an axis where the view is narrower than the survey it stays within it, and along
  one where it is wider the survey is centred. Every gesture, back and a new survey keep
  to it. **A new window size keeps the scale and the top-left corner**, as the plot does,
  but a map that shows the whole survey goes on showing all of it (a map has no scroll
  bars to reach what a smaller plot would cut off). A survey file loaded or a file
  closed: a map that showed the whole survey shows the whole new one; another view stays.
- **The axes** carry tick values only, as wide as the survey's largest coordinate always,
  so the plot's edge stays put; the units are in the status bar, the scale bar and the
  ruler, from the survey file's header (`H20`, `H201`: `ft`, `US ft`, `m`, or its own
  words); "units" where nothing says.
- **A scale bar** (1, 2 or 5 times a power of ten, at most 150 pixels long) in the plot's
  bottom-left corner and a **north arrow** (grid north) in its top-right one.
- **The strip:** Layers, zoom out, zoom in, fit, back, and the gear: where the point under
  the pointer is described, beside the pointer (the default) or in a strip along the map's
  bottom (kept when nothing is pointed at, so the map does not change size).
- **Levels of detail.** When the points outnumber the pixels, the map draws a point per
  cell of a grid no wider than two pixels (the first point of the cell, a real
  position), and every point once zoomed in closer. The grids, from twice the spatial
  index's cells to one cell for the whole layer, are made with the layer, on the worker
  that reads the file, and go to the GPU with it, so no pan or zoom waits for a level:
  each frame draws the level its scale needs, and only the rows of cells in view.
- **Speed** (measured under software OpenGL, Mesa's llvmpipe, in an optimised build, on a
  32-core machine busy with other work, load 30 to 38): a million receivers 5 m apart in a
  square, as dense as a survey gets, are read, indexed and given their levels in about a
  second; on a map of 400 × 560 pixels they draw about 63 000 points at fit and 100 000
  zoomed in, and a frame of the whole window while the map pans or zooms took 1 to 7 ms
  more than an idle one (medians 42 to 48 ms against 41 ms idle: on that machine at that
  load the idle window alone took 41 ms). An idle map draws nothing.

### The map's own choices

Taken here, in the plot window's conventions, and not yet put to the user (each says
what it was instead of):

1. **The point under the pointer is described beside it** by default (a box drawn in
   the map, kept inside it), the strip along the bottom a setting. (Either was asked
   for; the box is the one the eye is already at.)
2. **A click on a point selects it and its traces**, whatever the point; the plot's
   design had a click on a source open its record, which comes with the linking of the
   map and the plot.
3. **A map that shows the whole survey keeps showing it when its window changes size**;
   any other view keeps its scale. (The plot keeps its scale always, but it has scroll
   bars.)
4. **Sources are red, receivers blue** (green where the theme's blue is its accent); the
   open file's own positions are rings in the same colours.

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
| The map, a million points | a pan or a zoom draws at once from the levels of detail on the GPU; see the numbers in [The map window](#the-map-window) |
| Response to a zoom or pan | the view moves at once with what is already drawn; new data replaces it as it arrives; a pan of up to a whole view (an arrow key, Shift + arrow, a click on a scroll bar's track) finds its data on hand: a view and a half is read ahead on each side, and read again as the view moves once less than a view is left (the user: "arrow and shift arrow have visible delay in data being drawn") |
| Work per view | only the traces and samples on screen (plus that read-ahead, which shrinks to keep a tile within 64 MiB, and the filter margin); a panel's tiles hold 192 MiB at most; in density zoomed out past a trace per pixel, only the traces drawn; in the wiggle modes at most a trace per pixel column, every one of them read |
| Open | progress and Cancel at once; a second open of an unchanged file reads its index cache |

## Decisions

Each choice the draft left open, with the user's answer (2026-11-14). "Confirmed": as
the draft had it; otherwise, what the user changed is what this page describes.

1. **Wheel zooms, drag pans** (on a touchpad, two-finger scrolling zooms). Confirmed.
2. **Shift + drag selects a box, Ctrl + drag draws a ruler** (velocity in the plot,
   distance on the map); Alt is left alone. Confirmed.
3. **Right drag is box zoom, a right click the menu** (told apart by whether the mouse
   moved). Confirmed.
4. **Single keys** (`K`, `R`, `F`, `H`, `M`, Space) act on the trace under the pointer
   or the selection holding it, while the plot has the focus. Confirmed.
5. **Hover orange (the theme's highlight), the selection in the theme's accent
   colour**, each made readable on the plot's background. Confirmed, and both are the
   user's to set among the plot's six colours (22).
6. **Fit all is Ctrl + `0`** (and a button); **back is Backspace or Alt + Left**.
   Confirmed.
7. **A double-click does nothing extra.** Confirmed.
8. **Ctrl + arrow keys zoom along one axis.** Confirmed.
9. **The display gain starts automatic:** AGC over 500 ms on pre-stack records, none on
   stacked data; 3 dB steps on `]` / `[`. Confirmed; and the user asked that every
   setting of the gain drop-down be remembered, with sane defaults for a new
   installation (the defaults' table under the gain), and that the Exponential gain
   have a cutoff time (2 000 ms by default, after which it holds).
10. **A typed scale keeps the top-left corner.** Confirmed.
11. **Zoom steps:** a wheel notch 1.25, a key or button 1.5. Confirmed.
12. **The shot time is the record's UTC time.** Confirmed.
13. **The amplitude read out is the displayed value.** Confirmed, with a **raw
    amplitude** field beside it, off by default (the user: "ok but off by default").
14. **A new window size always keeps the scale** and the top-left corner (the user: "i
    would rather the plot scale stays the same and scroll bars apear if ti cannot be
    shown"); the scale grows only where the plot becomes larger than the whole record.
    Changed by the user: the draft kept the whole record along an axis that showed it.
15. **A click on a scroll bar's track pans by a whole view.** Confirmed ("this is also
    what fast panning with the arrows and modifier should do"): Shift + arrow pans by a
    whole view, and the plot reads ahead far enough that such a step shows its data at
    once (a view and a half on each side, kept to at least a view as the view moves).
16. **Line/Station and By Flag differ only within a station**, By Component groups the
    components; clicking the selected sort button goes back to the file's order.
    Confirmed ("by flag will sort by line/station then by component").
17. **A sort keeps the view.** Confirmed.
18. **Sort keys are the display header's fields**; raw header words come with the gather
    domains. Taken as built.
19. **Density only when it is chosen**, and in the wiggle modes zooming out stops at one
    pixel a trace (the user: "it should only be on if the user is asking for it",
    "maybe dont allow a zoom out that far?"). Changed by the user: the draft handed over
    to density below 4 pixels a trace.
20. **The trace overlap is 1 by default**, from 0.1 to 10, in plain sight in the strip
    ("Trace overlap should be configurable"). Changed by the user: it was in the gear
    popover only.
21. **Ctrl + click adds a trace to the selection or takes it out**, a plain click
    replaces it, Shift + click selects a range in the order shown (the user: "shoudnt
    this be control click"). Changed by the user: the draft had Shift + click add.
22. **Every colour of the plot is the user's**, the negative fill red by default ("I kind
    of like the other color for negative fill"), all six in plain sight in the gear
    popover. Changed by the user: the colours were behind "My own colours".

Also decided with the user, beyond this list: the click that brings a window forward
does only that (Mouse and keys); a trace the file marks dead is never drawn (the display
gain); Tab moves between a window's controls, not between files (Everywhere); the
Records window shows each record's traces, dead traces and the traces missing from its
patch; auxiliary traces are shown through the Seismic and Aux toggles, ahead of an Aux
window of their own.
