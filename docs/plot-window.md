# The plot window and the map: design

> **Confirmed by the user** (2026-11-14). Built from the user's requirements and feedback;
> every choice that was open in the draft is now the user's decision, as
> [Decisions](#decisions) at the end lists, with what the user changed.

## Layout

```
┌ Seismic ───────────────────────────────────────────────────┐
│ [▒|∿|▒∿][◢|◣][⊢][↦][-][1.00][+] overlap [Filters ▾][Raw]   │  controls (they
│ [gain▾] [-][+0][+] dB [12.5] tr/in [200] ms/in             │  wrap when narrow)
│ [-][+][fit][<] [◂ 1 / 1 ▸]                                 │
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
- **Time down, or time across:** as seismic is plotted, time runs down and the traces
  across; a toggle in the strip turns the plot so that time runs from left to right and
  the traces are stacked from the top down, as signals are drawn (see
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
- **The cursor's time line**, a toggle in the strip after the fills (⊢; off by default,
  remembered between runs): when on, a thin line runs along the pointer's pixel row
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
  error colour), **R** (reversed, in its accent colour), **KR** for both, a thin bar where
  traces are too close for the letters; the row goes when the record has no edit left.
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
  - **display mode** (▒ ∿ ▒∿ above): greyscale density, wiggles, or wiggles over
    density, and two toggles for the wiggles' fills (◢ ◣): the **positive fill** (the
    lobes right of the trace, above it when time is across) and the **negative fill**
    (left of it, below it), either, both or none; the symbols turn with the plot. The default is **wiggles with the positive fill**, black on white paper.
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
  - the **orientation** (↦, a toggle on the symbols' line after the cursor's time line):
    time down, or, while it is on, time across ([Orientation](#orientation)); kept with
    the display, so a new plot window starts the way the last one was left;
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

## Orientation

A plot can be drawn two ways (the user, on the vibrator analysis plots that reuse the
plot: "realistically some of these plots will need to be rotated -90 degrees and
displayed left to right"), chosen per plot window by the toggle in the strip and kept
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
  reading the file again; the picture on hand is drawn stretched until it comes. On
  Morgantown (an optimised build, llvmpipe, the machine at a load of about 12), at the
  widest wiggle view of the default layout, the sharp picture comes 70 to 90 ms after the
  turn, and 20 to 60 ms in density: the processing and drawing of the new view; before,
  the turned view was read from the file again (on a local drive, from memory, as fast;
  on a network drive, a read of the view like any pan).
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
  fewer: on Morgantown at the wiggle limit, the tiles then keep twice the samples (every
  second sample's extremes, not every fourth's), and while the arrow key pans along the
  traces the frames took a median of 51 to 83 ms time across against 45 to 67 ms time
  down (three runs each; the same run varies by half from one to the next).

Pictures (`docs/screenshots/turn-*.png`): Morgantown's first breaks near the source time
down and time across, and the sweep pilot of `Sweep0.sgy` (Aux alone, normalized per
trace) both ways.

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
the picture before stays until the reversed one is drawn. It is an edit of the file, not a
setting: it holds for every record of the file, comes back with the file when it is
opened again (also after a restart: [Edits](#edits-to-traces)), is undone with Edit >
Undo, and another file is shown as it was left.

**Reverse polarity** of a single trace, or of the selection that holds it (`R`, or the
plot's menu), is an edit of the file's traces (see [Edits](#edits-to-traces)): those
traces' samples are negated (processSEG's `reversePolarity` on their live samples, as
`polarityOp` does) where the window's reader prepares them, before the pipeline and the
gain. A trace reversed both ways is as recorded. A trace the file marks dead stays blank,
reversed or not (it is never drawn); the display header and the status bar still say it is
reversed.

## Filters

The **Filters** button in the strip (a funnel icon, lit while filters are applied), before
the gain (the order the samples go through them), opens a drop-down that says what the
traces go through ("Filters: 8-14-60-80 Hz, notch 60 Hz x3, DC"; "Filters: none"), as
the button's tooltip does, and holds every setting, applied as it changes (a slider sends its value every frame it moves). The traces go through, in
order: the **DC removal** (none, the mean: `demeanOp`, or the mean and a linear trend:
`detrendOp`), then one zero-phase filter (processSEG's `filterOp`): a **low-cut**,
**high-cut** or **band-pass** by its four corners (`f1` to `f2`, the low-cut ramp; `f3`
to `f4`, the high-cut ramp; cos² ramps, `bandPassOp(Corners)` when there is no notch),
and the **notches** (`withNotch`: each at a frequency, with a width and a number of
harmonics; **+ 50 Hz** and **+ 60 Hz** add the power line's with two harmonics). Then
the polarity and the gain, as before. The sliders are logarithmic (fine at low
frequencies), each corner between its neighbours (`f1 < f2 <= f3 < f4`, `core` keeps them
so whoever sends them), and end at the file's Nyquist frequency: a corner or notch set
for a finer interval is cut at Nyquist or left out for this file, and the drop-down says
so; the processing never stops for it.

**Raw / processed:** the **Raw** toggle beside the button, and `P` while the plot has
the focus, show the traces without the filters, under the same gain, and filtered again;
both are disabled while there is no filter. **The Aux traces** go through the filters
only when "Filter the Aux traces too" is ticked (processSEG passes an auxiliary trace by
otherwise); the gain still leaves them as they are. A plot of auxiliary traces alone
takes its level from them, so a pilot sweep shown alone is drawn.

**The cost follows the view.** The panel's reader filters the tile's traces and samples
only (and the margin the filters need around them), on a `ProcessPool` of its own, off
the UI thread; while the layer filters it asks for whole traces, so every later change of
a parameter, of raw or processed, or of the Aux box, is made from the samples it already
holds, with no read of the file (also when the file's drive does not answer). The picture
before stays until the new one is drawn. While a slider moves, the reader finishes each
tile it has begun and takes the newest change next (those it never reached are dropped),
each tile it finishes is drawn though a newer change waits, and after the first change
each asks for the view alone (the read-ahead comes back with the next view): so the plot
follows the slider instead of waiting for it to stop.
The filters are on the plot's layer: they go with it to the next record and to the next
file by every route, and the settings keep them (not Raw) for a new plot. Measured: see
[Performance targets](#performance-targets).

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
| Backspace, or Alt + Left | Back to the previous view |
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
| Ctrl + left drag | **Measure:** a line from press to release, its length (in the survey's units) and grid bearing beside it, until Esc |
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
| Ctrl + Z | Edit > Undo: take back the last change to the edits of the file the Seismic window shows (a kill, a restore, a polarity change, reverse all, a clearing, an import), whichever window has the focus; a text field keeps its own Ctrl + Z |
| Ctrl + Shift + Z, Ctrl + Y | Edit > Redo: make the change undone last again |
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
  tick with its count and its colour, none on by default: traces dead in the headers, not
  decodable, killed; the amplitude flags of processSEG's `qc/amplitude` with its default
  thresholds (noisy, clipped, spiky, constant, weak, DC offset, all zero, not a number);
  missing from the template (the stations the X record plans that the record has no trace
  of: `recordCompleteness`'s `missingStations`), not in the template (its traces at
  stations the X record does not list), recorded twice; auxiliary; without a position;
  reversed; and, survey-wide, **spread not the template**: the shots whose X record agrees
  with the template the X records describe far less than the survey's shots typically do
  (`compareRelations`' Jaccard index under the median less three robust deviations). A
  filter's points are ringed in its colour (where points crowd, a disc a little larger than
  theirs); its tooltip says what it counts or why it is not checked; Select selects its
  traces in the plot; the point under the pointer says which filters mark it ("Marked:
  noisy"). The record is read on a background job when one of the filters that need it is
  on and the record shown changes (a chunk of 512 traces at a time); the rest come from the
  state at once. For a file of receiver gathers the template is the O record of the
  receiver, and the filters mark the gather's sources. A layer's points get smaller as they crowd on the screen (from 5
  pixels across down to 2, from how far apart its points typically are), so lines of
  stations stay lines when zoomed out; a ring that small is drawn as a disc.
- **Colours:** the plot's background (the plot window's colour scheme: paper by default);
  sources in the theme's red, receivers in its blue, or its green where the blue is the
  accent that marks the selection (as in the Everforest themes), each made readable on
  the background; the highlight in the plot's hover and selection colours. Hover and
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
  the seismic file's headers; "units" where nothing says, never a guess. **Files that name
  different units** (a second survey file, the open file's headers) are said once in
  Messages and at the top of the Layers list ("The coordinates' units disagree (...): the
  map uses US survey feet, the first, and converts nothing"). The gear's
  Lengths shows lengths in another of the three instead, converted exactly.
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
   out from the survey's own agreement with its template: on Morgantown, whose records are
   irregular (a median Jaccard index of 0.78 against the 23 × 129 template its X records
   describe), 26 of 5519; on a regular survey, every shot that is not its template. A
   filter's colour is one of the theme's palette, made readable on the map.

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
(File > Import > Survey...: it writes the survey's stations and coordinates into the
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
highlight (the record's points, a few thousand, and the hovered ones). Measured on the
Morgantown record (3 957 traces at a pixel a trace) with its S, R and X files, in the
"Plot and map" layout under software OpenGL (llvmpipe, an optimised build, the machine
busy with other work): sweeping the plot, 16 to 17 ms a frame (median; an idle frame
10 to 12): a hover draws again only the stripes of the trace it leaves and of the one it
reaches, as the whole image draws them, over the image kept (it drew the whole image,
about 30 ms on llvmpipe, 39 to 41 ms a frame). With the pointer sweeping the map, 11 to
17 ms a frame; the frames that light another trace in the plot still draw its whole
image (its marks change), up to 50 to 70 ms on llvmpipe. A GPU draws either in a
fraction of that.

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
| Reverse polarity | `R` | that trace or the selection, 180 degrees out of phase; ticked while the trace under the pointer is reversed, and then it puts the polarity back |
| Kill / Restore | `K` | drawn blank (or left out of the plot: the gear popover's "Hide killed traces"), left out of the processing, of the levels the gain computes over the record and of spectra; "Restore" over a killed trace |
| FFT in a new window | `F` | that trace's amplitude spectrum, or the selection's averaged, raw and through the plot's filters, in a window of its own ([Spectra](#spectra)); several can be open |
| Select its receiver on the map | `M` | the receiver the trace was recorded at (in a receiver gather, its source), or those of the selection, with their traces; greyed out where the trace has no place on the map |
| Reverse polarity of all traces | | every trace of the window, ticked while on ([Polarity](#polarity)) |
| Undo *what it was* | Ctrl + Z | takes back the file's last kill, restore, polarity change or clearing, as Edit > Undo |
| Redo *what it was* | Ctrl + Shift + Z | makes it again, as Edit > Redo |
| Clear all edits for this file | | the traces as the file has them; Undo brings the edits back |

On a selection, a trace operation does to every selected trace what it does to the one
under the pointer: Kill kills them all (Restore, over a killed trace, restores them all),
Reverse polarity reverses them all, or puts them all back when that trace is reversed.
Later: show headers (`H`) and, perhaps, a filter on one trace (as a layer of its own,
with the overlays).

### Edits to traces

Killing a trace and reversing its polarity are edits: lists kept per file, by the trace's
index in the file, beside the file and never in it (the file is opened read-only). A
killed trace is drawn blank (the plot's background, no wiggle); with "Hide killed traces"
(the gear popover, a setting) it is left out of the plot instead, and the traces beside it
close up: the record is laid out again without it, at the same scales and place, and
again with it when it is restored or the setting is turned off.
"Reverse polarity of all traces" is an edit of the file too: each file shows its own, and
another file opened in the same window is shown as it was left. Messages lists every
change.

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
before, and the next run that opens the file unchanged shows them and remembers them with
its identity (a file changed since does not take them: Messages lists them). Two viewSEG at once with
the same file open (two windows) lose none of each other's edits: before a write, the
entry's time is compared with the one read or written last, and another's change is
merged in (what either added or took away is kept), Messages says so, and the plot shows
the other's edits too. One file opened under two
paths in a run (a copy, a hard or a symbolic link) has one set of edits, those made under
each path kept, and one entry: at once when the two paths' size, ends and modification
time agree, otherwise once both are hashed whole; Messages says so, and a file taken so at
once whose hash then tells it apart loses only what it took. When a hash of every byte says
that a file taken at once for one remembered was another, the remembered file's entry is
put back as it was. An entry with parts that cannot be read (edited by hand) says so and
brings back the rest, and is not written again until its edits change (so as not to drop
those parts): when its file was opened is kept beside it (`<entry>.seen`), so that File
memory never lists a file in use as not opened for months; a later version's parts are
kept as they are. Edits an agent makes
through agent control are shown for the session only (docs/agent-control.md), marked so in
the row of edits.

**File > File memory...** lists what is remembered: the name a file was last seen under,
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

**Handing a list over.** File > Export > Trace edits... writes the edits of the file shown,
as remembered: an edit shown for the session only (agent control's) is left out, since a
list handed on outlives the session, and Messages says how many; one an agent hid for the
session is in it,
as a CSV table (`trace,record,channel,edit,file`: the trace's number in the file from 1,
its field record and channel from the headers, `killed` or `reversed`, "all" for reverse
all, and the name of the file the list is for on every row) or as viewSEG's own NIF
document (with the file's identity), for processing. File > Import > Trace edits... reads
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
nothing read from the file; the picture before stays until the new one is drawn (on the
Morgantown record, zoomed in on 40 traces, about 30 ms from the key under software
OpenGL). Otherwise only the view's tiles are made again. A kill, or a restore, also has
the record's level taken again, so that the gain leaves the killed trace out.

## Spectra

**FFT windows.** "FFT in a new window" (the plot's menu, or `F` over a trace) opens the
amplitude spectrum of the trace under the pointer, or of the selection when that trace is
in it, in a window of its own: titled by what it shows ("FFT: trace 37 · FFID 151 ·
shot.sgd", "FFT 2: 12 traces · ..."), floating beside the middle of the main window the
first time, dockable anywhere like every window. Several can be open; each is a snapshot
of the traces it was opened on and of the plot's filters then, and keeps it while the
plot moves on. Closing one (its ×) drops its work if it is still being computed. A
window's number is the lowest free one, so a window opened again takes the place the
layout kept for that number; a layout that names FFT windows not open loads without a
word.

**The live Spectrum panel** (Window > Spectrum; a tab behind the map in the first
layout) shows the same for what the Seismic window shows: the selected traces of its
file when there are some, else the traces in view (at most 4096, spread evenly over
them), over the visible time (or the whole trace). It follows the plot as you pan, zoom,
select, step to another record or file, kill a trace or change a filter, asking again
only when what it is of changed; an answer older than the one shown is dropped, and while
a pan goes on each newer answer is shown as it comes. **Freeze** keeps what it shows. It
works only while it is on screen: hidden, behind another tab or collapsed it asks for
nothing. A layout saved before the panel came keeps it hidden.

**What a spectrum is.** processSEG's spectrum (`SpectrumPlan`): each trace's window is
demeaned, tapered (a sin² ramp over 10 % at each end) and zero-padded to the next power
of two; amplitudes are one-sided and corrected for the taper, so a sine of amplitude A
on a bin reads A. Several traces are averaged over power (the RMS amplitude across them).
The frequency axis runs from 0 Hz to Nyquist (500 / interval in ms). Left out, and
counted in the window's line of words: killed traces, traces the file marks dead, traces
that cannot be read or hold a sample that is not a number, and traces at another sample
interval than the first. Auxiliary traces count as seismic ones do (a pilot's spectrum).

**Raw and processed.** The raw curve is the samples as the file has them; the processed
one the same samples through the plot's filters (Filters in the strip), run on whole
traces before the window is cut, also when the plot is shown raw, so the two compare. In
dB both are on one scale, 0 dB at the larger peak of the two (a filter's cut shows as
the gap between them); linear, in the file's sample units. The frequency axis can be
logarithmic (0 Hz is then left out). A spectrum of one trace has its phase too (Phase:
degrees, from the window's first sample, drawn under the amplitude).

**Time.** An FFT window is over the whole trace by default; "Visible time" takes the
time the Seismic window showed when it was opened (and the whole trace again when
unticked). The live panel is over the visible time by default. How a window shows its
spectrum (dB or linear, the axis, the curves, the time, the phase) is kept: a new FFT
window starts as the last one changed, and the live panel as it was left.

**Reading it.** The pointer over the plot puts a line at the nearest frequency and a dot
on each curve; the line under the plot reads the frequency and each curve's level there
("24.4 Hz   raw -3.1 dB   processed -40.2 dB"). The wheel zooms about the pointer, a
drag pans, a right drag zooms to a box, a double click shows everything again; no view
goes past the data. A click on a curve's name in the legend hides it.

**Off the screen's thread.** The spectra are computed by a reader of their own (`core/
spectrumreader`), which reads only the traces it does not already hold (as decoded, up
to 128 MiB: a pan reads the traces it brings into view; a filter, a time window or
another window of the same traces reads nothing), and gives up a request between blocks
of traces when a newer one of its window comes or the window closes.

**The plot itself** (`view/curveplot`, drawn by `ui/imgui/curveplot`) is a plot of named
curves over one axis, each in its colour with a legend, that can be drawn turned (the
axis down from the top and the values across, as a signal beside a seismic trace): the
vibrator analysis's plots (signal, spectrum, correlation, phase) are made with it.

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
| A filter's slider dragged | the plot follows while it moves: a new filtered tile each change the reader keeps up with (changes it has not reached are dropped), each of the view alone, from the samples at hand (no read). Measured with `tools/filterbench` (release build, software OpenGL under xvfb, on a 32-core machine shared with other work, load 20) on a 3954-trace, 4001-sample record dragging f2 of a band-pass over 600 frames: the whole record in density, frames 10.2 ms median, 12.5 ms 95th, a tile every frame; 723 traces of wiggles, 38.9 ms median, as a pan of the same view (38.8 ms: drawing that many wiggles on software OpenGL), a tile every frame; no read from the file |
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
