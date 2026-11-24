# The plot window and the map: design

> **Confirmed by the user** (2026-11-14). Built from the user's requirements and feedback;
> every choice that was open in the draft is now the user's decision, as
> [Decisions](#decisions) at the end lists, with what the user changed.

## Layout

```
┌ Seismic ───────────────────────────────────────────────────┐
│ [◂ 1 / 1 ▸] [-][+][fit][<] [▒|∿|▒∿][◢|◣] [Gain ▾][-][+0.0 dB][+] │  controls (they
│ [Filters][Raw] [Sort: file order ▾]              [⋯]       │  wrap when narrow; the
│                                                            │  gear stays on row 1)
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
- **Time down, or time across:** as seismic is plotted, time runs down and the traces
  across; the **Time across** checkbox, under Plot in the gear's Look tab, turns the plot so
  that time runs from left to right and the traces are stacked from the top down, as
  signals are drawn (see
  [Orientation](#orientation)). The Seismic window starts time down; every plot window,
  single traces and overlays among them, can be turned.
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
  from "999" to "1000" as the view pans. (When time is across, its values run along the
  bottom, where their width moves nothing.)
  The last visible time is always labelled: with the whole trace in view it is the last
  sample's time (11999 for 12 000 samples at 1 ms, where the round ticks stop at 11000),
  zoomed in it is the last time in view, and the first visible time is labelled at the
  other end. A round tick too near an end label to be read beside it is left out. The
  same holds with time across and in the density display.
- **The cursor's time line**, the **Cursor time line** checkbox under Plot in the gear's
  Look tab (off by default, remembered between runs): when on, a thin line runs along the pointer's pixel row
  from the pointer across the plot to the time axis, and the pointer's time is written
  at the axis on that row, right-aligned as the tick values are, on a small box over
  them, to the sample interval (whole ms at 1 ms or coarser); when time is across, the
  line runs down the pointer's pixel column to the time axis along the bottom, and the
  time stands under it, over the tick values. It is drawn over the plot's image each
  frame, so it follows the pointer without lag and reads and redraws nothing; it is not
  drawn when the pointer is off the plot. Its colour is the theme's crosshair colour,
  made readable on the plot's background, with a halo of that background on each side,
  so it shows on paper and on the theme's plot, over wiggles and over density. **With
  it, the display header's values of the trace under the pointer** stand in a box over
  each of the header's rows, at that trace's column (in each of its columns, at the
  trace's row, when time is across), in the style of the time box: a
  trace's line and point can be read where the rows are thinned because the traces are
  close (the user: "a box displaying the header like the one that gives the time would
  be nice for when not all headers are shown"). No vertical line: the trace's highlight
  marks the trace.
- **Scroll bars** appear when part of the data is out of view: under the plot when not
  every trace is shown, right of it when not all of the record's time is (when time is
  across, the other way round: time under the plot, the traces right of it); none when
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
- **Display header along the top** (beside the plot, at its left, when time is across):
  rows of trace header values over the traces (columns beside them), thinned so labels
  never overlap. Any trace header field can be a row (among them the component
  of a multi-component station), and there can be several; the default is receiver
  **line** and **point**. While the record has an edited trace, a last row, **edits**,
  marks each one over its trace, as the edits are now: **K** (killed, in the theme's
  error colour), **R** (reversed, in its accent colour), **E** (excluded from the plot's
  filters), **KR** for both, a thin bar where
  traces are too close for the letters; the row goes when the record has no edit left.
  Hovering a mark highlights it, and the tooltip ends with "Right-click to remove".
  A right-click on a mark opens a menu to take that trace's edits away (one step each;
  several traces that share a pixel when zoomed out are one step together). A right-click
  elsewhere on the header is still the header's menu.
  What the row shows but viewSEG does not remember, an edit made through agent control
  for the session only, has a **\*** after it (**K\***; its bar an outline); an edit
  remembered but hidden for the session (an agent undid your kill: it comes back at the
  next run) is in brackets, in the dim text colour: **(K)**.
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
  - **display mode** (▒ ∿ ▒∿ above): density (grey, or the colour map chosen),
    wiggles, or wiggles over density, and two toggles for the wiggles' fills (◢ ◣): the **positive fill** (the
    lobes right of the trace, above it when time is across) and the **negative fill**
    (left of it, below it), either, both or none; the symbols turn with the plot. The default is **wiggles with the positive fill**, black on white paper.
    The fill toggles are drawn in the two wiggle modes, not in density. The **trace overlap**
    (the largest swing of a wiggle, in trace spacings: see [Wiggles](#wiggles)) is in the
    gear's Traces tab, as the gain amount is shown: a box to type into, and - and
    + stepping through 0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8 and 10;
    greyed in the density mode, with a "(with wiggles)" note.
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
    overlap, the colours, the gain type, amount and settings, the order, the display
    header's fields and the Seismic / Aux choice (`Settings.plot`: a new plot starts as
    the user left the last one; polarity is not kept, reversing it being an operation on
    the data; which components are off is not kept, that choice holding for one file);
  - the **orientation** (a checkbox under Plot in the gear's Look tab, with the cursor time line):
    time down, or, while it is on, time across ([Orientation](#orientation)); kept with
    the display, so a new plot window starts the way the last one was left;
  - **Seismic and Aux** (the user, asked whether auxiliary traces should wait for an
    Aux window: "filter toggle"), two toggles shown when the record holds auxiliary
    traces (a time break, a pilot, an uphole): Seismic is on at first; with Aux on too,
    the auxiliary traces are drawn in the same plot, in the file's order among the
    seismic ones (`TraceFilter`, `ckFilter`), at the same scales, and the window is
    titled "Seismic + Aux"; with Seismic off, "Aux" shows them alone. At least one stays
    on. The choice is kept with the other display settings: across records of the file,
    when another file is shown and when that file is shown again, for a new plot, and
    in the next run (`settings.nif`, `(seismic ...)` and `(auxiliary ...)`; a settings
    file that does not hold them starts with Seismic on and Aux off). A file with no
    auxiliary traces shows its seismic traces and does not change the remembered choice,
    so a folder being watched keeps showing the same traces on every new shot that has
    them. A record left with nothing the choice can show stays empty, and the plot says
    the trace filter hides every trace. Shorter traces are drawn as long as they are; an
    auxiliary trace whose sample
    interval differs from the seismic traces' is drawn at theirs, and the log says so
    (their times are then not to scale). Sorts, gain, edits, the display header and the
    readout work on them as on the others. The Aux window of its own, with its own
    filters, is still to come;
  - **scale boxes: traces per inch and ms per inch**, each a box to type a value into, at
    the top of the gear's Scales tab.
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
    step, 12 dB with Shift; held, they repeat), beside the drop-down or under it when the
    strip is too narrow, and keys (`]` or keypad `*` for more, `[`
    or keypad `/` for less; the same steps, repeating while held), from -300 to +300 dB
    (a factor of 10^15 either way: raw records span far more than 60 dB between the
    first breaks and the late times). The amount rescales the drawing at once and never
    reads or processes again; where the scale passes what the GPU's numbers hold, every
    sample that is not 0 is drawn at full scale. The type **None** applies no gain of
    any kind, so no amount either: its - and + buttons and box are greyed and read
    0.0 dB, and the amount you set is kept for the other types, not applied (no
    time gain either: the exponential gain's settings belong to Exponential only).
    A *reference* amplitude is drawn at **full scale** at 0 dB: at the ends of the
    density colour map (black for positive and white for negative in grey, blue and red
    in red-white-blue, yellow and dark purple in viridis), and a wiggle's full swing (the
     trace overlap); the types differ
     in what they do to the samples and in where the reference comes from. The drop-down's
     first row is **Let viewSEG choose** (ticked by default), with dim text naming the type
     it picked for this record; under a line, the six types are radios. The bar says
     "Gain: auto (AGC 500 ms)" or "Gain: auto (none)" while viewSEG chooses, and
     "Gain: AGC 500 ms" when the user picked the type:

    | Type | On the samples | Reference (full scale at 0 dB) | Settings |
    |---|---|---|---|
    | Let viewSEG choose (default; not a type) | AGC on shot and receiver records, nothing on stacked data | as AGC or None | the AGC window |
    | None | nothing; 0 dB whatever the amount (greyed) | the record's clip percentile of \|x\| (99 by default), held while panning | |
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
    | Gain | Let viewSEG choose (AGC on shot and receiver records, none on stacked data) |
    | AGC window | 500 ms |
    | Fixed amplitude | none until Fixed is chosen: then the record's clip percentile |
    | Normalized | each trace, to its clip percentile of the whole trace (zooming does not change the level; the reader decodes whole traces, as it does for filters) |
    | Exponential | 6 dB per second (the power of time: 2), until 2 000 ms |
    | Clip percentile | 99 (of \|x\|) |
    | Gain amount | 0 dB, in steps of 3 dB (12 dB with Shift), -300 to +300 dB |

    **The clip percentile** is the drop-down's last setting, under every type's own: a
    box for the percentile of |x| drawn at full scale (99 by default, from 50 to 100: 98
    clips harder, 100 is the peak), with the amplitude it gives now beside it and what
    it is taken from (the record, the data in view under Float, each trace under
    Normalized per trace). A new percentile never reads the file: the panel's reader
    works the level out again, off the screen's thread, from the samples it holds (and
    under Normalized per trace brings each trace to it again), and the picture before
    stays until the new one is drawn; under Float the level of the data in view is taken
    again at once. Fixed takes it when its amplitude is taken from the record shown.
    **The record's level is the record's, whatever is in view:** it is taken over all
    of the record. When the record's first view reads all of it (with its read-ahead:
    the fit in density), over that; when it does not (the scales carried from the record
    before, a wiggle mode's first screen), over every trace or every few, at most 256,
    which the panel's reader reads once the first view is drawn (a few reads; that view's
    own level stands in meanwhile, replaced once). A new clip percentile, a kill or
    restore, a filter change or a gain that runs on the samples, made zoomed in, has the
    reader work it out again over the same traces, from their samples, which it keeps
    apart from the view's (up to 32 MiB): nothing is read from the file for it, and the
    level held stays meanwhile. Over every few traces, a trace louder than its
    neighbours can be missed: the drop-down then says which (every 4th trace, ...).

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
  - **one Sort drop-down** (it says what is in use: a preset's name, "file order", or "custom"):

    | Button | Order |
    |---|---|
    | Line/Station | receiver line, then station (point), as the headers give them; a station's traces stay in the file's order |
    | By Flag | receiver line, then station, then component: a station's components side by side, in order |
    | By Component | the traces grouped by component, each group by line, then station |

    Picking the preset already in use does nothing; **File order** goes back. A preset whose
    keys the traces have none of (post-stack data has no receiver line, point or component)
    is greyed, unless it is the order in use. Other orders are keys of the user's own, from
    **Custom...** in the same list, and the drop-down then says "custom", while
    such an order is in use: a small popover lists the keys, the first first, each a
    display header field (line, point, component, channel, channel set, trace ID code, FFID,
    source line and point, offset, CDP, inline, crossline, trace number) and each ascending or descending; "Sort"
    applies them, "File order" goes back. Traces equal in every key keep the file's order,
    and unknown values come last either way. The keys sorted by last are remembered and
    offered again; the presets themselves are data in the settings (`sortPresets` in
    `settings.nif`), so a site can rename them or add its own;
  - the **record** shown: the previous and next record, and its place ("2 / 120"), which
    opens **Go to record** (a place in the file or an FFID). The next record is shown at
    the same scales as the one before (the same positions and times; the whole record
    along an axis that showed the whole record), with the same display, gain and order;
  - zoom out, zoom in, fit all, back to the view before the last gesture, and a "more"
    popover: the display presets, the colours, density's colour map, the trace overlap
    again, the display header's fields, the scale units and the screen calibration.
  - The strip's groups wrap as the window narrows: two lines in the default layout on a
    1920-pixel screen, three on a 1366-pixel laptop screen. Where its lines would leave
    the plot less than ten lines of text (a 1152 x 720 screen at 125 %: six lines),
    they scroll in a region of their own above the plot (the wheel scrolls them), so
    the plot keeps its room; agent control's `wait` never waits for a plot that has no
    pixels ("no room to draw"), and its screenshot is refused in words.
- **The status bar** (the main window's bottom edge) reads out what lies under the
  pointer in the plot: the time at the cursor, trace (its number in the file) and
  channel, receiver line / point, source line / point, FFID, offset, amplitude and the
  shot time (the record's UTC time). The amplitude is the sample after the display's
  processing and the gain types that change the samples (AGC, Exponential, Normalized for each
  trace), not the gain amount or the scale-only types (None, Fixed, Float, Normalized for the
  whole record); zoomed out the largest of the samples drawn at that
  pixel ("peak of 4"). Right-click the bar to choose the fields and their order; any of
  the trace's keys can be added (sample number, UTC at the cursor, CDP, inline,
  crossline, source, receiver and midpoint coordinates, elevations, component, trace
  status, trace ID code, SEG-D channel set), and the **raw amplitude** (the user: "ok but off by default"): the sample as
  it is in the file at the cursor, before polarity, edits, processing and gain (zoomed
  out, the largest of the samples there, as the amplitude). It is off until chosen;
  while it is on, each tile carries the file's samples beside the drawn ones, cut the
  same way, so the readout takes them from what is on hand and nothing is read for it
  on the screen's thread. Unknown values are left blank. Whatever the fields, the bar says "dead" over a
  trace the file marks dead, and "killed", "polarity reversed" or both over an edited
  trace, in the theme's warning colour.

## Orientation

A plot can be drawn two ways (the user, on the vibrator analysis plots that reuse the
plot: "realistically some of these plots will need to be rotated -90 degrees and
displayed left to right"), chosen per plot window by the Time across checkbox in the gear's
Look tab and kept
with the window's display. The Seismic window starts time down; a window made for single
signals can start time across.

| | Time down (as seismic is plotted) | Time across (as signals are drawn) |
|---|---|---|
| Time | downwards; its values left of the plot | from left to right; its values along the bottom |
| Traces | across, the first at the left | stacked from the top down, the first at the top |
| A positive amplitude | swings right, towards the next trace | swings up, towards the trace before |
| Display header | a row per field above the plot, the names at the left | a column per field left of the plot, the names above them, each as wide as its field's longest value in the gather (so the plot stays put as the view pans); the edits column next to the plot |
| Scroll bars | the traces' below, time's at the right | time's below, the traces' at the right |
| The cursor's time line | from the pointer left to the time axis, the time over its values | from the pointer down to the time axis, the time over its values |
| The header's box at the cursor | over each row, at the trace's column | in each column, at the trace's row |
| Traces per inch, ms per inch | along the plot's width, along its height | along its height, along its width |
| Zoomed out as far as wiggles go | a pixel column a trace | a pixel row a trace |
| The edge traces' whole wave | left of the first trace, right of the last | above the first, below the last |

- **One mapping.** Every part of the plot finds where a trace and a time lie on the
  screen, and what lies under a point of it, through one mapping between the data and
  the screen (`core/orientation`): the picture (density, wiggles, fills, the hovered and
  selected traces), the display header, the scroll bars, the cursor's line and boxes, a
  box zoom, the trace under the pointer and the status bar's readout. The view itself
  (the traces and times shown, and the plot's pixels along each) is the same either way,
  so the limits, the zoom-out limit, the scales, the read-ahead and what is read do not
  depend on the orientation, and neither do the tiles and their textures. A pixel of the
  time-across picture is the matching pixel of the time-down picture transposed, with
  each wiggle swung the other way about its baseline (up rather than right): that is what
  the tests compare.
- **Every gesture and key acts in the screen's directions:** the wheel zooms about the
  pointer; Ctrl + wheel, and Ctrl + Up / Down, zoom up and down only (in time when time is
  down, in traces when it is across); Shift + wheel, the sideways wheel, and Ctrl + Left /
  Right zoom across only (in traces, or in time); the arrow keys pan the way they point;
  a drag carries the data with the pointer; a right drag zooms to the box drawn; a scroll
  bar's thumb lies where the view lies along it, and follows the pointer.
- **Everything that acts on traces acts on them the same way:** hover, selection, Ctrl +
  click, Shift + click's range in the order shown, the sorts, kills and reversals, the
  Seismic and Aux toggles and the link with the map.
- **The header takes room, not time:** fields added to the display header or taken
  away, the edits' band coming or going, or (time across) another gather's longer values
  make the plot shorter or longer along time; the time span shown stays the same (a view
  of the whole record stays whole), the scale changes.
- **A turn keeps the view:** the same traces and times are shown after it, at the scales
  the plot's other shape gives them (the scale boxes say which), within the limits: in a
  wiggle mode no more traces than the plot has pixels along them (a wider view is
  narrowed from its first trace); a view of the whole record shows it whole again.
  Nothing is read for a turn: the tiles on hand are drawn the other way round at once.
  Only where the plot's other shape needs another resolution (zoomed out past a trace or
  a sample a pixel, as a new window size can) is a new view asked for, as for any view,
  and it is made from the samples the reader holds (the last view read from the file:
  fewer of its traces, every second or fourth of them, at any decimation), without
  reading the file again; the picture on hand is drawn stretched until it comes. On a
  large field record (with your own file; an optimised build, llvmpipe, the machine at a
  load of about 12), at the widest wiggle view of the default layout, the sharp picture
  comes within a frame or two after the turn, and sooner in density: the processing and
  drawing of the new view; before, the turned view was read from the file again (on a
  local drive, from memory, as fast; on a network drive, a read of the view like any pan).
- **The first trace at the top** when time is across is the default taken (the traces
  then read down the plot as a table's rows and a chart recorder's channels do); whether the user would rather have it at the bottom (the
  time-down picture turned a quarter turn anticlockwise, "-90 degrees" taken literally)
  is asked. It is one constant (`FirstTraceAtTop`); either way a positive amplitude
  swings up.
- **Speed** (software OpenGL, Mesa's llvmpipe, an optimised build, the machine busy with
  other work at a load of about 65): turning costs nothing to draw. On the same plot, 400
  traces of 2000 samples on 720 × 720 pixels, a whole wiggle image takes 36 to 42 ms time
  across against 43 to 56 ms time down, and density 8 to 9 ms either way. In the default
  layout, where the plot is wider than tall, a turn gives time more pixels and the traces
  fewer: on a large record at the wiggle limit (with your own file), the tiles then keep
  more of the samples, and panning along the traces costs about the same either way.
  `samples/land/shots.sgy` is 96 traces: open record 1, turn it, and the first breaks
  near the source run down the page or across it. The pilot of
  `samples/vib/vib_uncorrelated.sgd` (Aux alone, normalized per trace) turns the same way;
  the window calls a SEG-D auxiliary trace "the first auxiliary trace", not "the pilot".

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
- **Order:** the tint of the hovered and selected traces' columns first, then each trace
  over the one before it; the hovered and selected traces once more, on top, so a
  neighbour's fill never hides a highlight. The line is one pixel
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
  The six and the scheme are remembered between runs.
- **The gear popover** is in three tabs: **Look** (display presets, colours and the
  density colour map), **Traces** (wiggles, killed traces and the display header) and
  **Scales** (scale units and the screen's calibration); the tab chosen last opens
  again. It opens below the gear, moved left or up as far as needed to stay inside the
  program's window (past its edge it would become a window of the desktop's own), and
  is never larger than the window: a tab taller than it scrolls. At 125 % in a 1152 x
  720 window (what a 1280 x 800 laptop screen opens) every tab fits.
- **Density has a colour map of its own**, chosen in the gear popover's **Density colour
  map** section, where each map is shown as its colour bar (the most negative amplitude
  at the left, the most positive at the right) with its name; a click on a bar or its
  name draws the plot in it at once, and reads nothing again. It is kept with the rest of
  the display (a new plot starts with it; it is remembered between runs):

  | Map | Negative | Zero | Positive |
  |---|---|---|---|
  | **Grey** (the default) | white | mid grey | black |
  | **Red-white-blue** | red | white | blue |
  | **Viridis** | dark purple | teal | yellow |
  | **Red-black** | red | white | black |

  The amplitude the gain draws full black in grey is the positive end of every map, its
  negative the other end. The two diverging maps run in straight lines from white at
  zero to their pure colours; viridis is matplotlib's (perceptually uniform, readable in
  grey and by most colour-blind viewers), its 256-entry table as published. The GPU draws
  through the map as a 256-entry lookup texture (`core/colourmaps`); the pixel tests
  compare it with the same map on the CPU, time down and time across. The map is
  density's only: the wiggles, the fills and the plot's background keep their colours,
  and the hovered and selected traces' columns are tinted over any map: in grey towards
  the hover and selection colours below, made strong enough to show on grey (their hue
  kept; orange and blue where the theme's are greys, as in White and Vantablack), in the
  other maps towards colours off the map's own hues, so a tinted column never reads as an amplitude (`highlights`):
  green and black in red-white-blue, magenta and white in viridis, green and blue in
  red-black.
- **"Paper":** white background, black wiggles and black positive fill, the theme's red
  (darkened to read on white) for the negative fill, whatever the UI theme. **"Follow
  the theme":** the theme's plot background, trace and fill colours.
- **Highlighting marks the trace without hiding its data:** a selected trace has a
  marker above it (a small triangle, or a bar where markers meet, in the selection colour;
  left of the plot when time is across), its whole column is tinted behind the data (the
  selection colour at low opacity, at least a pixel wide however far the plot is zoomed
  out), and its line, where it reads as a line, is drawn in the selection colour. A
  fill, and a line so dense that it is a band (a sweep, a trace swinging faster than the
  pixels resolve: more than 6 pixels across at one pixel of time), keep their normal ink,
  so selecting a sweep or the only trace of a record never turns the plot into a block of
  one colour. The hovered trace is marked the same way, with a weaker tint and no marker;
  under density alone, a column is tinted towards the colour. Hover is the theme's highlight
  colour (orange); the selection is the theme's accent colour (the colour of a selected
  button), so the two never look alike. The theme's own "selection" colour is a
  background tint, which would not show as a line on paper. Each is darkened or
  lightened just enough to read on the plot's background. A trace both hovered and
  selected shows the hover. Hover and selection are survey-wide trace ids, shared with
  the map.
- **Components.** A record is multi-component when its traces, before the component
  buttons, carry more than one distinct component (`TraceKeys.component`, the value
  By Component sorts by: a SEG-D group index when that is set, else the sensor type;
  a SEG-Y trace identification code when it names a component). Traces are still told
  apart, counted and filtered by that value: one button per distinct value present.
  Each trace is drawn once, side by side, never overlaid. The button's name, letter
  and colour come from what the trace says it is, not from the group index. For SEG-D
  that is `TraceKeys.sensorType` when it is a named sensor: 1 hydrophone (H, blue);
  2, 3, 4 vertical, inline and crossline geophone (Z, X, Y: green, yellow, teal);
  6, 7, 8 the same three as an accelerometer (the same letters and colours; the
  tooltip says accelerometer). A SEG-Y trace leaves the sensor type unset and puts
  the identification code in the component, so the same rule uses codes 11..17.
  Several components with the same sensor, or with no named sensor, are labelled
  with the component number and take the four configured colours in order, green
  first; further ones keep the normal ink. The tooltip says what is known
  ("component 2 (vertical geophone), 24 traces"). In a wiggle mode that colour is
  the line and both fills (a hovered or selected trace still takes the highlight).
  In density the colour map is unchanged and a thin band of the component's colour
  is drawn along the top of each trace column (along the left edge when time runs
  across). The strip draws one toggle per component present, after the Seismic / Aux
  toggles: named sensors in the order hydrophone, vertical, inline, crossline, then
  the numbered ones by their component. All are on at first. Turning one off removes
  its traces and the plot is laid out again with the rest, as the Seismic / Aux
  filter does.   While any component is off, the window's title says how many traces are
  hidden ("24 of 96 traces hidden: hydrophone off"). The last one on cannot
  be turned off. The choice holds across records
  of the same file (what is switched off, so a component first seen on a
  later record is shown) and resets when another file is shown. A record
  that would be left with no trace, because every component present is
  off, is shown whole again, and one message says so. The buttons stay while any
  is off, because multi-component is judged before the filter. A record with one
  component draws nothing new. The colours are the gear's Look tab, **Component
  colours**: four pickers and Reset, stored with the other settings. The defaults
  read on white paper and on a dark plot. The buttons are the legend.
- **Killed traces, and traces the file marks dead,** are drawn blank: the plot's
  background shows where the trace was, in every mode (no line and no fill among wiggles,
  no grey under density), with only the hover's tint under density alone. Hiding them instead (the traces closing up) is a
  setting to come.

## Display presets

A **display preset** keeps a whole display under a name, to put it back with one click:
the mode, the fills, the trace overlap, the colours (the scheme and the six), density's
colour map, the gain type with every setting of its drop-down, the gain amount and the
clip percentile. Not the orientation: applying a preset leaves the plot turned as it is.
They sit under their own **Display presets** heading in the gear popover's Look tab, below
the Plot checkboxes:

- the presets, in the order they were made, each a line to click: the plot is drawn as
  it says at once (as if each control had been set; only what changes the samples, a
  gain type that runs on them, reads again, from the samples at hand). The preset the
  plot shows now is drawn selected. A right-click on one opens its menu: **Apply**,
  **Rename to** the name in the box, and **Delete**, without the plot being drawn as it
  first;
- a box for a name and **Save**: the display shown kept under that name (a name already
  there, in any case, is replaced in its place); **Rename** gives the preset clicked or
  right-clicked last the name in the box; **Delete** forgets it. A name is not empty and at most 64
  characters; at most 32 presets are kept. What cannot be done (no such preset, a name
  taken) is said in the Messages window.

The presets are kept in the settings (`displayPresets` in `settings.nif`), so they come
back in the next run; a settings file of an earlier build has none, and reads without a
word. An agent can apply, save, rename and delete them too (the `display preset`
command), for the session only, as with every other setting it changes.

## First-break overlay

A toggle button on the Seismic window's strip, beside the display modes and fills, and
**Analysis > First-break overlay** (ticked while it is on; it has no shortcut) turn on the
same setting. For each trace of the record shown the plot draws, in the theme's two roles
`break_model` and `break_pick`, a short thin bar across the trace's column:

- at the time a refraction model expects the first break (processSEG's `fitShot`, fitted to
  the confident picks of the record against the traces' source-receiver offsets; the
  bar is the model's `modelMs`), and
- at the time the first break was picked (processSEG's first-break picker, its defaults).

A trace is flagged, with a thin line joining the two bars and a heavier pick bar, when it is
off the model or off its neighbours (below). A pick that is not compared (confidence below 0.5,
or farther from the model than the guided window, 20 to 100 ms from the fit's scatter) is a weak pick: it is not drawn unless **Show weak picks**
is ticked (below), and then faint with no line; the counts and the flags are the same either way. A trace with no pick shows only the model bar; a trace the model cannot
place (no offset) only the pick. The bars have a halo in the plot's background colour, so they
read over the wiggles and over density. They are the traces' own: they follow zoom, pan, the
sort order and the trace filter, are drawn for the traces in view only, and a killed trace has
none. A time-shift edit moves the pick bar, and the status bar's pick time, with the
samples (positive later, whole samples, the same move the plot applies); the model bar
does not move, and a reversal does not. A stored shift on a killed trace is not applied. Where the traces are closer than three pixels the bars become two lines through the
times (the model's and the pick's). A key beside the overlay's button names the two colours
("model", "pick"), marks a given model with a small "given" and, in the warning colour, counts
the traces more than 12 ms off it ("358 off"); it is the same width whatever the model, and
says what the overlay lacks (while it is working, why it failed, or that the model needs a
survey) beside it. Hover it for everything else: the model's velocity or velocities,
intercept, crossover, the record's median of pick less model, the counts, and where the
offsets came from.

**Showing one kind.** Click the key's "pick" or its "model" to hide that kind of bar and see
the other alone; a hidden one stays in the key, dimmed with a hollow swatch and its word
struck through, and a second click shows it again. The line joining a pick to the model is
drawn only while both are shown; with only the picks shown, a pick off the model keeps its
heavier look. With both hidden the plot has no overlay drawing but the key stays (the overlay
is still on). Hiding changes nothing else: the status bar, the tooltip, the counts and the
agent's `firstBreaks` state are the same. The popover also has **Show picks** and **Show
model** boxes at the top of its "Colours and size" part, and the small wheel at the key's end
opens the popover (a click on the key's "given" or count part does too). The two switches are
`breakShowPicks` and `breakShowModel` in `settings.nif` (written only when off), no display
preset carries them, and the agent's `display` command takes them.

**Showing the weak picks.** The popover's "Colours and size" part has a **Show weak picks** box,
off by default: a pick that is not compared with the model (low in confidence, or no break
found near the model) is then left out of the picture, which shows the picks that mean
something. Tick it to draw them faint as before. It is a drawing choice only (no new picking),
kept as `breakShowWeak` in `settings.nif` (written only when on); no display preset carries it,
and the agent's `display` command takes it.

**Colours and size.** The key's popover has a colour box for each bar (the pick's and the
model's), a **Reset colours** button (back to the theme's pink and blue) and a **Size**
choice. Medium, the default, makes a bar about 80 % of one trace's width on the screen
(at least 7 pixels, at most about 40) and at least 3 pixels thick, with a halo so it reads
over black fill and over white paper; Small is the thin short bar of before, Large a longer
and thicker one. The joining line uses the pick's colour. Colours and size are kept with
the plot's display (`breakPickColour`, `breakModelColour`, `breakSize` in `settings.nif`) and
no display preset carries them; the agent's `display` command takes them, and a panel's
`state` shows them in its display.

**Pick on.** The popover's "Picking" part chooses what the second (guided) pass reads: **Smoothed
(high cut 60 Hz)**, the default, or **As recorded**. Smoothed picks on a zero-phase high-cut copy
of each trace (processSEG's Butterworth, 24 dB/octave, corner 60 Hz or 0.8 of the record's
Nyquist frequency if that is lower, no phase shift); the samples the plot shows are never
changed. A wavelet that builds slowly is then picked nearer its start, and more of the visible
breaks get a confident pick (on a record whose wavelet built over 40 ms, the picks came 2 ms
nearer the onset and 54 of 60 traces had a confident pick, against 39). The words name the cut
actually used. When the record's sample interval leaves the cut below 40 Hz (an interval over
10 ms), or its traces are too short for the filter, the picks are made on the samples as
recorded and the popover says so. Changing the choice picks the record again once (the first
pass does not change); the record's noisy-trace check, which uses the same picks, follows it
while the overlay is on. Kept as `breakPickOn` in `settings.nif` (written only when "as
recorded"); no display preset carries it, and the agent's `display` command takes it. Both
choices use a 40 ms window in the guided pass (the first pass keeps 20 ms). A trace holding a
NaN or infinite sample is always picked as recorded (the filter would spread it over the whole
trace). The key and the agent's `state` say what the picks shown were made on: when the first
pass's picks are shown (no model to trust), they say as recorded and 20 ms. Panels on one
record with different choices each keep their own result.

**Picking and the model.** The record is picked twice. The first pass has no search window, so a
trace with no visible break gets a pick on noise. A model is fitted to those picks, dropping
the picks far from it (a start from the closer half, then the picks within three robust
sigmas, at least 12 ms, of the fit, up to five rounds; at least 10 picks must remain). The
second pass picks every trace again in a window either side of that model: four times the
scatter of the trimmed first-pass fit, at least 20 ms and at most 100 ms (100 ms when that
scatter is not known). The picker uses its own guide, with energy windows 40 ms long, on the
smoothed copy by default, and the model is fitted again, trimmed the same way, to those
picks; it is one straight line unless a second segment has at least 15 trimmed picks beyond
the crossover and fits clearly better, or the two segments hold at least 15 more of all the
confident picks than the line does (so a bend whose far segment holds most picks stays two
segments). That fit is what "Use this record's fit" copies. When fewer than 10 confident picks
hold together, the first-pass picks stay and the key's note says so. With a given model the
shown picks come from a pass guided by it instead, in a window of the same width from the
scatter of the fit then in use.

**Which traces are flagged** (one rule decides, so the key, the marks, the words and the agent
state agree):

- *Where a break is expected*: the record's traces are cut into about 20 bins of offset (at
  least 10 traces a bin), and the range runs out from the nearest offsets to the end of the
  last bin before one where fewer than a fifth of the traces have a confident pick within
  that guided window of the record's fit; it never runs past the 95th percentile of the offsets of the
  picks both passes agree on (kept by the fit, and the first pass's pick confident and as near
  the fit). So noise the guided window happened to hold at long offsets does not widen it, and
  a stretch of real breaks the fit misses does not end it. A trace with a model time beyond
  that is *beyond the offsets where breaks are seen*: counted apart, never judged, never a
  finding.
- *Comparable*: within that range, a confident pick (0.5 or more) within that same window of
  the model. Any other trace in range is *no break found* and not flagged, unless the first
  (unguided) pass found a confident break outside that window and at most 400 ms from the model,
  not before the model's intercept less
  the limit, while the guided window found none: that is *far off the model* (a station placed
  a few hundred metres wrong), and flagged, drawn with its link to where the break was found.
  A first-pass pick farther off, or before any break can arrive, is noise.
- *Off the model*: the residual (pick less model) of a comparable trace is larger than the
  record's limit, the larger of 12 ms and three times 1.4826 times the median absolute deviation
  of the picks' scatter about the record's own fit, whichever model is shown (a given model that
  fits badly cannot widen its own limit).
- *Off its neighbours*: the residual less the median residual of up to three comparable
  neighbours on one side along the same receiver line (in receiver point order; file order
  where lines or points are unknown; at most six stations away), taking the left side's, the
  right side's or the mean of the two, whichever is nearest the trace's own residual, is larger
  than the larger of 12 ms and four times the robust sigma of the differences from the mean of
  both sides. Traces off the model count as neighbours too, so a stretch the model misses (a
  bend, a static) is followed, a block of wrong stations flags only itself, and one wrong
  station inside the stretch is still found. A trace with fewer than three neighbours is not
  judged this way.
- *The record's words*: when the traces' azimuths from the source cover at least 180 degrees,
  and the azimuths are spread well enough round the source (a line through it is not enough),
  the residuals are fitted as a constant plus a cosine and sine of the azimuth; otherwise only
  a constant (their median) is looked for. A lean or a constant beyond the larger of 10 ms and
  two times the scatter left after that fit says "the picks lean to one side of the source by N
  ms (earliest towards bearing B degrees, clockwise from north if x is east and y north): the
  source may be placed or named wrongly" or "every pick is early (late) by N ms".
- *A given model that does not match*: when its median residual is beyond the limit, the picks'
  scatter about it is more than twice the picks' own scatter, or it finds fewer than half as
  many comparable traces as the record's own fit does, the words say the given model does not
  match this record's breaks and give the record's own fit (velocity or velocities, intercept)
  beside it, and say nothing of the source: the model is the likelier fault. The record's own
  fit given as a model always matches.

The key counts the traces flagged (off the model, off its neighbours or far off the model);
the tooltip reads "N flagged (M of K compared off the model, P off their neighbours, F far
off)", the far-off traces not being among the K compared. The given model's numbers apply at
once to the picks already there; the picks guided by it are made again in the background and
replace them when done, while the key says "picking again for this model...". Each model a
panel shows keeps its own picks (two panels on one record with two models each keep theirs;
the last few models of a record are kept, so going back to one is immediate). If that picking
is stopped (in Jobs) or fails, the picks guided by the other model stay drawn and the key and
the tooltip say whose they are; giving the model again picks again. Its boxes take a number
when Enter is pressed or the box loses focus; Escape puts the old number back.

The offsets are the trace keys': where a join set both ends of a trace, the distance between
the survey's positions (a header offset the join left is not trusted over them), else the
header's as the layout the file was opened with reads it (a vendor map's divisor included),
else derived from the file's own coordinates with the coordinate scalar applied (a negative
scalar divides, a positive one multiplies, 0 is none). With none the picks are drawn alone and
the key says so. A join that arrives (or changes) after the overlay was made makes it again.
The overlay never corrects an offset: when the fitted velocity is no first-break velocity for
the offsets' unit (under 300 or over 30 000 m/s, in feet likewise), the key says the offsets
look wrongly scaled, and the hover says by about what factor against a typical 3000 m/s; check
the vendor map, the coordinate scalar and the units. "Use this record's fit" refuses a fit
above the 1 000 000 a given model takes, and says why. The model is one time against offset for the record, whatever its
receiver lines; a record of several components is fitted from one sensor kind. The stations are
compared along each receiver line. The work runs on a job (Jobs lists it) for the record shown
and is kept for it (the last few records stay, so stepping back is immediate); it is made
again when the file's keys change (a join, a header edit) or a trace of the record is killed or
restored, and a result that arrives after the record, the keys or the edits it was made for have
changed is dropped. The status bar adds, for the trace under the pointer, the model's time, the
pick's and their difference.

The setting is the window's, off in a new one until turned on, and kept with the plot's
display (`firstBreaks` in `settings.nif`) so a new plot starts as the last was left; a display
preset does not carry it.

**The model's source.** By default the model is fitted to the record's own picks, so it follows
the record and cannot show a source at the wrong place. Click the key ("model", "pick") to give
a model instead: a velocity (in the offsets' unit per second), an intercept in ms (0 by
default) and, optionally, a second velocity beyond a crossover offset (the same two-segment
shape as the fit, continuous at the crossover). The expected break of every trace with an
offset is then the intercept plus its offset over the velocity, the same for every record; the
second velocity and crossover are behind a **Two layers** checkbox (off: velocity and
intercept only; "Use this record's fit" turns it on when the fit has a second segment); the
key shows "given" and the count flagged, the flags are the rule above against the given model,
and the key's tooltip gives the velocity, the record's median of pick less model and how many
of the compared traces are flagged. The velocity's unit is the offsets' (the
file's, or the import's); a file that names none takes the project's survey's, when it
names a length, and the tooltip says so (only the label: nothing is converted). **Use this record's fit** copies the fitted numbers of the record shown into
the boxes and switches to Given: a model calculated once on a good record and held for the
others. It is kept in the project when one is open, else in the settings (`breakModel` inside
the plot's display in `settings.nif`; a preset does not carry it). The noisy-trace test's
exclusion area keeps using the fitted model.

## Polarity

Reversing the polarity turns the trace data 180 degrees out of phase: an operation on the
samples, not a way of colouring them. **Reverse polarity of all traces**, in the plot's
right-click menu (ticked while it is on), is a file edit, remembered with the file and
undone with Edit > Undo. It holds for every record of the file, comes back when the file
is opened again (also after a restart: [Edits](#edits-to-traces)), and another file is
shown as it was left. It is not a setting. On the Seismic picture it runs processSEG's
`polarityOp` first on every trace the window reads, before its gain, so the picture, the
gain's statistics, the status bar's amplitude and Headers shown as displayed see the
reversed data. The same reversal applies in every graph of the file: a spectrum and its
phase, a spectrogram, an envelope and its instantaneous phase, a correlation (the
traces correlated; the chosen reference stays as stored), a vibrator
signature, an f-k, and the live spectrum panel. A window that is not frozen asks again
when reverse-all is set, cleared, undone or redone; a frozen one does not. With it on,
the line under a graph says "All traces are reversed" once, and does not also list every
trace. Turning it on or off reads the view again; the picture before stays until the
reversed one is drawn. Headers shown as recorded, the hex view and the status bar's raw
amplitude stay the file's samples.

**Reverse polarity** of a single trace, or of the selection that holds it (`R`, or the
plot's menu), is an edit of the file's traces (see [Edits](#edits-to-traces)): those
traces' samples are negated (processSEG's `reversePolarity` on their live samples, as
`polarityOp` does) where the window's reader prepares them, before the pipeline and the
gain. The same sign flip, before that trace's own filter and the plot's filters, is part
of every graph of the trace: a spectrum and its phase, a spectrogram, an envelope and
its instantaneous phase, a correlation, a vibrator signature, an f-k, and the map's amplitude flags.
No box turns it off. A window that names a trace's own filter names the reversal the
same way ("Trace 12: reversed", "N traces are reversed").
An open window that is not frozen asks again when a trace it shows
is reversed, put back or undone; a frozen one does not. A cross-correlation's reference
is the one chosen in References and stays as stored. Headers shown as recorded, the
hex view and the status bar's raw amplitude stay the file's samples. A trace reversed
both ways (this edit and reverse all) is as recorded everywhere, on the plot and in every
graph, and a graph does not call it reversed. A trace the file marks
dead stays blank, reversed or not (it is never drawn); the display header and the status
bar still say it is reversed.

## Filters

The **Filters** button in the strip (a funnel icon, lit while filters are applied), after
the gain button, opens a drop-down that says what the
traces go through ("Filters: 8-14-60-80 Hz, notch 60 Hz x3, DC"; "Filters: none"), as
the button's tooltip does, and holds every setting, applied as it is set (a number typed into a box is taken on Enter, Tab or a click away). The traces go through, in
order: the **DC removal** (none, the mean: `demeanOp`, or the mean and a linear trend:
`detrendOp`), then one zero-phase filter (processSEG's `filterOp`): a **low-cut**,
**high-cut** or **band-pass** by its four corners (`f1` to `f2`, the low-cut ramp; `f3`
to `f4`, the high-cut ramp; cos² ramps, `bandPassOp(Corners)` when there is no notch),
and the **notches** (`withNotch`: each at a frequency, with a width and a number of
harmonics; **+ 50 Hz** and **+ 60 Hz** add the power line's with two harmonics). Then
the polarity and the gain, as before. The corners and the notches' frequency and width are boxes you type Hz into (nine
significant digits kept, a number that cannot be there refused with a line that says
where it may be), each corner between its neighbours (`f1 < f2 <= f3 < f4`, `core` keeps them
so whoever sends them), and end at the file's Nyquist frequency: a corner or notch set
for a finer interval is cut at Nyquist or left out for this file, and the drop-down says
so; the processing never stops for it. A file whose headers give no sample interval
(its time axis counts samples) gets the DC removal alone: the drop-down says that the
pass band and the notches, set in Hz, are not applied to it, and the log says it once
when the record is shown, as it says any reason the filters cannot run once for the file.

**Raw / processed:** the **Raw** toggle beside the button, and `P` while the plot has
the focus, show the traces without the filters, under the same gain, and filtered again;
both are disabled while there is no filter. **The Aux traces** go through the filters
only when "Filter the Aux traces too" is ticked (processSEG passes an auxiliary trace by
otherwise); the gain still leaves them as they are. A plot of auxiliary traces alone
takes its level from them, so a pilot sweep shown alone is drawn. **Filters that reach no
trace shown:** when every trace the plot shows is auxiliary (a pilot sweep file, or Aux
alone) and the box is off, the filters set change nothing on screen, so the funnel is not
lit but drawn in the warning colour, its tooltip says why, and the drop-down says it in
the warning colour under the box ("They reach none of the traces shown: every one is
auxiliary, and "Filter the Aux traces too" is off."); with seismic traces shown too, the
button is lit and both say the auxiliary ones are not filtered. A spectrum window whose
auxiliary traces were left unfiltered so offers **Filter the Aux traces too**, a click
that ticks this box on the plot (untick it here to undo), which the plot and every
spectrum window not frozen then follow. A file of auxiliary traces alone is not filtered
by default: the box stays the one choice, as for any record.

**The cost follows the view.** The panel's reader filters the tile's traces and samples
only (and the margin the filters need around them), on a `ProcessPool` of its own, off
the UI thread; while the layer filters it asks for whole traces, so every later change of
a parameter, of raw or processed, or of the Aux box, is made from the samples it already
holds, with no read of the file (also when the file's drive does not answer). The picture
before stays until the new one is drawn. While a number changes, the reader finishes each
tile it has begun and takes the newest change next (those it never reached are dropped),
each tile it finishes is drawn though a newer change waits, and after the first change
each asks for the view alone (the read-ahead comes back with the next view): so the plot
follows the change instead of waiting for it to stop.
The filters are on the plot's layer: they go with it to the next record and to the next
file by every route, and the settings keep them (not Raw) for a new plot. Measured: see
[Performance targets](#performance-targets).

## New plot

**New plot** opens a window of a plot's traces in one of the signal-analysis views
processSEG offers. It is in two places:

A Vibrator signature, Cross-correlation or Envelope window (against a reference) says
when a trace cannot be matched to the whole of its reference, in a line in the warning
colour above its words (`AnalysisResult.warning`, `core/signalend`), and once in Messages for
the file: "trace is 9 840 ms, the reference is 12 000 ms: the last 2 160 ms of the
reference have no data" when the record is shorter than the reference (the shorter side is
zero-padded), and "signal ends at about 7 600 ms; the reference runs to 12 000 ms" when the
trace is long enough but its signal stops before the reference does. The Vibrator
signature takes the end of the signal from the sweep tracker's fundamental of the force
(`amplitude[0]`) and the reference's from the tracker's `extent`; the other two have
no tracker and look at the trace in 100 ms blocks. The signal ends where it falls to a
tenth of its usual level (the 90th percentile of the levels) and to at least 60 dB below
its loudest block (float ripple left in a wavelet's tail is no signal); blocks after the
last such one that stay above half of that level belong to the signal (a hysteresis, so a
decaying tail does not end at its first dip). The trace's end is compared with where the
reference's own signal ends, found the same way (not with the reference's length: a short
wavelet's copies are not "early"); one that ends within 150 ms or 3 % of it is taken to end
with it. A length is samples times the interval (12 000 samples at 1 ms are 12 000 ms); a range is
given by its first and last sample times. A trace longer than the reference
(a lead-in before the sweep) gets neither line: the correlation's time shift takes the
lead-in up (a delay), but the phase to the reference, measured as if both started together,
does not.

- **Analysis > New plot**, on the traces selected in the Seismic window (greyed out only
  while no file is shown: with no trace selected the window opens and says what to click,
  for example "Click a trace in the Seismic window to show its spectrogram.", and fills in
  as soon as one is selected);
- **the plot's right-click menu > New plot**, on the trace under the pointer, or on the
  selection when that trace is in it.

Each view is a window of its own that docks, titled by what it shows ("Spectrogram 2:
3 traces · FFID 1 · shots.sgy"). Its numbers are worked out off the screen's thread,
from the traces read whole, through the Seismic window's filters (an auxiliary
trace only when "Filter the Aux traces too" is ticked, as in the plot; a trace whose own
filter runs instead of the plot's does not go through them), then each with its own
filter, run after them (named under the title: "Trace 12: own filter, band-pass 10-60
Hz", or "N traces have their own filter"). A reversed trace is multiplied by -1 first,
before its own filter and the plot's filters, and named the same way ("Trace 12:
reversed", or "N traces are reversed"). Reverse-all is that same sign flip, said once ("All traces are reversed");
a trace reversed on its own as well is as recorded, and is not called reversed. No box
turns it off. An f-k's **Raw** leaves the plot's filters
out and still applies each trace's own filter and a reversal. Killed traces and those marked dead are left out (said under the title). A trace sampled at another interval than the first
one's is left out too, and counted "at another interval", as a spectrum window does; a
trace with no sample interval of its own takes its file's, and is left out when it has
none. Unless **Freeze** is on (the pin at the right of the first row of controls), a window
follows the Seismic plot it was opened from, as the Spectrum panel does: the selection in
the record on show, or, with no selection, what that view shows of the record (an envelope
or a phase spectrum: its first trace; an f-k: its seismic traces; a vibrator signature:
its pilot and the next channels). A new record, a sort, a kill or a restore, the plot's
filters, a reversal, reverse-all and another file opened in the plot all work it out again. A file that cannot feed
the view (a vibrator signature of a record with no pilot) leaves the window open and says
so, and a file that can brings the numbers back. Frozen, a window keeps the traces and the
file it had; the title and the line under the controls name that file and those traces
("Frozen · 3 traces · FFID 1 · shots.sgy"). Unfreezing follows at once. A change of its
settings works out from the traces it is frozen on.

| View | Of | Shows | processSEG |
|---|---|---|---|
| **Spectrogram** | the traces (several: their power average) | amplitude against time and frequency, in dB from the largest, in a density colour map, with its scale | `averageSpectrogramInto` |
| **Envelope and instantaneous phase** | the first trace | the trace and its envelope; its instantaneous phase (°), or with a chosen reference the phase against it (trace minus reference, -180 to 180); its instantaneous frequency (Hz), with the reference's dim | `analyticInto`, `wrapDeg` |
| **Phase spectrum** | the first trace | amplitude (dB) and phase against frequency | `amplitudeInto` |
| **Cross-correlation** | each trace (up to 8) against a reference | the correlation coefficient and its envelope against lag; the amplitude ratio (dB) and phase difference (°) per frequency | `crossCorrelateInto`, `compareInto` |
| **Vibrator signature** | a vibrator unit: its reference (Ref), ground force (GF), reaction-mass (M) and baseplate (B) traces | against sweep time, for the ground force judged: its phase to the reference; its force (fundamental and peak, in % of the 100 % force when that is set); the frequency (Ref's and the ground force's); the distortion (THD, %); the stretches past a peak limit in the error colour; with Details also the other ground force, M, B, the recorded pilot, the harmonics and a table per signal | `analyzeVibrators` |

A Vibrator signature window on a vibrator controller's `.dat` or `.vib` signature file keeps the
file's own channel layout: its roles come from the trace codes (Ref 21, M 18, B 19, GF 20: traces
1 to 4 of either kind, so the pickers are read-only and "from the controller's channels"), and no
typed mass is applied, because trace 4 is the ground force already (a `.dat`: the sum of the
controller's two force channels; a `.vib`: computed from set B's accelerations and the weights in
the file's header, in pound-counts). The note under the plots says so. The units are counts.
| **f-k** | a box of traces × time (opened on fewer than 4 traces: the seismic traces of the first one's record; of more than 256, the first 256, side by side) | amplitude against wavenumber and frequency, in dB from the largest, in a density colour map, with its scale | `fkAmplitudeInto` |
| **Node orientation** | the traces the Seismic plot shows, in its order, whatever is selected (a component filter is respected) | the node's roll, pitch and azimuth (°) from each trace's orientation header (SEG-D Rev 3), one point per trace as shown: a step or drift is the node moving; a trace without the header is a gap, and traces none of which has one say "These traces carry no orientation header." (SEG-Y always); no samples are read | `traceOrientation` (parseSEG) |

Auxiliary traces go through the filters only when "Filter the Aux traces too" is ticked: when
it is not, the window says how many the filters passed by (under the title, "the auxiliary trace is
not filtered: Filters > Filter the Aux traces too is off"), as the spectrum windows do, and `state`'s `passedBy` counts them. Against a reference (Cross-correlation, an Envelope's phase against the reference, Vibrator
signature) neither side is filtered: the raw trace is compared with the raw reference, whatever
the plot's filters and a trace's own filter are, and the window's note says so ("the plot's and
the traces' own filters are not applied here: raw trace against the raw reference") when the plot
or a trace has a filter. Its "filters:" chip is not shown there, and a trace's own-filter line
says "(not applied here)"; an Envelope whose reference is named but unusable is filtered, and
shows its chip. A polarity reversal is still applied (to the
trace, and to a pilot reference that is reversed). An Envelope with no reference (its own phase)
is filtered as ever.

One reader thread works out every window's numbers in turn, and a long computation (an f-k,
a spectrogram, a correlation) is given up between its steps, within about 100 ms, when its
window is closed or asks again (a new setting, a new filter), or its file is closed. A
cross-correlation draws 8 traces: of more, only those 8 are read, and the window says how
many were not (`notDrawn` in `state`).

Each window's first line holds its view's settings, the colour map last among them
where the view has one, and Raw (an f-k) after the colour map. Freeze is the pin at the
right of that line's first row. A change works it out again.

- **Spectrogram:** the frame's length (ms; a Hann window: a frame of W ms resolves about
  2/W kHz; 128 ms at first), the frames' overlap (%, 75 at first), the floor (the lowest
  dB drawn, -60 at first) and the colour map (density's maps; viridis at first). Each
  frame is placed at its centre's time. Each trace's mean is removed first, so a direct
  current offset is not the brightest row.
- **Phase spectrum:** the phase is drawn **only where the amplitude is within N dB of its
  peak** (20 dB at first): elsewhere it is noise, a gap, and the unwrap starts again on
  the far side from the last drawn value. The picture is **Unwrapped** at first.
  Also offered: **Magnitude 0-180**
  (the absolute value of the wrapped phase, axis fixed 0 to 180). **Signed +-180** is
  the wrapped phase, with the same gaps. **Unwrapped** joins it along frequency, so a
  delay is a straight line (`-360·f·τ` degrees) and the axis may be large. **Delay
  removed** takes that line's best straight fit off (a pure time delay; the readout
  says it in ms), which leaves a linear sweep as a parabola. The cursor reads the phase
  as drawn and, unless the picture is signed, the signed value in brackets. A sweep's
  phase climbs steeply because its delay grows with frequency; for vibrator QC, read
  the phase against the pilot in the vibrator signature plot. The phase is from the
  trace's first sample, of the whole trace, **its mean removed first** (as an FFT
  window does; the note under the title says "mean removed"), untapered,
  **zero-padded to 4 times its length**: between bins the phase of energy
  arriving at time t steps 360°·t/(4T), at most a quarter turn for any t within the
  trace (length T), so the unwrap cannot alias. Unpadded, a step passes half a turn once
  t is past T/2, and a sweep's phase (which falls all the way) turned and rose there.
  A trace with a sample that is not a number is left out and counted in the window's line of
  words ("1 left out (killed, dead or unreadable; 1 with a sample that is not a number)"),
  as the FFT window does, not drawn as 0; so are such traces of a spectrogram and an f-k.
- **Cross-correlation:** the reference is the one chosen in Analysis > References,
  and only that. The bar says "Reference: <name>" and **References** opens that window.
  Nothing else chooses a reference from here. With none chosen, the plot area says
  "No reference is chosen. Choose one in References." With the chosen one gone,
  or a sample interval that is not the traces', the plot area says which in one sentence
  and does not draw; the same button is there. A shorter reference is zero-padded and a
  longer one is not cut, as a file's own pilot is. Its samples are used as stored: the
  plot's filters and a trace's own filter do not apply to them. Changing the choice
  redraws every open correlation that is not frozen; a frozen one keeps what it showed,
  including when the file is opened again.
  The first graph says how well each trace matches the reference, by time shift (the
  correlation divided by the square root of the product of the two energies: 1 for the
  reference's shape whatever its amplitude, -1 for its mirror image). A trace delayed by
  τ from the reference peaks at +τ. Under the title, one line per trace says its best
  match, its shift and which way ("arrives 2.0 ms after the reference", "before", "in
  step"), and a table of the several traces adds the mean amplitude ratio, the mean
  phase difference and the rotation.
  The **match** is the correlation envelope's peak: the shape's match whatever the constant
  phase turn of the trace. The **shift** is that peak's place, found between samples (a
  parabola through the peak and its two neighbours), so a delay of 3 ms at 2 ms sampling
  reads +3.0. The **rotation** is the phase of the correlation at the peak: "rotated 90°" for
  a trace that is the reference's Hilbert transform; nothing is said within 10° of 0, and
  "reversed polarity" within 30° of 180°. A peak is clear at 0.3, or lower when it stands at least 4.5 times above
  the envelope's RMS beyond ±20 ms of it (a noisy sweep: the shift is good though the
  coefficient is small; checked when at least 40 ms of lags lie there). A clear match under
  0.7 whose ratio is under 20, or one clear by the ratio alone, says its shift to the whole
  millisecond ("at about +4 ms", "about +4" in the table). Any other peak is "no clear match
  (0.06)", with no shift, direction or rotation (checked before the next); a clear peak at the
  first or last lag shown is "no peak within ±250.0 ms: widen the time shifts" ("-" in the
  table), and its trace has no phase per frequency. A trace arriving by its found shift is
  not warned that its signal ends early. `state`'s `peakLagMs` is the shift as the window
  says it (null for no clear match or no peak, with `verdicts` saying which). The note says the time shifts really shown (the box's value rounded to whole
  samples). The amplitude ratio and the phase per frequency are measured after the found
  shift is removed ("phase after removing the time shift"; a trace with no clear match or no
  peak is not shifted), so a delay is not read as a phase error. The Compare window words the
  same pair the same way ("best match 1.00 at +4.0 ms (B lags A by 4.0 ms; rotated 90°)"),
  and under it the largest correlation magnitude, which "Shift B by the correlation peak"
  does not use: it moves B by the match's shift. A positive shift moves B earlier; the chip
  says "(earlier)" or "(later)". A trace that is the reference itself is said so ("it matches exactly
  (1.00 at 0 ms)") and is not drawn among others. The amplitude ratio and the phase
  difference are given where the reference's amplitude is within the same N dB (20) of
  its peak. The time shifts shown: ±250 ms at first.
- **f-k:** the box's times (**From**, **to**, ms; empty: the traces' ends), the floor and
  the colour map as a spectrogram's, and **Raw** (off at first: through the Seismic
  window's filters, so the effect of a filter shows; on: the plot's filters left out.
  A trace's own filter is applied either way). The box is
  tapered (a cosine over 10 % at each end) along time and across the traces, which are
  zero-padded to twice their number; each trace's mean over the box is removed first. A
  trace with a sample that is not a number is left out, and the note says so: the traces
  that remain are taken as they are, so when that makes their spacing irregular the rule
  for irregular offsets applies (wavenumber per trace). The wavenumber is worked out from the trace spacing
  when it is regular (the signed offsets, else the receivers' distances along the line) and
  the unit of the file's distances (the unit confirmed with its import, else what its
  headers say: the measurement system, the coordinate unit, the CRS). Trace offsets are
  in the measurement system (not the coordinates' unit); the receivers' distances are in
  the coordinate unit. **In metres** the axis
  is in cycles/km and the apparent velocity in m/s. **In feet** (international or US survey:
  the foot of the file itself) the axis is in cycles/kft (per 1000 ft) and the velocity in
  ft/s, as a US crew reads them; the note under the title names the unit. The velocity
  follows the file's units when they are known, not Tools > Settings > Units; the readout's
  tooltip says which. When the file names no length the velocity is in traces/s, and the
  tooltip says the Units setting does not apply: there is no length to convert. When the spacing is
  not regular, or the unit is an angle (arc seconds, degrees) or not given, the wavenumber is
  in **cycles per trace** (velocity in traces/s), and the note says why; the axis always
  names its unit. An event arriving later on the later traces is at a positive wavenumber.
  The cursor reads the wavenumber, the frequency, the dB and the apparent velocity f/k; the
  keys step it a wavenumber (Left / Right) or a frequency (Up / Down), as a spectrogram's.
- **Vibrator signature** (wireline tests, start-up QC of a vibrator):
  - **Roles.** A table gives each role its trace among the window's: by default the
    order Ref, GF, M, B. Opened on one trace (the pilot), the window takes it and the
    record's next three channels, as wireline records have them; on several, the first
    four are the roles and the others can be chosen (16 at most). A role can be "none";
    Ref cannot. When the window's traces carry the SEG-Y vibrator trace identification
    codes (21 reference, 20 estimated ground force, 18 reaction mass, 19 baseplate), the
    roles are taken from the codes instead, whatever order the traces are in, and the
    note says "roles taken from the trace identification codes". A role you change is a
    choice by hand and stays for that file; on another file with the codes they decide
    again (the Messages say so), and a file without them keeps the roles as they were.
    The agent state's `roles.source` says which: `window order`, `trace identification
    codes`, `chosen by hand` or `remembered for this file layout`. The codes are not
    always right (two converters put the mass and the baseplate in the other order), so
    a line above the table says who is who ("Ref trace 1 · GF trace 4 · M trace 3 · B
    trace 2 — from the trace identification codes"; its tooltip has the codes' words),
    **Swap mass and baseplate** (beside B) puts them right in one click and **Roles from
    the codes** (beside Ref) goes back. A hand choice is remembered per **file layout**
    (the record's trace count and its code sequence): in the project when one is open
    (`vibRole` entries in `project.nif`), else in the user settings, and every later
    file of that layout opens with it; another layout is not affected. Opened on the
    pilot of a record that has the vibrator codes, the window takes every trace of the
    record (16 at most), and each role's list shows "trace 7 · code 30 (not in the
    standard)", so any trace can be picked for any role (the codes outside the standard
    have no meaning here).
  - **Which reference.** When the project has a reference chosen (References), Ref's list
    offers **Project reference: name** first, and it is the default: the phase, frequency
    and force are measured against what the unit was meant to sweep. The recorded R trace
    (what it says it swept) is then measured against it too, as **Ref (recorded)**: a row
    of the table and a line in the phase and frequency plots. Picking a trace for Ref
    measures against that trace instead; with no reference chosen the trace is used as
    well. The window says which in one sentence under the settings ("Measured against the
    project reference ..." or "Measured against the recorded reference, trace N"); the
    choice is kept with the plot's options and put back by Reset options.
  - **This file's reference trace.** Ref's list offers it when a trace of the window has
    the vibrator reference code (21): that trace as Ref, measured against by itself, not
    against the project reference. In a cross-correlation and an envelope (its phase
    against the reference) the button **Use this file's reference trace** takes the
    record's code-21 trace, whole, as the reference instead of the project's, with
    nothing stored in the archive; the same button goes back. It is never chosen for you:
    with no project reference a correlation says so and offers the button. The choice is
    the window's, not an option remembered for new windows.
  - **Polarity.** GF as recorded, reversed, or **automatic** (reversed when its mean
    phase to the reference is past ±90°: wiring). M and B take one polarity, together
    (the baseplate moves against the mass: one reversed alone would make their force a
    difference); automatic needs both and both masses. Ref is the phase origin.
    A polarity chosen by hand is remembered with the roles for the file layout (in the
    project when one is open, else in the user settings), so a later file of that layout
    opens with it, also after a restart; a choice made by an agent is for the session only.
    The other boxes (masses, harmonics, the six limits, the window, **100 % force =**, the
    target, **Details**) are plot options kept in the user
    settings; the top frequency is kept with its reference in the project as well, so it
    travels with it. Point limits stored by an older version (`limitsOn`, `limits`) are read
    and ignored.
  - **GF from M and B.** With the reaction mass and the baseplate's mass entered (kg, or
    lb when Tools > Settings > Units is Imperial; **kg | lb** after the two boxes is that
    setting, the selected one drawn lit, and the numbers convert in place, pounds to a
    tenth: 3600 kg reads 7936.6 lb, and what is stored stays in kilograms; empty at first, as no default fits
    every vibrator), `GF (M, B) = Mr·M + Mb·B` is a second ground force, and the **Ground
    force judged** choice at the top (beside the verdict, never folded away) says which of
    the two the window uses: that one is "GF" in every plot, in the verdict and in the limits
    table. With **Details** on, the plots tell them apart ("GF as recorded", "GF from M and
    B"), each force on **a plot of its own** (the one from M and B in kg × recorded units,
    or lb × when Units is Imperial; the stored numbers stay in kilograms): the recorded
    force (counts) and the weighted sum are not in one unit, so neither shares the other's
    axis. Without accelerometer sensitivities it is uncalibrated, and the window says so.
  - **Harmonics** tracked to the 5th at first (2 to 16): the highest harmonic the
    distortion plot draws one line for (with Details). Distortion itself is the **in-band** one (below).
  - **The verdict.** One line at the top of the window says PASS, FAIL or NOT JUDGED, in
    words and a sign (a tick or a cross), never by colour alone; a FAIL names the worst
    failing value (the one furthest past its limit, in proportion) and the time of its
    window ("FAIL: peak force 157 % > 120 % at 9.5 s (and 1 more)"). Under the settings an
    always-visible **limits table** has a row per limit: what was measured, the limit, a
    tick (✓), a cross (✗) or a dash (not judged), and where the worst window is or why the
    limit was not judged. It is judged as a vibrator controller's QC does: the mean of each
    window of the sweep (500 ms, typed in the **window** box), then the average and the worst
    window against six limits, on the sweep less its tapers (dimmed on the plots). Defaults:
    average phase at most 5°, peak phase at most 10°, average distortion 30 %, peak distortion
    60 %, average force at least 90 % and peak force at most 120 % of the force that is 100 %.
    The limits, and the length of the windows, are in the **Limits...** popup; an empty box
    turns that limit off. These six are the only limits: the point-by-point limits of older
    versions are gone. The force limits need the **100 % force =** box (the force, in the
    file's unit, that counts as 100 %): with it empty the table says which box to fill
    and the other four limits still give the verdict. A trace shorter than its reference
    is judged to its own end (the note says so).
  - **Target force and which GF.** The average force limit is a percent of the *target*
    (the **Target force (%)** box, 100 at first: the drive level the sweep was set to, a
    percent of the 100 % force); the minimum shown is in the same percent; the peak force
    limit is a percent of the 100 % force itself (the table says "of target" and "of
    100 %"). With both ground forces the **Ground force judged** choice (GF as recorded, or
    GF from M and B with the masses typed) says which the window uses (plots, verdict and
    table); it is named in the verdict line, remembered with the roles and the polarity for the file layout (project, else
    settings; an agent's change is for the session) and in the agent state (`judged`,
    `bothSignals`, `judgeWarning`, `roles.judge`). The recorded GF is the weighted sum the
    recorder wrote with its own masses; the other is the same sum formed here. When the
    recorded one does not match (the level ratio between the two varies by more than 3 dB
    along the sweep, or their phases differ by more than 10 degrees in some window) the
    default stays and one line says so. Each signal has its own **100 % force =** value (the
    recorded GF is in counts, GF from M and B in kg x counts); the box shows that of the
    signal judged. The peak force of GF from M and B can read lower than the vibrator's own
    peak force figure (about 5 % lower at the median on the files reviewed).
  - **What the plots show of the verdict.** The judged ground force alone (Details adds the
    rest). **Phase**: its phase to the reference, the axis fitted to the curve as drawn (its
    maximum is never clipped, also signed around a half turn), with Absolute phase the
    floor a little under 0 so a line at 0 degrees is visible. **Force**: its fundamental
    and peak, in % of the 100 % force ("Force (%)") when that is set, else as recorded.
    **Frequency**: Ref and the ground force. **Distortion**: its THD. The pieces of the
    sweep (the QC windows) whose mean phase or distortion, or whose peak force, is past the
    *peak* limit are drawn over the curve in the error colour; no limit lines, no window
    means. A plot of one curve has no legend, a plot of two a small one inside its top
    right corner, so the four plots share one left and one right edge. Each plot fits its
    own axes to what it shows, again whenever another record or file is shown or a setting
    changes the curve, unless that axis was zoomed by hand.
  - **In-band distortion.** The **Top frequency (Hz)** box is the sweep's top: THD sums
    the harmonics, from the 2nd, whose frequency stays within it, as the controller's
    distortion does, and is 0 where none is in band (the reference above half the top).
    It is filled in from the project reference, with nothing typed ("(from the reference)"
    beside the box): exactly from a generated reference's end frequency, else read from the
    recorded reference's samples: the sweep's frequency law, fitted to its frequency track over
    the last part of the flat part (a line or a parabola, in f or in ln f, whichever fits
    better, so a sweep with a boost in dB per octave is followed), taken to where the sweep
    ends (the start of a sweep that falls). The end is found from the fall of the end taper's
    envelope (the analytic envelope, the noise in it estimated from its own scatter over the
    flat part and taken off): the fall, down to 3 % of the amplitude or the noise's reach, is
    tried against a few shapes (powers of the time left, and the cosine squared) and the data
    weigh them, so no taper shape is assumed; the fall ends where it stops steepening, so a
    ring-down or leakage after the taper (a gentle slope) does not lengthen the sweep, and a
    sweep with no taper, or one that ends on a step, ends where its envelope does. The reading
    is rounded to a whole hertz when within 0.5 % of one (6-220 Hz reads 220, not 220.4); the
    same for every record. Its uncertainty is three standard errors (the error lay within it in 77 to 100 % of the families of synthetic sweeps tried): the law's error at the
    end, and the end's, from the fit of the fall, the shapes that fit it about as well, the
    stretch it is extended over and the envelope's blur, times the sweep's rate. When it
    exceeds 0.6 % of the frequency the band's warning says "uncertain", with the uncertainty
    in hertz, and `analysis.band.uncertain` is set: the number is then the reading, no surer
    than that. Most clean sweeps are marked when their end taper is long and the sweep fast;
    a reading that the sweep's frequency, Nyquist or its own uncertainty (above 5 %) makes
    absurd is not used: the band follows the median of the estimates that fit (the reading, the line through the
    frequency track and the library's own estimate, those below Nyquist and not below the
    largest frequency the reference shows) and the warning says so; the same when the
    reading is uncertain by more than 3 %.
    A typed value is kept with that reference in the
    project. A line warns when it is below the largest frequency measured in the flat part of the
    reference by more than 0.5 %, or above it by more than the sweep's rate over its end
    taper and half a chord, with 25 % and 1 % to spare (the chord reads a little under the
    top). A top typed for a recorded reference is kept per file layout; one kept before
    that is dropped. The distortion plots, the table's THD
    columns and the verdict all use it. A harmonic above 80 % of Nyquist is never measured.
  - **The stored reference's place.** When the unit has a recorded reference trace, a
    stored reference is aligned to it by cross-correlation and the note says the shift
    found ("stored reference aligned to the recorded reference: +115 ms"). With no
    recorded reference, the stored reference's own start time (its From) is honoured and
    the note says the two are taken to share the record's first sample. Against a
    reference nothing is filtered: the raw trace is measured against the raw reference
    whatever the plot's filters are, and the note says so.
  - **Fitting.** At its default size one unit shows its verdict, its limits table and its
    four plots with nothing to scroll; the settings are behind a strip of icon buttons (Roles,
    Limits..., Details, the settings wheel, Freeze), the note under one line. The plots share
    one time axis, labelled on the last. Stepping to the next record keeps the window's size
    and place and only updates it.
  - **Set from this sweep** (beside **100 % force =**) sets the judged signal's 100 % force to
    this record's average force divided by the target's share (the verdict's average force,
    in the stored unit, over Target force / 100): for a sweep where the vibrator held its
    target. It is a hand change, kept like a typed value (per signal judged), also after a
    restart.
  - **Limits...** opens the six pass or fail limits (always applied) and the **QC window**
    (500 ms): the sweep is cut into pieces of that length and each limit is checked on the
    average inside a piece; average = mean of all pieces, peak = the worst piece.
    **Details** adds, under the verdict's table, each signal's statistics (mean and
    maximum phase, THD, mean and minimum force, maximum peak, in the same unit as that
    signal's axis; the column names the unit when every row shares it, and a row in another
    unit names its own); M and B are summarised, not judged.
  - The values are as recorded (no calibration yet): the force in the recorded units,
    or a weighted sum of M and B's recorded values.
  - All the plots share sweep time, so the held cursor reads them at the same time.
- The **envelope** is the analytic signal's modulus; the instantaneous phase its
  argument; the instantaneous frequency the phase's step between the samples either
  side, in Hz. Where the envelope is 60 dB or more below its peak the phase is noise,
  so no frequency is drawn there (and the window's words say so).

**Drawing an image.** An image view (a spectrogram, an f-k) draws what is in view cut down
to about the plot's pixels (at most 300 000 cells): each drawn cell is the largest value of
the image's cells it stands for, so a strong event is never averaged away. It is redone only
when the answer, the view or the window's size changes, and the cursor reads the exact cell
of the whole image. A long f-k (256 traces over 60 s) therefore costs no more to show than a
short one.

**The cursor.** In a spectrogram the cursor follows the pointer, a line to each axis with
its exact value written on the axis, and the line under the image reads its time,
frequency and dB. While the window has the focus (a click on it), the keys hold it:
**Left / Right** a frame, **Up / Down** a frequency bin, **Home / End** the first or last
frame; **Esc**, or moving the pointer over the image, lets it go. The curve views take
the spectrum windows' cursor: the nearest point of the curve under the pointer, lines to
both axes with the exact values on them; the keys hold it in the plot last pointed at
(**Left / Right** a sample, **Home / End** the ends, **Up / Down** another curve), at
the same x in the plots that share its axis, the reading then marked "Held".

Agent control: `open plot`, `plot display`, `plot cursor` and `close plot`
(docs/agent-control.md); `state`'s `plots` gives each window and its numbers;
`screenshot` takes `new plot N`; when another analysis window is in front of it and hides
part of it, the shot is refused (naming that window) and the window is brought forward, so
that asking again gets it whole.

## Mouse and keys

**One gesture, one action.** Each row is one input; no input appears twice for the same
window. Keys act on the focused window (the plot, the map or the file list); a key
while the pointer is over the plot acts on the plot, so a menu click that left the
focus elsewhere does not swallow it. The
application keys work everywhere. **The click that brings a window forward does only
that** (the user: "should be only when window i already active"): a click selects a
trace, shows a file or shows a record only in a window that had the focus already; the
first click in another window gives it the focus and nothing else. Every action is also in a menu or on a control, with
its shortcut shown there.

### The plot

| Input | Action |
|---|---|
| Move the mouse | **Hover:** the trace under the cursor is drawn in the hover colour, its source and receiver light up on the map (see [Linking the plot and the map](#linking-the-plot-and-the-map)), and the status bar reads it out; where the trace has no place on the map, the status bar says why |
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
| Ctrl + wheel | Zoom up and down only, about the cursor: in time (in traces when time is across) |
| Shift + wheel, or the sideways wheel | Zoom across only, about the cursor: in traces (in time when time is across; some systems send Shift + wheel as the sideways wheel) |
| `+` / `-` (main keys or keypad) | Zoom in or out about the cursor (or the centre), both axes |
| Ctrl + Up / Ctrl + Down | Zoom in / out up and down only: in time (in traces when time is across) |
| Ctrl + Right / Ctrl + Left | Zoom in / out across only: in traces (in time when time is across) |
| Arrow keys | Pan the way they point, by a tenth of the view; with Shift, by a whole view |
| Ctrl + `0` | Fit all (also a button in the controls) |
| `]` or keypad `*` / `[` or keypad `/` | More / less gain amount, 3 dB a step; with Shift, 12 dB |
| Backspace | Back to the previous view |
| Alt + Right / Alt + Left | Select the next / previous trace of the record (Alt + Down / Alt + Up when time is across); the plot scrolls to keep it in view |
| Page Down / Page Up | Next / previous gather |
| Home / End | First / last gather |
| Ctrl + G | Go to a record number |
| `P` | Raw ↔ processed: the traces without the filters, under the same gain, or filtered (not Space: with keyboard navigation on, Space presses the control that has the keyboard's focus, such as the strip button clicked last) |
| `K` | Kill or restore the hovered trace (or the selection, when it holds that trace) |
| `R` | Reverse the polarity of the hovered trace, or put it back (or the selection, when it holds that trace) |
| `F` | Amplitude spectrum (FFT) of the hovered trace (or the selection) in a new window |
| `H` | Show the trace's headers |
| `M` | Select the trace's station on the map, with the station's traces: its receiver (in a receiver gather, its source); over a selected trace, those of the selection |
| Ctrl + Z, Ctrl + Shift + Z or Ctrl + Y | Undo, redo the edits of the file shown: the Edit menu's, from any window ([Everywhere](#everywhere)) |
| Esc | Cancel, innermost first: the drag in progress, else the ruler, else the selection |

### The map

The map uses the same gestures wherever the meaning carries over, always at equal aspect
([The map window](#the-map-window) says how it looks).

| Input | Action |
|---|---|
| Move the mouse | **Hover:** the point under the cursor (within 7 pixels) is drawn in the hover colour and described: source or receiver, line and point, coordinates and elevation with their units, its file, the traces of the open files recorded there and their records, and for a survey file's source the field records the loaded relation file gives it; in a box beside the pointer or in a strip along the map's bottom, as the map's settings say. Points of other layers on the same spot (an SPS receiver and the open file's own) are described together. **The traces recorded there are drawn in the hover colour in the plot** (a receiver's trace; a source's whole record); where none is in the record shown, or none was recorded there, the status bar says why. The status bar shows the cursor's coordinates with their units |
| Left click on a source | **Show its record** in the plot (in a file of receiver gathers it is the other way round: a click on a receiver shows its gather); a survey file's source no trace of the open files was recorded at, whose record a file of the folder listed holds (it is ringed), **shows that file** at its record; any other is selected |
| Left click on any other point | **Select** it and its traces (replaces the selection) |
| Ctrl + left click | Add the point (and its traces) to the selection, or take it out |
| Shift + left click | **Select a range:** the stations of the line from the point clicked last to this one (of the same file and role), and their traces, in place of the selection; the point clicked last stays where the next range starts |
| Left drag | **Pan** |
| Shift + left drag | **Box select:** every point of a shown layer in the box, and their traces (replaces the selection; with Ctrl too, adds to it) |
| Ruler, then left drag | **Measure**, as Ctrl + left drag does. The button stays on until clicked again; clicking it while it is on takes the line away. A click without a drag still selects. Panning stays on the middle button and the arrow keys |
| Ctrl + left drag | **Measure:** a line from press to release, its length and grid bearing beside it, and the Ruler turns on (the button lights), until Esc or until the button is clicked off |
| Right drag | **Box zoom:** as close as shows the whole box, at equal aspect |
| Right click | **The menu of the point under the cursor:** show its record (a source with traces), select it and its traces, add it to the selection or take it out, hide its layer; over no point, "No point here". Layers and fit are in the strip |
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
| F1 | Help > Keyboard shortcuts: the list of keys and mouse gestures (docs/user/keyboard-shortcuts.md) |
| Ctrl + Z | Edit > Undo: take back the last change to the edits of the file the Seismic window shows (a kill, a restore, a polarity change, reverse all, a clearing, an import), whichever window has the focus; a text field keeps its own Ctrl + Z |
| Ctrl + Shift + Z, Ctrl + Y | Edit > Redo: make the change undone last again |
| Drop files or a folder on the window | A folder: list it and show its first file; one file: show it and list its folder; several files: list them and show the first |
| Up / Down (file list focused) | Step to the next / previous file and show it in the same plot, keeping the display settings and the scales (wherever the focus is in the window, but in the filter box) |
| Tab / Shift + Tab | Move between the controls of the window that has the focus, as in every window (the user: "tab should move between options in the window not files"): in the file list the folder's drop-down, its buttons, the filter, "Follow the latest file" and the list (one stop, at the file shown); Space or Enter acts on the control reached |
| Page Down / Page Up, Home / End (file list focused) | Ten files on / back; the first / last file |
| Click a file in the file list (focused) | Show it in the plot, in place of the one shown |
| Up / Down, Page Up / Page Down, Home / End (record list focused) | The next / previous record, a page on / back, the first / last record, in the order the list shows (a click on a column's header sorts it), shown in the plot |
| Click a record in the record list (focused) | Show it in the plot |

### Explain, by right-click

Every plot has "Explain" in its right-click menu, last, after a separator: the Seismic
plot, the map, each plot of an FFT window, of the Spectrum panel, of every New plot window
(one per plot of a window that stacks several), of Compare, of a reference's window, of the
Generate dialog, and the Headers window's graph. A plot with no menu of its own gets one
with that entry; a right click that does not drag opens it (a right drag is ImPlot's zoom
box and stays so). Choosing it opens a popover at the pointer, closed by Esc or a click
elsewhere: what the plot shows (each axis with its unit, what a curve or a colour means),
what it is computed from (which traces and window, and which of the filters, the reversal,
the time shift and the reference are applied now, and the Units setting), how to read it
and, where it is true, what can mislead. The words are one module's, `core/explain` (a text
from the kind of plot and its current settings, no toolkit types); `state` gives the same as
`explain` for the New plot and spectrum windows, [What each plot tells
you](user/plots.md) is generated from them (`nim plots`), and `tests/texplain.nim` fails for
a plot kind without words and for a page that has drifted. Help > Keyboard shortcuts says
"Right-click any plot: Explain".

### A right-click menu holds what it acts on

While a right-click menu is open, what was under the pointer at the right click stays
highlighted and its read-outs stay as they were then, wherever the pointer goes over the
menu (the user: "when i right click i want the highlighting and the values for x,y axis
just as if i was not in the right click menu");
when the menu closes, chosen or dismissed, the highlight follows the pointer again. A
right click elsewhere in the window while the menu is open opens it there, for what is
under the pointer then, as desktop programs do.

| Window | Held while its menu is open |
|---|---|
| Seismic plot | The trace right-clicked stays the hover (drawn in the hover colour, its source and receiver lit up on the map); the status bar's read-out, the cursor's time line and the header values over its rows are those of the right click |
| Map | The point right-clicked stays the hover (drawn in the hover colour, its traces lit up in the plot); its description (station, coordinates with units, file, traces, records) stays, in the popup beside the menu (not under it) or in the strip, and the status bar keeps the coordinates of the right click |
| Headers (Summary, the header tables, Trace > Data) | The line or value right-clicked stays highlighted |
| Messages | The line right-clicked stays highlighted |
| Files, Records, FFT windows, Spectrum | No right-click menu (a right drag in a spectrum zooms to a box) |

## The map window

```
┌ Map ──────────────────────────────────────┐
│ [Layers] [-][+][fit][<] [ruler] [⚙]       │  controls (they wrap when narrow)
├───────────────────────────────────────────┤
│ ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·     ▲     │  survey coordinates, north up,
│   •     •        •                N       │  equal aspect; no axis values
│ ·  ·  ◉  ·  ·  ·  ·  ·  ·  ·  ·           │  · receivers   • sources
│   ┌───────────────────────┐               │  ◯ the open file's own positions
│   │ Receiver, line 104, … │               │  the point under the pointer
│   └───────────────────────┘               │
│ 2000 ftUS                                 │  scale bar
└───────────────────────────────────────────┘
```

- **Named "Map"**, with an identity of its own (Dear ImGui's `###map`) that layouts keep.
  At a first start it stands right of the plot, over the Headers window; a layout saved
  before the map existed names no map, and the map then joins the Headers window's place.
  The presets place it too, and **Plot and map** puts the plot and the map side by side.
- **Layers:** each loaded survey file's sources and receivers, as filled discs, sources
  over receivers; each open file's own sources and receivers (its trace headers'
  coordinates), as rings, so where the headers and the survey files agree each disc sits
  in its ring and where they do not both show; and the **highlight** on top: **the points
  of the record on show**, always (its receivers in a darker shade of the receivers'
  colour, a pixel larger than the receivers around them, so the spread shows as a whole
  and the sources inside it stay visible; its source larger and outlined), then the
  selected points (the selection's colour) and the hovered ones (the hover colour),
  larger and outlined. Each layer can be hidden (**Layers** in the strip, or the right-click menu of
  one of its points). **The Layers list is in groups** (the user: "When a survey can be
  loaded it should display as a preplot layer"): the **Preplot**, the survey files' sources
  and receivers, what the survey planned; the **Recorded**, what the seismic files say of
  themselves, their own positions as the headers give them or as a join made them (named
  "(joined)"); then the highlight. Each group has its tick, which hides all of it (its
  layers keep their own ticks, greyed out meanwhile), and each layer its own; a hidden
  layer is neither drawn, nor found under the pointer or in a box, nor highlighted. The
  groups hidden are kept in the settings (`map.hiddenGroups`); a layer hidden on its own is
  kept while the program runs (with the file's identity across runs: what is remembered
  about a file). **The template box** (under the Preplot, off by default; the user: "a
  bounding box from the template should be able to be drawn"): the box round the receivers
  the relation (X) records plan for the record on show (in the outline colour, "X record 77:
  1127 receivers planned" above it) and for the source under the pointer (in the hover
  colour, its words below it); for a file of receiver gathers (the domain follows the
  record shown), round the shots the O records plan for its receiver, and for the receiver
  under the pointer. The record's X record is the one the filters' check finds (processSEG's
  `recordCompleteness`: the source station's, else the FFID's, as the record match in
  Import survey's options says), checked on a background job from the keys while the box
  is on; for a record whose headers name no station (a SEG-Y file without a header
  layout), the survey file's station at its place is the record's for the check, and the
  box says so ("X record 77 (by the source at its place)"), so the box and the filters
  always name the same record. A source under the pointer shows its station's first X
  record (a source shot again has several). The box's
  sides run along and across the planned stations' lines (the run with most places), a few
  pixels outside them. **Without a relation file**, the spreads are generated from a
  template the user gives in the Layers list (lines × stations centred on the source, or a
  distance box along and across the receiver lines), on a job, through processSEG's
  `generateRelations` over the S and R files, and the box says "Generated"; with X records
  but no O records, a receiver gather's planned shots are made from the X records the same
  way. **The folder's shots** (under the Recorded; the user: "clicking on a shot that
  exists inside the folder of seg files should open that file"): each seismic file the
  Files window lists is read in the background, without being shown, for its records'
  FFID, source station and source coordinates, and matched to the survey files' sources
  (by station; by place when the headers name none; by the FFID through the relation file
  when they give neither); a source whose record a listed file holds is **ringed**, its
  description names the file ("Shot in the folder: shot-14.sgy (FFID 1014)"), and a click
  on it shows that file at that record. **A shot several files hold** (a reshoot, a copy of
  a record): the description names them latest first, a line each ("also in ..."), and a
  click shows the first, **the newest file** (by its modification time; files of one time by name; in one file its last
  record of that shot); the point's right-click menu lists each file, to show another. The Layers list says how many of the survey's
  sources have a file, and how far the reading is. **Filters** (the user: "filters for
  failed traces, missing traces from template, any other relevent items", and "perhaps
  noisy as well, clipped"), under "Filters: the record shown" in the Layers list, each a
  tick with its count and its mark, none on by default: traces dead in the headers, not
  decodable, killed; the amplitude flags of processSEG's `qc/amplitude` with its default
  thresholds (clipped, spiky, constant, DC offset, all zero, not a number) and, for **noisy**,
  **weak**, **louder than its neighbours** and **not judged for noise**, processSEG's
  `qc/exclusion` (`noiseQc`; see **Noisy traces** below);
  missing from the template (the stations the X record plans that the record has no trace
  of: `recordCompleteness`'s `missingStations`), not in the template (its traces at
  stations the X record does not list), recorded twice; auxiliary; without a position;
  reversed; and, survey-wide, **spread not the template**: the shots whose X record agrees
  with the template the X records describe far less than the survey's shots typically do
  (`compareRelations`' Jaccard index under the median less three robust deviations).
  **Marks** (the user: "the map needs more pronounced overlay for filters and they
  shouldnt be lost at max scalling"): a filter's points are marked with a glyph of its own,
  an outline round the station with a halo of the map's background round it, drawn over
  the stations, the lines and the highlight. Its colour says the kind of finding (a role of
  the theme each: `flag_failed` for dead, not decodable, all zero, not a number;
  `flag_amplitude` for noisy, clipped, spiky, constant, weak, DC offset; `flag_edited` for
  killed and reversed; `flag_spread` for missing, not in the template, twice, spread not the
  template), and so does its outline, so the kind reads without the colour (failed traces a
  square, amplitude flags a circle, edits a diamond, the spread a triangle: no two kinds
  share a shape, for a viewer who cannot tell two of the colours apart); a symbol inside
  says the filter within the kind (none, an X, a plus, a bar, an upright bar or a ring):
  dead a plain square, noisy a plain circle, missing from the template a plain triangle,
  reversed a plain diamond, killed an X in a diamond (the rest: `core/mapkinds`'
  `FilterMarks`, no two alike; `tthemes` checks that every two are told apart without
  colour, as a protanope, deuteranope or tritanope sees them, in every theme). The colours meet the themes' rules: 3
  against the map's background and 20 (deltaE) from the sources, the receivers, the
  record's receivers, the hovered and selected points, and from each other. A mark keeps
  its size on the screen at every zoom (26, 22, 30 and 18 pixels across at 100 % for the
  four kinds, so marks of two kinds on one station nest), and every marked point is drawn
  however far out the map is (none thinned, unlike the stations), one glyph a place
  however many things a filter marks there (a station with 5 000 dead traces is one mark,
  where it was 5 000 or more, each drawn twice with its halo; with the 63 traces of a shot
  killed, each marked at its file's own position and its survey station's, 61 glyphs go to
  the GPU where 124 did); where marks fall on one
  another, the point under the pointer says how many of each lie under it ("Marked here: 1
  dead in the headers, 3 noisy, 2 missing from the template"; `view/maplayers`' `markSpots`
  merges a filter's marks by place, each thing once, in a grid, and `markedHere` looks only
  at the grid's cells within reach and counts again only when the marks under the pointer
  change: 0.007 ms a frame over a station of 20 000 marked traces with a million marked
  places elsewhere, a debug build, where looking at every mark and counting through a list
  took 335 ms a frame, optimised). In the Layers list each
  filter shows its mark as the map draws it, and its tooltip names the shape and the kind;
  Select selects its traces in the plot; the point under the pointer says which filters
  mark it ("Marked: noisy"). **Noisy traces** (the user: automatic with an override, a station
  count that "should not jump to a new line in record", on receiver gathers too, never
  across unrotated components): `core/recordqc` runs `noiseQc` on the record's traces
  with the area `Settings.noise` (`core/noisearea`) chooses, on one pick and one
  `fitShot` result that the first-break overlay shares (`FirstBreaks.picks`, `.fit`: the
  job that gets there first posts them, the other takes them; a record is picked once,
  off the UI thread). The area is the library's automatic chain (the refraction model,
  else a radius from the offsets, the survey's or the headers', else a number of
  stations, default 8, else none), or the user's fixed time, radius or station count
  (Tools > Settings, saved in the settings file as `(noise ...)`; the experimental
  first-break trend is not offered), counted on every line or only the lines the shot
  reaches. Weak is judged everywhere against the traces outside the area; noisy only
  outside it; **louder than its neighbours** is its own filter (a station against the
  median of those beside it on its line); **not judged for noise** counts the traces
  inside the area and those with the sensor or station unknown (`NoiseSummary`,
  `RecordQc.noise`: said in the Layers list as `areaWords`, `notesWords`,
  `notJudgedWords`, and in the agent's `state` `noise`). The Seismic window draws the
  traces inside the area as a quiet grey band behind them (`view/areabands`, "plot.noise
  area N"), following the plot's order, while a noise filter is on. Unrotated node
  geophones are never compared across nodes: the library judges a node on the summed energy of
  its motion traces and the hydrophone as a group of its own, and the viewer has no
  control for it. The record is read on a background job when one of the filters that need it is
  on and the record shown changes (a chunk of 512 traces at a time); the rest come from the
  state at once. For a file of receiver gathers the template is the O record of the
  receiver, and the filters mark the gather's sources. A layer's points get smaller as they crowd on the screen (from 5
  pixels across down to 2, from how far apart its points typically are), so lines of
  stations stay lines when zoomed out; a ring that small is drawn as a disc.
- **Colours:** the plot's background (the plot window's colour scheme: paper by default);
  sources and receivers in the theme's `source` and `receiver` roles (its red, and its
  blue, or its green where the blue is the accent that marks the selection, as in the
  Everforest themes; another of its colours where they would be hard to tell apart:
  `view/theme.deriveRoles`), each made readable on the background; the highlight in the plot's hover and selection colours. Hover and
  selection are shared with the plot: a selection made on the map selects the points'
  traces, the trace under the pointer in the plot lights up its source and receiver, and
  the point under the pointer on the map lights up its traces in the plot ([Linking the
  plot and the map](#linking-the-plot-and-the-map)).
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
- **The axes carry no values** (the user: "the map does not need any x and y values on
  the axis"): the scale bar, the north arrow and the pointer's coordinates in the status
  bar say what is needed, and the plot area is the same from the first frame on.
- **The unit is named exactly** (the user: "the legend of distance by units should have
  correct ft/survey ft/ meters"): `m`, `ft` (international feet, 0.3048 m) or `ftUS` (US
  survey feet, 1200/3937 m) in the status bar's coordinates, the scale bar and the ruler,
  from the units confirmed with a join, else the survey file's header (`H20`, `H201`), else
  the seismic file's headers. The scale bar says "units" where nothing says; the ruler
  shows the number as the survey gives it and names no unit. Never a guess. **Files that name
  different units** (a second survey file, the open file's headers) are said once a session in
  Messages and at the top of the Layers list ("The coordinates' units disagree (...): the
  map uses US survey feet, the first, and converts nothing"). The gear's
  Lengths shows lengths in another of the three instead, converted exactly.
- **A scale bar** (1, 2 or 5 times a power of ten, at most 150 pixels long) in the plot's
  bottom-left corner and a **north arrow** (grid north) in its top-right one.
- **The strip:** Layers, zoom out, zoom in, fit, back, Ruler (a left drag then measures;
  the button lights, in the same colour as the other on toggles, and stays on until
  clicked again; clicking it while it is on takes the line away. Ctrl + drag measures
  and turns it on too), and the gear: where the point under
  the pointer is described, beside the pointer (the default) or in a strip along the map's
  bottom (kept when nothing is pointed at, so the map does not change size).
- **Levels of detail.** When the points outnumber the pixels, the map draws a point per
  cell of a grid no wider than two pixels (the first point of the cell, a real
  position), and every point once zoomed in closer. The grids, from twice the spatial
  index's cells to one cell for the whole layer, are made with the layer, on the worker
  that reads the file, and go to the GPU with it, so no pan or zoom waits for a level:
  each frame draws the level its scale needs, and only the rows of cells in view.
- **Speed** (measured under software OpenGL, Mesa's llvmpipe, in an optimised build): a
  million receivers 5 m apart in a square, as dense as a survey gets, are read, indexed
  and given their levels in about a second; on a map of 400 × 560 pixels they draw about
  63 000 points at fit and 100 000 zoomed in, and a frame of the whole window takes 3.6 ms
  idle, 3.7 ms (median) while the map pans and 4.3 ms while it zooms, the slowest 20 and
  32 ms. An idle map draws nothing.

### The map's own choices

Taken here, in the plot window's conventions, and not yet put to the user (each says
what it was instead of):

1. **The point under the pointer is described beside it** by default (a box drawn in
   the map, kept inside it), the strip along the bottom a setting. (Either was asked
   for; the box is the one the eye is already at.)
2. **A click on a source shows its record; a click on a receiver selects it and its
   traces** (in a file of receiver gathers, the other way round: a receiver's click
   shows its gather). A source no open file has a trace of is selected. (Before the
   linking, a click selected any point; the plot's design had a click on a source open
   its record.)
3. **A map that shows the whole survey keeps showing it when its window changes size**;
   any other view keeps its scale. (The plot keeps its scale always, but it has scroll
   bars.)
4. **Sources are red, receivers blue** (green where the theme's blue is its accent); the
   open file's own positions are rings in the same colours.
5. **Shift + click selects a range along a line**: the stations from the point clicked
   last to this one, on their line, as Shift + click selects a range of traces in the
   plot. (The linking's first plan had Shift + click add, which Ctrl + click does, as the
   user decided for the plot.)
6. **The record on show is marked** by its receivers in a darker shade of their colour
   and its source as a larger, outlined disc. (Outlined receivers were tried first: on a
   survey of thousands of receivers they merged into a black mass and hid the sources.)
7. **A group's tick hides its layers without changing theirs**, so ticking it again
   brings back what was shown; and **a hidden layer's points are not highlighted** (the
   record on show, the selection, the plot's hovered trace), so hiding the Preplot shows
   the Recorded alone. (Before the groups, the highlight was drawn over a hidden layer.)
   The groups hidden are remembered between runs; a layer hidden on its own only while
   the program runs, as it names a file.
8. **The template box** is off by default (the task's word), a tick under the Preplot;
   the record on show's box is drawn in the outline colour and the hovered shot's in the
   hover colour, each with its X (or O) record and the stations planned in words; a
   station no loaded survey file places is counted ("3 not on the map"), not drawn. With
   no relation file the default template is 8 lines × 120 stations (a guess at a land 3D
   patch: the user sets the real one); the generated records are not written to a file
   (an export, later). A trace whose headers give coordinates but no station (a SEG-Y file
   without a header layout naming them) is at the survey file's station at its place,
   within half a survey unit.
9. **The folder's shots are read only while a survey file with sources is loaded**
   (without one there is nothing to match them to, and reading every file of a folder
   on a network drive is not free); each file is opened through its index cache when it
   has one, but a walk writes none (a folder of thousands would push out the caches of
   the files the user opens); what was found is kept beside the index cache (a small file
   per seismic file), so the folder listed again opens none of its files. A file that
   does not answer for 3 s is passed by and tried again a minute later, once that first
   try has come back (each try that hangs holds a thread until the drive answers); while
   two such tries hang, no other file is tried (a share that stops answering would else
   hold a thread per file): the Layers list says the folder does not answer, and the
   reading goes on when the drive does. A
   source with a file is ringed in the outline colour; one without keeps its plain disc.
   A click on a ringed source shows the file in place of the one the plot shows, as a
   click in Files does.
10. **The filters** are none on by default; they are kept in the settings. The amplitude
   flags take processSEG's default thresholds (thresholds the user sets, and flags for
   every record of a survey, are the QC phase's; they fill the same filters). Dead in the
   headers and all zero are two filters (the header's word and the samples' fact). "Not in
   the template" counts stations, as `recordCompleteness` does, and marks their traces;
   without receiver stations in the headers (traces matched by channel) the counts are
    given and nothing is placed. "Spread not the template" marks only the shots that stand
    out from the survey's own agreement with its template. On `samples/land`, one of the
    six shots is marked ("1 shots of the 6 X records"); on a large irregular survey, with
    your own file, only the shots that stand out are marked, not every one. A
   filter's mark is its kind's colour, a role of the theme, made readable on the map, in a
   shape of its own.

## Linking the plot and the map

The plot and the map show one hover, one selection and one record on show, kept in the
program's core: neither window talks to the other, each draws what the core holds.

- **From the plot to the map.** The trace under the pointer lights up where it was
  recorded, in the hover colour: its source and its receiver, in every layer (the open
  file's own positions, and the survey files' points of its stations). In a shot record
  every trace has the record's source, which is marked anyway, so the receiver is what
  moves; in a receiver gather it is the other way round. `M` (or the plot's menu)
  selects the trace's station, with the station's traces.
- **From the map to the plot.** The traces of the open files recorded at the point under
  the pointer are drawn in the plot as the hovered trace is (the hover colour, line and
  fill; under density alone, their columns tinted): a receiver's trace (one per
  component), a source's whole record. A click on a source shows its record; a click
  on a receiver selects its traces; Ctrl + click adds or takes out, Shift + click
  selects a range along a line, a Shift + drag box selects the traces of the points in
  it, Esc clears (the map's table above).
- **Always marked:** the points of the record on show (its receivers, its source).
- **Says why:** where the hover lights nothing up in the other window, the status bar
  says why, beside the readout or the coordinates: "Trace 1 is an auxiliary trace: it
  has no place on the map", "Trace 18's receiver is not on the map: no loaded survey file
  has its receiver station (line 101, point 105)", "No trace of the open files was
  recorded at this receiver", "24 traces recorded at this source, none in the record
  shown (FFID 12)", "No trace here: no seismic file is open".

**Where the positions come from, before a survey is imported for the seismic file**
(Project > Import survey: it writes the survey's stations and coordinates into the
file's keys, never into the file; then a trace whose headers lack its stations finds them
too):

| The trace headers give | Trace → map | Map → plot |
|---|---|---|
| Coordinates | its own source and receiver (rings) | from those rings |
| Stations (line, point), with the survey's S and R files loaded | the survey files' points of its stations (discs) | from those discs, by station |
| A record and a channel only, with the X (relation) file loaded | the survey files' points of the stations the X file gives that record's channel | **not yet**: a survey file's point finds no trace whose headers lack its station (the status bar says "No trace is matched to this receiver: the open files' headers give no receiver stations"); the open file's own ring on the same spot does, where the headers have coordinates |
| None of these | nothing: the status bar says why | nothing |

The record on show is marked the same ways: by its traces' own positions and stations,
or, for a record whose headers name no station, by the stations its relation file
plans for it. The selection's points come from the traces' own positions and stations
(not through the relation file).

**Cost.** A hover reads nothing, asks for no tile and makes no layer again (a test
counts them); the plot's image is drawn again, and when the map's pointer lights other
traces, each tile's marks (a byte a trace) go to the GPU again; the map uploads its
highlight (the record's points, and the hovered ones). A hover reads nothing. Measured
on a large field record (with your own file: a few thousand traces at a pixel a trace)
with its S, R and X files, in the "Plot and map" layout under software OpenGL (llvmpipe,
an optimised build, the machine busy with other work): sweeping the plot costs a frame;
a hover draws again only the stripes of the trace it leaves and of the one it reaches.
With the pointer sweeping the map, the frames that light another trace in the plot still
draw its whole image (its marks change). A GPU draws either in a fraction of that.
`samples/land` is 96 traces: the same gestures, and the cost is the drawing, not a read.

## The plot's menu: functions on the data

Right-click the plot. The menu holds only what acts on the data; how the plot looks is in
the strip (display modes, gain, sort, zoom, fit, back) and in the gear popover (colours, killed traces hidden or blank,
trace overlap, display header, scales), and the display header has its own menu (a right
click on it).

Its first line says what the trace operations act on: the trace under the pointer
("Trace 37"), or, when that trace is in the selection, the whole selection ("12 selected
traces"); the selection stays as it was. Over no trace it says "No trace here".

| Item | Key | |
|---|---|---|
| *The trace under the pointer* | | The menu is in short groups, each under a muted heading. The first holds the trace operations |
| Reverse polarity | `R` | that trace or the selection, 180 degrees out of phase; ticked while the trace under the pointer is reversed, and then it puts the polarity back |
| Kill / Restore | `K` | drawn blank (or left out of the plot: the gear popover's "Hide killed traces"), left out of the processing, of the levels the gain computes over the record and of spectra; "Restore" over a killed trace |
| Exclude from plot filters | `E` | the plot's filters (the Filters menu's, the Aux traces too when that is on) never touch that trace or the selection; ticked while the trace under the pointer is excluded, and then it puts the filters back. A filter of the trace's own (Filter this trace...) still runs; marked **E** |
| Filter this trace... | | gives the trace (or the selection) a frequency filter of its own; "Remove the trace's filter" appears when one has it |
| **Analyse** | | |
| New plot > FFT | `F` | that trace's amplitude spectrum, or the selection's averaged, raw and through the plot's filters, in a window of its own ([Spectra](#spectra)); several can be open. The same submenu lists the other views of the selected traces |
| Compare > Set as A / Set as B | | copies the trace under the pointer into that slot, even when it is one of a selection. The copy does not follow the plot. Filling the second slot opens Compare two traces (the user guide) |
| Store as reference... | | keeps the trace under the pointer as a reference |
| **Map** | | |
| Select its receiver on the map | `M` | the receiver the trace was recorded at (in a receiver gather, its source), or those of the selection, with their traces; greyed out where the trace has no place on the map |
| **Whole record** | | |
| Reverse polarity of all traces | | every trace of the file, in the picture and every graph, ticked while on ([Polarity](#polarity)) |
| Clear all edits for this file | | the traces as the file has them; Undo brings the edits back |
| *Last, with no heading* | | |
| Undo *what it was* | Ctrl + Z | takes back the file's last kill, restore, polarity change or clearing, as Edit > Undo |
| Redo *what it was* | Ctrl + Shift + Z | makes it again, as Edit > Redo |

On a selection, a trace operation does to every selected trace what it does to the one
under the pointer: Kill kills them all (Restore, over a killed trace, restores them all),
Reverse polarity reverses them all, or puts them all back when that trace is reversed.
Compare does not: each slot holds the one trace under the pointer. While that file and
that trace are on show, the edits row marks it A or B beside K, R and the filter mark.
Later: show headers (`H`) and, perhaps, a filter on one trace (as a layer of its own,
with the overlays).

## The Aux window

A second trace panel of the same reader, layout and drawing as the Seismic window, with
fewer controls (`PanelRole`, `capsOf` in `core/panels`): View > Windows > Aux. It is closed
at a first start, after Reset the windows and in a layout that does not name it; opened, it
docks to the right of the Seismic window, taking 30 % of its width, and its open state and
place are kept with the layout.

- **What it shows.** The auxiliary traces of the record the Seismic window shows (its panel's
  trace filter is fixed to auxiliary-only), in the file's order, as recorded: the file's
  edits (kill, reverse polarity, a trace's own filter) apply, the plot's filters and sort do
  not. It follows the Seismic window: stepping records, another file, Follow the latest
  file, a reload. It has no record of its own (the panel refuses `go to gather` and the
  rest of the commands that would give it one), reads nothing while closed, and starts no
  record-level job of its own (first breaks, the record's check, the template's). A record
  with no auxiliary traces says "This record has no auxiliary traces." A record whose
  auxiliary traces are all killed, while killed traces are hidden, says "Every auxiliary
  trace of this record is killed and hidden."
- **Drawing.** Wiggles only, with the positive and negative fill buttons; no density and no
  display-mode buttons. The gain is its own: None (0 dB, as in the Seismic window), Fixed
  and Normalized, with the gain amount; it starts Normalized for each trace, as a pilot and
  a monitor channel differ by orders of magnitude, and its trace overlap starts at 1 (a
  trace spacing of swing, as in the Seismic window). It starts with a red wiggle line and
  positive fill (the theme's negative-fill red) and a black negative fill, on white paper;
  Paper, Follow the theme and My own in the gear still apply, and a saved choice is kept.
  The gain's list has no "Let viewSEG choose" and no AGC, Exponential or Float.
- **View.** The same zoom, fit and back buttons and keys as the Seismic window, over a view
  of its own: the "keep the scales on the next record or file" rule is the Seismic
  window's, since it is the panel's (`carry`). Its time range is its own; it is not linked
  to the Seismic window's (the Seismic window has no such link either): aux traces are often
  shorter or have another length.
- **Not in it.** The first-break overlay, the frequency filters and Raw, sort, the Seismic
  and Aux toggles, the template button, the component toggles, the record stepper (Page
  Up, Page Down, Home, End, Ctrl+G) and the gear's display presets, density colour map,
  component colours and Scales tab.
- **The gear** has the Look tab (colours, the cursor time line, time across) and the Traces
  tab (trace overlap, killed traces hidden or blank, the display header's rows).
- **The right-click menu** is the Seismic window's one (above) without Map, Whole record,
  Exclude and Filter: Reverse polarity, Kill / Restore, Analyse (New plot, Compare, Store as
  reference), Undo, Redo, Explain.
- **Selection and edits** are the file's and the program's, not the window's: a click on an
  aux trace there is THE selection (the plots, the spectrum windows, the Vibrator window,
  the status bar and the Headers window follow it), and a kill or reversal made there shows
  in the Seismic window when it shows the trace.
- **Kept** (`settings.nif`, `(aux ...)`): its display (gain, fills, look) and display
  header, apart from the Seismic window's defaults; whether it is open and where it is
  docked are the layout's. An agent's changes to it stay for the session, as for the Seismic
  window.

### Edits to traces

Killing a trace and reversing its polarity are edits: lists kept per file, by the trace's
index in the file, beside the file and never in it (the file is opened read-only). A
killed trace is drawn blank (the plot's background, no wiggle); with "Hide killed traces"
(the gear popover, a setting) it is left out of the plot instead, and the traces beside it
close up: the record is laid out again without it, at the same scales and place, and
again with it when it is restored or the setting is turned off.
"Reverse polarity of all traces" is an edit of the file too, remembered and undoable:
each file shows its own, every graph of it follows it, and another file opened in the
same window is shown as it was left. Messages lists every change.

**History.** Every change is a step: Edit > Undo (Ctrl + Z) takes back the last, Edit >
Redo (Ctrl + Shift + Z, Ctrl + Y) makes it again, as far back as the session goes (a
thousand steps a file, fewer when they are changes of millions of traces: twenty million
traces named over all its steps); a new change drops what was undone. The Edit menu names the step
("Undo trace 21 killed") and works whichever window has the focus, on the file the
Seismic window shows; the plot's menu has the same items. "Clear all edits for this file"
is a step too. The history is for the session: it is forgotten at the quit, the edits are
not.

**What is remembered about a file.** The edits are kept with the file's identity, not its
name (`core/identity`, `core/filememory`): its size and a hash of its first and last
64 KiB, read when it is opened (a few milliseconds, off the screen's thread), confirmed
by a hash of every byte on a lane of its own, beside the background work (one changed while
it is read is not confirmed). A file renamed or moved keeps its edits:
opened again, under any name, it shows them at once (the size, the ends and the
modification time match what is remembered), and Messages says so; a copy with one byte
changed is another file and shows none (when even its time is the same, what came at
once is taken away again when the hash tells them apart, with a warning). They are
written beside the program's settings (`<config>/files/`, one small NIF document per
file), a second after a change and at the quit, each whole or not at all (a temporary
file renamed over it; one that a write cut short leaves is removed at the next start);
the data file's bytes and modification time are never touched. A file whose drive does not answer opens as always; its edits
come when its identity can be read, and edits you make before that are kept by the file's
path, size and modification time (`pending-<hash of the path>.nif`) until it is: quit
before, and the next run that opens the file unchanged does not apply them (the path says
nothing of the content): they are kept as an unconfirmed record of the file's identity,
said once and listed in the Project window to apply or to forget (a file changed since:
Messages lists them and they are removed); a second run
whose drive is silent too keeps the first run's beside its own. Two viewSEG at once with
the same file open (two windows) lose none of each other's edits: before a write, the
entry's time is compared with the one read or written last, and another's change is
merged in (what either added or took away is kept), Messages says so, and the plot shows
the other's edits too (each window shows the other's once it writes itself); the two
never write the entry at the same moment. One file opened under two
paths in a run (a copy, a hard or a symbolic link) has one set of edits, those made under
each path kept, and one entry: at once when the two paths' size, ends and modification
time agree, otherwise once both are hashed whole; Messages says so. A file taken so at
once whose hash then tells it apart (the same size, first and last 64 KiB and
modification time, another content: rare) has its edits taken away, also those made
under its own path meanwhile, which stay with the other. When a hash of every byte says
that a file taken at once for one remembered was another, the remembered file's entry is
put back as it was. An entry with parts that cannot be read (edited by hand) says so and
brings back the rest, and is not written again until its edits change (so as not to drop
those parts): when its file was opened is kept beside it (`<entry>.seen`), so that File
memory never lists a file in use as not opened for months; a later version's parts are
kept as they are. Edits an agent makes
through agent control are shown for the session only (docs/agent-control.md), marked so in
the row of edits.

**Edit > File memory...** lists what is remembered: the name a file was last seen under,
when it was last opened, what is kept, the file's size and the entry's, and whether the
file is gone from where it was ("not found" when its folder is not there, as a network
drive not connected: that is not counted as gone). The entries come at once; where each
file is, is looked at afterwards, folder by folder ("looking..."), so that a drive that
does not answer holds only its own entries: after 3 seconds they say "not answering"
(never gone; Refresh looks again) and the folders after it are looked at. It removes the
entry selected, those not opened for a number of days (90 to begin with), or those whose
file is gone; each removal lists what it takes away and asks first (a listing that comes
meanwhile does not change what it takes), and Messages names each entry forgotten.
Nothing is ever dropped on its own.

**Handing a list over.** Edit > Export trace edits... writes the edits of the file shown,
as remembered: an edit shown for the session only (agent control's) is left out, since a
list handed on outlives the session, and Messages says how many; one an agent hid for the
session is in it,
as a CSV table (`trace,record,channel,edit,file`: the trace's number in the file from 1,
its field record and channel from the headers, `killed`, `reversed` or `excluded`, "all" for reverse
all, and the name of the file the list is for on every row) or as viewSEG's own NIF
document (with the file's identity), for processing. Edit > Import trace edits... reads
either (a CSV table needs a header naming a `trace` column, within its first lines;
without an `edit` column every trace listed is killed; a table saved by a spreadsheet,
with a byte order mark, quoted cells, `;` or tabs, reads as well) onto the file shown, as
one step that Undo takes back, read off the screen's thread (lists of up to 64 MB);
traces past the file's last are left out and said, before any run is expanded (a list
from elsewhere naming "1-50000000" costs no more than the file's traces), and a list
names at most 20 million traces of each edit (the rest left out and said); a list made
on another file is applied by trace number all the same, with a warning.

An edit must show at once. The window's reader keeps the samples it last read from the
file (as decoded, up to 128 MiB), so an edit of traces in view, a gain change, or a
slightly shorter view, makes the picture again from them, off the screen's thread, with
nothing read from the file; the picture before stays until the new one is drawn (on a
zoom of a few dozen traces, within a frame under software OpenGL; with your own file of
a large record, the same, from the samples already read). Otherwise only the view's
tiles are made again. A kill, or a restore, also has
the record's level taken again, so that the gain leaves the killed trace out.

## Spectra

**FFT windows.** New plot > FFT (the plot's menu, or `F` over a trace) opens the
amplitude spectrum of the trace under the pointer, or of the selection when that trace is
in it, in a window of its own: titled by what it shows ("FFT: trace 12 · FFID 1 ·
shots.sgy" on `samples/land/shots.sgy` record 1, "FFT 2: 12 traces · ..."), floating beside the middle of the main window the
first time, dockable anywhere like every window. Several can be open. Unless **Freeze**
is on, a window follows the Seismic plot it was opened from, as a New plot window does:
it shows the traces it was opened on until the plot changes, then the selection in the
record on show, or the traces in view when nothing is selected, and a new record or a
new file. It follows the plot's filters, its Aux toggle too, as they change (shown raw
or not alike: both curves are drawn), and the kills of its traces (a killed trace left
out, a restored one taken back), computed again from the samples at hand, so the file
is not read again when those samples are already held. A reversed polarity changes no
amplitude, and the phase is of the samples as recorded, so a reversal asks nothing.
**Freeze** (the pin at the right of the first row, off by default; tooltip "Freeze: keep
these traces while the plot moves on") keeps the traces and the file it shows, and the
filters they went through; the title names them ("Frozen · trace 12 · FFID 1 ·
shots.sgy"). Unticked, it follows the plot at once. A record that cannot feed it leaves
the window open and says why. Closing one (its ×) drops its work if it is still being computed. A
window's number is the lowest free one, so a window opened again takes the place the
layout kept for that number; a layout that names FFT windows not open loads without a
word.

**The live Spectrum panel** (View > Spectrum; a tab behind the map in the first
layout) shows the same for what the Seismic window shows: the selected traces of the
record on show when there are some, else the traces in view, over the visible time (or
the whole trace). A selection left in another record does not keep it there. It follows
the plot as you pan, zoom, select, step to another record or file, kill a trace or change
a filter, asking again only when what it is of changed; an answer older than the one
shown is dropped, and while a pan goes on each newer answer is shown as it comes. The
**Freeze** pin, at the right of the first row, keeps the traces and the file it shows;
the line under the controls names them. Unfreezing follows at once. It
works only while it is on screen: hidden, behind another tab or collapsed it asks for
nothing. A layout saved before the panel came keeps it hidden.

**How many traces.** A spectrum takes at most 4096 traces, and no more than 128 MiB of
their samples (559 traces of 60 s at 1 ms): more selected or in view are taken evenly
spread over them, and its line of words says so ("64 traces averaged, spread evenly over
the 12 000 selected").

**What a spectrum is.** processSEG's spectrum (`SpectrumPlan`): each trace's window is
demeaned, tapered (a sin² ramp over 10 % at each end) and zero-padded to the next power
of two, or further while a bin is wider than half the plot's narrowest filter feature
(a ramp, half a notch: `narrowestRampHz`), up to 8 times; amplitudes are one-sided and
corrected for the taper, so a sine of amplitude A on a bin reads A. A sine between two bins reads
up to about 3 dB (a factor of about 0.71) low with the window used, at each of its two
neighbouring bins: read a tone's amplitude where it is on a bin, or take it as at least what
the curve shows. Several traces are averaged over power (the RMS amplitude across them).
The frequency axis runs from 0 Hz to Nyquist (500 / interval in ms). Left out, and
counted in the window's line of words: killed traces, traces the file marks dead, traces
that cannot be read or hold a sample that is not a number, and traces at another sample
interval than the first. Auxiliary traces count as seismic ones do (a pilot's spectrum).

**Raw and processed.** The raw curve is the trace with its own filter, without the
plot's filters; the processed one is those samples through the plot's filters only
(Filters in the strip), run on whole traces before the window is cut, also when the
plot is shown raw, so the two compare. A trace's own filter is part of the trace: it
is in the raw curve wherever that trace is shown or analysed, and no box turns it
off. The window names it ("Trace 12: own filter, band-pass 10-60 Hz"; of several,
"N traces have their own filter"). A reversed trace is multiplied by -1 first and named
the same way ("Trace 12: reversed"; of several, "N traces are reversed"). Reverse-all is
that same sign flip, said once ("All traces are reversed"); a trace reversed on its own
as well is as recorded, and is not called reversed. Where the own
filter runs instead of the plot's,
the plot's filters do not apply to that trace, so its processed curve equals its raw
curve, and the line says "this trace uses its own filter instead of the plot's".
The response is the plot's filters' response, and only when the plot has a filter
on. **Processed** and **Response** are drawn unticked, and do not toggle, while no
filter is on in the plot; an own filter alone does not unlock them. The stored
choice shows again when a plot filter is. In
dB both are on one scale, 0 dB at the larger peak of the two (a filter's cut shows as
the gap between them), and the line of words says which amplitude that is ("0 dB =
amplitude 0.000142 (raw peak)"): each window has a 0 dB of its own, so two windows
compare by it; linear, in the file's sample units. The frequency axis can be
logarithmic (0 Hz is then left out). A spectrum of one trace has its phase too (Phase:
degrees, from the window's first sample, drawn under the amplitude). The picture is
**Unwrapped** at first; **Magnitude 0-180** (absolute value, axis fixed 0 to 180),
**Signed +-180** and **Delay removed** are the other choices, kept with the window's
other choices. The Unwrapped and Delay removed pictures are unwrapped on a grid 4 times finer
than the bins (the trace zero-padded to 4 times the FFT's length, as the Phase spectrum
plot does) and read at the bins, so an arrival late in the window (past half of the FFT's
length) is not folded the wrong way. Where the amplitude is more than 60 dB below that curve's peak the phase is
not drawn, and the unwrap does not run across the gap. The readout gives the phase as
drawn and, unless the picture is signed, the signed value in brackets; Delay removed
also says the delay in ms. A sweep's phase climbs steeply because its delay grows with
frequency; for vibrator QC, read the phase against the pilot in the vibrator signature
plot. **Phase** is drawn unticked while the spectrum is not of one trace, the choice kept.

**The filter's response.** Under the curves, a thin faint line over a fainter shade
(the pass band reads as a lit area behind the data, which is drawn over it), the gain
the plot's filters apply at each frequency: a unit impulse in the middle of a trace as
long as these is put through their FFT filters (processSEG's plan, its padding, in
float32), and its output's amplitude is taken at each frequency. So it is what they
really do, not the design: a notch's centre is as deep as the plan's own frequency
sampling leaves it (deeper on a long trace than on a short one; the design says 0 at
the centre), the stop band their round-off
(below -120 dB). The DC removal and the trend taken out before the filter depend on
each trace's own mean and trend, are no gain, and are left out of it. It is drawn on a grid of its own, not the
spectrum's bins: 1024 even steps to Nyquist, and dense across each notch (its very
centre included) and each ramp, so a notch is drawn at its depth wherever it falls
between bins. In dB, 0 dB is the top of the curves and the gain is clamped only at the
plot's floor (its name then says "below -120 dB drawn at it"); linear, a gain of 1 is
the larger peak; under the plot it reads in dB, at its point nearest the bin read.
It shows what the filters do; the processed curve shows what the data and the window
make of it. **Response** hides it; it is on by default and drawn whenever the filters
have a pass band or a notch and reached some of the traces: when they reached none
(auxiliary traces, the Aux box off) it is not drawn, so nothing looks filtered.

**Why this window.** A narrow notch in a spectrum is filled in from its sides: by the
taper's leakage, by bins too wide for it, and by the filter's own ringing near the
trace ends (real energy in the processed traces, not an artefact of the spectrum).
A wider taper widens the main lobe, which fills a notch a few bins wide: the 10 % taper
shows a narrow notch deeper than a wider one, so it stays. What helps is finer bins when
the window is short, hence the padding above. A Hann window can show a weak hum line the
10 % taper's leakage hides, but not a notch. With your own file, the response curve shows
what the filter itself does; the processed curve shows what the data and the window make
of it. On a long trace the notch's centre reaches the filter's own floor; on a short one
the bins fill it in. `samples/land` is 1.5 s at 2 ms.

**What the processed curve went through.** The filters are made for the traces' own
sample interval (a corner or notch past its Nyquist is cut or left out, as in the
plot, and the words say so), and the processed curve is of the traces they reach
only. An auxiliary trace goes through the plot's filters only when "Filter the Aux
traces too" is ticked, as in the plot. With it off, an auxiliary trace is in the raw
curve (with its own filter, when it has one) and left out of the processed one
("processed: notch 60 Hz, 23 of the 24 traces (the auxiliary trace is not filtered:
Filters > Filter the Aux traces too is off)"; the legend names it "processed (23 of 24)":
the two curves then differ by those traces too), and a pilot shown alone has no
processed curve at all ("not processed: the auxiliary trace is not filtered: ...");
nor has a spectrum whose filters
cannot run at its interval
(every notch past Nyquist, say). The words are the answer's own: they name what its
processed curve went through, never only what the plot has set now.

**Time.** An FFT window is over the whole trace by default; "Visible time" takes the
time the Seismic window showed when it was opened (and the whole trace again when
unticked). That time is read on the Seismic window's time axis, which starts at one time
for every trace (the first seismic trace's start time, as the plot draws them), so a trace
recorded with a delay is cut where the plot shows it, not at its own start time. The live panel is over the visible time by default. How a window shows its
spectrum (dB or linear, the axis, the curves, the time, the phase) is kept: a new FFT
window starts as the last one changed, and the live panel as it was left.

**Reading it: the cursor.** As the Seismic window's cursor: the pointer over the plot
puts the cursor at the nearest frequency, on the curve nearest the pointer, with a dot on
each curve and, from the cursor's point, a line to each axis with the exact frequency
and level written on the axis over its tick labels. The line under the plot reads the
frequency and each curve's level there ("24.4 Hz   raw -3.1 dB   processed -40.2 dB"),
rounded as the axes need: the frequency to the spacing of the bins ("60.1" at 0.24 Hz,
"60.00" at 0.06 Hz), dB and degrees to a tenth (never "-0.0"), linear amplitudes to
four significant digits. The box on the value axis says what the line under the plot
says for the cursor's curve: a level below the -120 dB floor is drawn at the floor but
read as it is ("-140.0"), the filters' response is read in dB on a linear axis too
("-12.0 dB", its unit then written), and an amplitude of 0 has no level ("raw -", no
box; agents get null), never the floor's -120. **The keys** (the window has the focus once clicked): Left /
Right move the cursor one frequency bin, Home / End to the first and last, Up / Down to
another curve (on a logarithmic axis, which leaves 0 Hz out, Home goes to the first
bin drawn, and the cursor is never held where it is not drawn); the keys then hold it, and it stays where they put it when the pointer
leaves the plot, so they can step it across a notch; the line under the plot starts
"Held ·" (its tooltip says which keys move it and how to let it go), and moving the
pointer over the plot, or Esc, lets it go. Held, it keeps its frequency and its curve:
when the bins change (a narrow notch makes them finer, "Visible time" another length,
the live panel another view) it moves to the bin nearest the frequency it was held at,
and when curves appear or go (the filters' response, the processed curve) it stays on
its own (on the top curve while its own is not drawn, and back on it when it is again).
Alt + arrows through the record keep it too, so a level at one frequency can be read
trace after trace.
The cursor is `core/plotcursor`'s, made for an f-k plot too (Up / Down there step its
second axis). The wheel zooms about the pointer, a drag pans, a right drag zooms to a
box, a double click shows everything again; no view goes past the data. A click on a
curve's name in the legend hides it.

**Stepping through the record: Alt + arrows.** In the Seismic window, Alt + Right /
Alt + Left select the next / previous trace of the record in the order shown (Alt + Down
/ Alt + Up when time is across: the arrows along the traces, the first trace at the top),
from the trace clicked last (else the selection's last, or first going back; else the
trace under the pointer; else the first in view), the plot scrolled by as little as
keeps it in view. Traces the trace filter hides are skipped; killed traces shown are not
(they are there to step over). In an FFT window of one trace, Alt + Right / Left select
the next / previous trace after its own, and the window shows it; in one of a selection
they step from the selection, and the window shows the trace stepped to. A frozen FFT
window keeps what it shows: its trace stays, and Alt + arrows in it step the plot's
selection (from the selection, as in the plot; from its own trace while nothing is
selected or under the pointer), so they are never stuck on the trace after its own. In the Spectrum panel they step the plot's selection, which the panel
follows. (Alt + Left
was also "back" in the plot; back is Backspace now, so the user's request wins.)

**Off the screen's thread.** The spectra are computed by a reader of their own (`core/
spectrumreader`), which reads only the traces it does not already hold (as decoded, up
to 128 MiB: a pan reads the traces it brings into view; a filter, a time window or
another window of the same traces reads nothing; let go once no spectrum window is open
and the live panel is off the screen), and gives up a request between blocks of traces
when a newer one of its window comes, unless it has been at it 60 ms already (then it
finishes: a narrow filter makes each request of a 600-trace view take about 0.2 s, and a pan
asks every frame, so giving them all up showed nothing at all), or when the window
closes; a request read and computed whole is answered all the same, so the live panel
moves on while a pan sends newer ones.

**The plot itself** (`view/curveplot`, drawn by `ui/imgui/curveplot`) is a plot of named
curves over one axis, each in its colour with a legend, that can be drawn turned (the
axis down from the top and the values across, as a signal beside a seismic trace): the
vibrator analysis's plots (signal, spectrum, correlation, phase) are made with it.

## Empty and first-run state

With no file open, the plot area shows a start screen instead of an empty dock:

- **Open file...** (Ctrl + O) and **Open folder...** (Ctrl + Alt + O), as large buttons;
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
| A filter's corner changed | the plot follows: a new filtered tile each change the reader keeps up with (changes it has not reached are dropped), each of the view alone, from the samples at hand (no read). Measured with `tools/filterbench` (release build, software OpenGL under xvfb, on a 32-core machine shared with other work, load 20) on a 3954-trace, 4001-sample record dragging f2 of a band-pass over 600 frames: the whole record in density, frames 10.2 ms median, 12.5 ms 95th, a tile every frame; 723 traces of wiggles, 38.9 ms median, as a pan of the same view (38.8 ms: drawing that many wiggles on software OpenGL), a tile every frame; no read from the file |
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
   Confirmed. Later (2026-11-15) the user asked for Alt + arrows to step through the
   record's traces, so in the plot back is Backspace alone (the map keeps Alt + Left).
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
    components; File order in the sort drop-down goes back to the file's order.
    Confirmed ("by flag will sort by line/station then by component").
17. **A sort keeps the view.** Confirmed.
18. **Sort keys are the display header's fields**; raw header words come with the gather
    domains. Taken as built.
19. **Density only when it is chosen**, and in the wiggle modes zooming out stops at one
    pixel a trace (the user: "it should only be on if the user is asking for it",
    "maybe dont allow a zoom out that far?"). Changed by the user: the draft handed over
    to density below 4 pixels a trace.
20. **The trace overlap is 1 by default**, from 0.1 to 10, in the gear's Traces tab
    ("Trace overlap should be configurable"), with - and +.
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
