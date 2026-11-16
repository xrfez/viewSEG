# viewSEG quick start

viewSEG is a viewer for SEG-Y and SEG-D seismic data with quality-control tools. It needs
no installation and no internet connection.

**Status:** early development. The window, the File menu, the file list, the folders
below, and one record on screen as wiggles or greyscale density, with zoom, pan, gain,
sorting, trace highlighting, killing and reversing traces, and a cursor readout, work.

## Start it

1. Unpack the archive anywhere you can write to: your home folder, a project drive or a USB
   stick.
2. Run the program in the unpacked folder:
   - Windows: `viewSEG.exe`;
   - Linux: `./viewSEG`.

It needs a 64-bit PC with AVX2 (Intel from 2013, AMD from 2017) and OpenGL 3.3.

If it cannot start, for example because the graphics driver has no OpenGL 3.3, a message
box says what failed, and the same text is saved as `startup-failure.log` in the logs
folder (`viewSEG --paths` shows where it is).

## Open data

**File** menu, or the shortcuts:

| Action | Shortcut |
|---|---|
| Open file... | Ctrl+O |
| Open files... | Ctrl+Shift+O |
| Open folder... | Ctrl+Alt+O |
| Close the file shown | Ctrl+W |
| Quit | Ctrl+Q |

The whole list, including the plot, the map and the tables, is **Help > Keyboard
shortcuts** (F1), and in [Keyboard shortcuts](keyboard-shortcuts.md).

**Project**, between File and Edit, holds this job's folder: **New project...** makes
one, **Open project...** and **Recent projects** open one, **Project...** opens its
window (ticked while it is open) and **Close project** goes back to working without one.
The right end of the toolbar names the project that is open (its icon, then its name;
**(read-only)** when it is), or dim **No project** when none is. A long name is
shortened in the middle, and at a narrow window the name gives way and the icon stays.
Click it for the same items as the Project menu. Rest the pointer on it for the
project's folder and, in one line, how many survey files and data folders it holds. The
theme is changed from **View > Theme** and **View > Light / dark**, not from the
toolbar.

Files and folders can also be dragged from a file manager and dropped on the window.

**Survey files** (SPS source, receiver and relation files, `.s` `.r` `.x` or `.sps` `.rps`
`.xps`, and SEG P1 files) open the same ways: File > Open, a drop (several at once), the
command line. viewSEG tells them by what they hold, not by their name, and loads them into
the survey (on a job, with progress, in the Jobs window) instead of the Seismic window,
which stays on the file it shows. Messages says what each held ("Loaded land.r (SPS R):
96 receiver points.") and what was left out: records without coordinates or at (0, 0),
stations given twice (the last one is kept), damaged lines by number. A file that is not a
survey file, or a damaged one, is refused or read as far as it goes, and the program goes
on. Each open seismic file's source and receiver positions are read into the survey too,
and everything in the survey is drawn on the **Map** (below).

**File > Open recent** lists the files and the folders opened last (the start screen
shows the newest ones); the file dialogs start in the folder of the last file opened.

## Step through a folder

The **Files** window, at the left, lists the seismic files (SEG-Y, SEG-D, SEG-2) and the
survey files (SPS S, R and X, P1) of a folder with their type, size and date; other files
are counted at the bottom, not listed.
Opening a folder lists it and shows its first file; opening a file shows it and lists its
folder beside it. Listing reads only the first few kilobytes of each file, in the
background, so a folder of thousands of files lists without opening any of them.

- **Click a file** to show it in the Seismic window, in place of the one shown. The display
  (mode, gain, filters, sort order, display header) and the scales stay as they were, so records
  compare one after the other. **Click a survey file** to load it into the survey: a pin
  marks it once loaded (its tooltip says what it holds); the Seismic window stays as it is.
- **With the Files window focused** (click in it), **Up / Down** step to the next or
  previous seismic file and show it (survey files are passed by); **Page Up / Page Down**
  skip ten, **Home / End** go to the first and last. They do so wherever the focus is in
  the window, but in the filter box, which keeps its keys.
- **Tab / Shift+Tab** move between the window's controls, as in any window: the folder's
  drop-down, its two buttons, the filter, **Follow the latest file** and the list (one stop, at the file
  shown); **Space** or **Enter** acts on the control reached.
- **Filter by name:** type in the box over the table; only the files whose names hold
  every word typed are shown.
- **Sort** by any column: click its header (click again to reverse).
- The drop-down at the top lists the **folders opened before**; the buttons beside it open
  another folder and list this one again.

A file stepped away from is closed, so stepping through hundreds of files keeps one open.
Coming back to it is quick: its index is kept in the index cache (`viewSEG --paths`
shows where), so it is not read through again. The folder listed last is listed again at
the next start.

### Files that arrive while you look

The folder listed is looked at again about once a second, so files a crew or a copy
writes into it while you work appear in the list by themselves (no refresh needed):

- A file that **appeared** after the folder was listed is marked with a **dot** until you
  show it.
- A file whose size or time **changed** at the last look is marked with a **spinner** and
  its name is dimmed: it is being written. It stays listed, and you can click it to see
  what is there so far.
- A file that has stopped changing but **ends before its last trace** is marked with a
  warning sign: it is still being written (the writer paused), or it was cut short.
- The line under the table counts the new files and those being written.

By default the Seismic window **stays on the file you chose**. Turn on **Follow the latest file** (the
button beside the filter box, or **File > Follow the latest file**; it is remembered) to
show each new file as soon as it is completely written: its size has stopped changing
and it holds every trace it announces. A file still being written is never shown early;
each new file is shown once, so stepping back to an older one is not undone, and the
next new file is shown again.

**When the file shown changes on disk** (an acquisition system writes it again, or a newer
copy is put over it), viewSEG shows it again, as it is now, once it stops changing,
keeping the display, the record and the scales; kills and polarity reversals made on the
old file are set aside (Messages says so; Edit > Undo, Ctrl+Z, brings them back; they
stay remembered for the file as it was).
If the file was **cut short**, viewSEG stops reading it at once and says so in Messages.
On Linux and macOS one case remains: a file cut short by another program *while viewSEG is
reading it* (in the fraction of a second a pan, zoom or new record takes) stops viewSEG
with "Bus error". Do not copy over or truncate a file viewSEG is reading; copy the new file
in under a new name, or rename it into place (Windows does not let a program cut a file
another program is reading).

Looking costs little: a folder of 5 000 files is looked at in about 15 ms, on a thread of
its own; a slow network folder is looked at less often (ten times as long as a look
takes), and a folder that cannot be read for a while (a share that went away) is said
once in Messages and keeps its list.

### Files on a network drive

viewSEG never waits for a drive in its window: listing a folder, opening a file, reading
its traces and saving the settings all happen on threads of their own, so the window keeps
drawing, and every button works, however slow the drive is.

- **A drive that stops answering.** After 3 seconds without an answer viewSEG says so where
  you wait: in the Seismic window ("Reading shot12.sgd: not answering for 12 s"; the plot
  keeps what it showed), above the plot for a file being opened, and under the list in the
  Files window for a folder being listed or looked at. Each comes with **Cancel** (stop
  waiting: the picture stays as it is) and **Retry** (try the drive again). The status bar's
  job says it too. Meanwhile you can show other files, from other folders or drives.
  The **Headers** window says it above its tabs ("Reading shot12.sgd for the Headers
  window: not answering for 5 s") and keeps what it showed; pointing at a trace of another
  file reads that one meanwhile.
- **A drive that goes away** while a file is shown: the plot keeps the picture and says the
  file cannot be read now; Retry reads it again once the drive is back. The Headers window
  says so for a trace or a record it could not read; a file whose own headers could not be
  read as it was opened is open without them, and its Summary says why.
- **Quitting** never waits for a drive: the window closes within about a second, whatever
  is stuck. A read the drive still holds is left to end on its own.
- **A slow drive.** viewSEG times its reads; when they are slow it reads further ahead
  (three views on each side instead of one and a half) in larger reads, so panning finds
  its data on hand more often. **File > Prepare the next file** (on by default) opens the
  next file of the list in the background while you look at one: its index, and the
  samples of its first view, so the next step does not wait for the drive to be walked.
  Files larger than 2 GiB are not prepared.
- **The index cache** stays on your own disk (in the cache folder, `viewSEG --paths`),
  never beside the files, so a second visit to a file reads its index locally.
- **What can still stop viewSEG:** a file whose drive fails, or that another program cuts
  short, in the fraction of a second a read of it is under way ("Bus error" on Linux and
  macOS, a crash on Windows). viewSEG checks the file before each read and reads nothing of
  a file it cannot look at, but the read itself goes through parseSEG's memory map, which
  will guard such a fault in a later release.

## Step through the records of a file

A file often holds several records (shots, receiver gathers, CDPs). The Seismic window shows
one at a time; the **Records** window, under the file list, lists them all, one row each,
with what tells them apart (a shot's FFID and source station, a receiver gather's
receiver, a CDP), and its key information: its seismic **Traces**, its auxiliary traces
(**Aux**, when the file has any), the traces the file marks **Dead**, and the traces
**Missing** from its patch. Missing counts against what the file itself declares for the
record (a SEG-D record's seismic channel sets, a SEG-Y file's traces per ensemble) and,
once the survey's relation file (SPS X) is loaded, or imported for the file (File > Import
> Survey, below), against the stations its X record plans for the shot; the cell's
tooltip says which, and how many of the record's traces are at stations the plan does
not list. A record with traces missing is drawn
in the warning colour, and the footer counts them; where nothing says how many traces a
record should hold, the cell is empty. The record shown is highlighted. Click a column's
header to sort by it (again for the other way; **#** is the file's order): sorted by
Missing, the short records come first.

- **Click a record** to show it. With the Records window focused, **Up / Down** step to
  the next or previous one in the order shown, **Page Up / Page Down** by a page,
  **Home / End** to the first and last. A file of a hundred thousand records scrolls as
  lightly as one of ten. Tab steps no record (the list is the window's one control).
- **In the Seismic window:** **Page Down / Page Up** show the next or previous record,
  **Home / End** the first and last; the arrows in the strip do the same, and the number
  between them ("2 / 120") opens **Go to record** (also **Ctrl+G**): type a place in the
  file or a field record number (FFID) and press Enter.

The next record is shown at the same scales (the same traces and times in view, or the
whole record if the whole one was in view before), with the same gain and trace order,
so records compare one after the other.

## Jobs

Anything that takes a while (opening a large file, listing a folder) runs while you go
on working. The status bar shows the job running, how far it is and the time left, with
**Cancel**; click it (or the toolbar's Jobs button, or **Window > Jobs**) for the
**Jobs** window, which lists every job:

- **Running:** a progress bar for each, with Cancel.
- **Waiting:** in the order they will run, in two lanes: *foreground* for what you are
  waiting on (opening a file) and *background* for long work, so a long job never holds up
  an open. The arrows move a job up or down its lane; the bin takes it off the list.
- **Finished:** how each ended (done, failed and why, cancelled) and how long it took;
  *Clear the list* empties it (Messages keeps the record).

When a background job ends, a short notice appears in the bottom-right corner for a few
seconds; click it for the Jobs window.

## Look at a record

An opened file shows its first record in the **Seismic** window (a window is named for
what it shows): traces across, time down, as
black wiggles with their positive lobes filled, on white paper, with automatic gain (AGC
on shot and receiver records). Wiggles stay wiggles at every zoom: zooming out stops
where the traces are one pixel apart, so every trace in view is drawn. A shot of more
traces than the plot is wide (a few thousand, say) opens at that limit from its first
trace, with a scroll bar under the plot for the rest. To see a whole large record at
once, choose the density display (Greyscale density, in the strip), which zooms out until
the record fills the plot. Where the traces are only a few pixels apart, the wiggle line
is drawn thinner than a pixel (light grey), so the fills show the record as a
variable-area section rather than a band of lines. In wiggles the plot reaches a little past the first and the
last trace, as far as their swing goes (the trace overlap), so their whole wave shows; a
record of a single trace shows whole. The rows of labels over the traces are the display header (receiver line and
point by default): right-click them, or their names at the left, to choose its fields
(automatic, or the ones you tick); the gear button has the same choice.

| To | Mouse | Keys |
|---|---|---|
| Zoom in or out about the pointer | wheel | `+` / `-` |
| Zoom up and down only (time; the traces when time runs across) | Ctrl + wheel | Ctrl + Up / Down |
| Zoom across only (the traces; time when it runs across) | Shift + wheel, or the sideways wheel | Ctrl + Right / Left |
| Pan | drag with the left or middle button | arrows, the way they point (a tenth of the view; with Shift, a whole view) |
| Pan with a scroll bar | drag its thumb; click the bar for a whole view; or the wheel over it | |
| Zoom to a box | drag with the right button | |
| Fit the whole record (in wiggles: as far as one pixel a trace, from the first) | the fit button | Ctrl+0 |
| Go back to the view before | the back button | Backspace |
| Step the selection to the next or previous trace | | Alt+Right / Alt+Left (Alt+Down / Alt+Up when time runs across) |
| Select a trace | click it | |
| Add a trace to the selection, or take it out | Ctrl + click | |
| Select every trace from the one clicked last to this one | Shift + click | |
| Cancel a drag, else clear the selection | | Esc |
| Kill or restore the trace under the pointer (the selection, if it is in it) | right-click: Kill / Restore | `K` |
| Reverse its polarity, or put it back | right-click: Reverse polarity | `R` |
| Its amplitude spectrum (the selection's, averaged, if it is in it) in a window of its own | right-click: FFT in a new window | `F` |
| Undo the last kill, restore or polarity change | Edit > Undo (or right-click: Undo) | Ctrl+Z, in any window |
| Redo what was undone | Edit > Redo (or right-click: Redo) | Ctrl+Shift+Z or Ctrl+Y, in any window |
| See the traces without the filters, or filtered again | the strip's Raw toggle | `P` |

Keys act while the Seismic window has the focus: click in it first (undo and redo work
from every window, but in a text field, which keeps its own Ctrl+Z). The click that brings
a window forward does only that: it selects no trace, and in Files or Records it shows no
other file or record; click again to do so.

A new size of the Seismic window (its edge, the windows beside it, the main window) keeps
the scales and the top-left corner: what no longer fits is reached with the scroll bars,
and a larger window shows more. Only a window larger than the whole record at that scale
shows it larger, filling the plot.

**Display.** The display buttons in the strip choose how traces are drawn:
density, wiggles, or wiggles over density. Density is drawn only in the two modes that
name it. Changing from density to wiggles while more traces are in view than the plot
has pixels narrows the view to one pixel a trace, keeping its left edge. In the two wiggle
modes, the two after them fill the wiggles' positive
lobes (right of the trace; above it when time runs across) and negative lobes (left of
it; below it): either, both or none. In density those two are not drawn. **Overlap**, in
the gear's Traces tab, sets how far the strongest amplitudes swing a trace, in trace
spacings (1 reaches the next trace; anything stronger is clipped there): type a value, or
step it with - and +. It is greyed in density. The gear also holds the
**colours**: a swatch for each of the plot's six colours (background,
wiggle line, positive fill, negative fill, the trace under the pointer, selected traces),
always shown. Click one to pick a colour, or type it as `#rrggbb` and press Enter: the
plot becomes "My own" colours. **Paper** (black on white; negative fills red) and
**Follow the theme** put ready-made colours back; **My own** brings yours back. They are
remembered when you quit. Under them, **Density colour map** shows each map as its colour
bar: **Grey** (positive black), **Red-white-blue** (negative red, zero white, positive
blue), **Viridis** (dark purple to yellow) and **Red-black** (negative red, zero white,
positive black); click one and the density is drawn in it at once.

**Display presets.** The gear's Look tab keeps whole displays under names, under its own
**Display presets** heading below the Plot checkboxes: type a name and click **Save** to
keep the display shown (mode, fills, overlap, colours, colour map, gain and its settings,
clip); click a preset's name to draw the plot that way again (it stays turned as it is).
**Rename** and **Delete** act on the preset you clicked last. The presets are remembered
when you quit.

**Auxiliary traces.** When the record holds auxiliary traces (a time break, a pilot, an
uphole), two toggles in the strip choose what the plot shows: **Seismic** (on at first)
and **Aux**. With both on, the auxiliary traces stand in the file's order among the
seismic ones and the window is called **Seismic + Aux**; with Seismic off it shows the
auxiliary traces alone (**Aux**). One of them always stays on. The choice is remembered,
as the gain and the sort are: the next file, a new plot and the next time you start
viewSEG show the same traces, when the file has them. A file with no auxiliary traces
shows its seismic traces and leaves that choice as it was. The gain, the sorts, the
edits, the display header and the status bar work on them too.

**Filters.** The **Filters** button in the strip (a funnel, after the gain; lit while
filters are applied; its tooltip and the top of its drop-down say which) sets what the
traces go through before the gain, and the plot follows as you move a
slider:

- **DC removal**: none, the mean, or the mean and a linear trend of each trace.
- **Pass band**: none, **Low-cut**, **High-cut** or **Band-pass**, each by its corners in
  Hz: the low-cut ramp from f1 (nothing below) to f2 (everything above), the high-cut ramp
  from f3 to f4 (nothing above). A band-pass of 8-14-60-80 Hz, say, takes the slow ground
  roll out of a shot record. The sliders move finely at low frequencies; Ctrl + click one
  to type a value. They end at the file's Nyquist frequency; a corner past it (set for
  another file) is cut there, and the drop-down says so.
- **Notches**: **+ 50 Hz** or **+ 60 Hz** adds a notch at the power line's frequency and
  its next two harmonics (x3); **+ Notch** one of your own. Each has its frequency, its
  width (the notch is gone half the width away) and how many harmonics it takes, and can
  be turned off or removed.
- **Filter the Aux traces too**: off, the auxiliary traces are shown as recorded; on,
  they go through the same filters (a notch on a pilot sweep shows where it passes that
  frequency).
- **No filters** takes them all away.

The **Raw** toggle beside the drop-down (or `P`) shows the traces without the filters,
under the same gain, so you can compare; press it again for the filtered traces. The
filters stay on for the next record and file, and a new plot starts with the ones you
set last. Moving a slider never reads the file again: viewSEG filters the samples it
already holds, and only the traces and times you are looking at (and a little around
them), so it is as quick on a huge file as on a small one.

**The plot's menu** (right-click the plot) holds what acts on the data, and nothing about
how it looks. Its first line names what it acts on: the trace under the pointer, or the
selection when that trace is selected. Then:

- **Reverse polarity** (`R`): the trace's samples turned 180 degrees out of phase, before
  the gain, so the picture, the gain and the status bar's amplitude all see the reversed
  data. Ticked while the trace under the pointer is reversed; choose it again to put it
  back.
- **Kill** (`K`): the trace is drawn blank (the plot's background, in every display mode)
  and left out of whatever the gain computes over the record (Float, Normalized for the
  whole record, the automatic level), so a noisy trace stops setting the brightness. Over
  a killed trace the item reads **Restore**. To have killed traces left out of the plot
  altogether (the traces beside them close up), tick **Hide killed traces** in the gear
  popover.
- **Filter this trace...** (or **Filter N selected traces...** when the trace under the
  pointer is in a selection): the same frequency filters as the strip's Filters drop-down,
  in the same order and words, for those traces only. **Apply** sets them as one step.
  They run **after the plot's filters** (the usual choice) or **instead of the plot's
  filters**. **Apply** with nothing set and "After" takes the trace's filter away (no
  mark; if there was none, nothing is stored). "Instead" with nothing set is kept: the
  trace is shown without the plot's filters, and the mark says "No filter: the plot's
  filters are not applied". **Clear** empties the controls and puts the choice back to
  "After". **Cancel**, Escape, and a click outside close the popover without applying.
  **Remove the trace's filter** (or **Remove the filters of N traces**) is in
  the same menu, and only when one of the traces has a filter. Gain, AGC, sort and the
  display are still the plot's, not a trace's. A killed trace keeps its filter; the kill
  wins on screen (the trace stays blank).
- **FFT in a new window** (`F`): the trace's amplitude spectrum (of the selection: their
  average) from 0 Hz to Nyquist, the trace with its own filter and, when the strip has a
  filter on, through that filter too, in a window of its own (see "Spectra" below).
  Killed traces are left out.
- **Reverse polarity of all traces** (below).
- **Undo** (Ctrl+Z) takes back the last kill, restore, polarity change, trace filter or
  clearing (it names it), and **Redo** (Ctrl+Shift+Z, Ctrl+Y) makes it again, as far back
  as you have worked in this run; a new change drops what was undone. The same items are
  in the **Edit** menu, which works whichever window has the focus. **Clear all edits for
  this file** shows the traces as the file has them (Undo brings the edits back).

Edited traces are marked in a row of the display header, **edits**, that is there only
while the record has an edit: a red **K** over a killed trace, an **R** in the accent
colour over a reversed one, and the filter icon in that same accent colour over a trace
that has its own filter (red, with the **K**, when the trace is also killed). Hovering a
mark highlights it. The tooltip names the edit ("Killed", "Polarity reversed", or the
filter in words, "Band-pass 10-60 Hz, after the plot's filters") and ends with
"Right-click to remove". A right-click on the mark opens a small menu for that trace:
**Remove kill**, **Remove reversal**, **Remove the trace's filter**, and **Edit the
trace's filter...** when it has a filter. Each removal is one step (Edit > Undo brings
the mark back at once). When the trace has more than one edit, **Remove all edits of
this trace** takes them all away as that one step. If the trace is selected and other
selected traces have the same edit, the menu also offers **Remove kill from N selected
traces** (and the same for a reversal or a filter). Zoomed out, where the marks are thin
bars or share a pixel, a right-click on the row picks the nearest edited trace within a
few pixels; when several traces share the pixel the menu says **N traces here** and the
removals apply to all of them as one step. A right-click elsewhere is unchanged: the
plot's menu on the traces, the header's menu on its other rows.
The Headers window's trace table shows the same letters beside the trace number, and the
filter's words in its tooltip. A filter changed for this run only, different from the one remembered with
the file, has a star, as a kill an agent made does. The status bar says
"killed", "polarity reversed" or the filter's words for the trace under the pointer, and
Messages lists each change. Edits are lists kept beside the file, never
written into it: they hold through another record, a sort, a gain change, stepping to
another file and back, and the next run (see "What viewSEG remembers"). An edit shows at
once: viewSEG makes the picture again from the samples it already
holds, without reading the file.

**Polarity.** Right-click the plot and choose **Reverse polarity of all traces** to see
every trace 180 degrees out of phase; the item is ticked while it is on, and choosing it
again goes back. It reverses the data itself, before the gain, so the status bar's
amplitude is the reversed one too. It is an edit of the file: every record of it is
reversed, it comes back with the file, and another file is shown as you left it.

**Highlight.** The trace under the pointer is drawn in orange, line and fill (under
density, its column is tinted), and the status bar reads it out. Click a trace to select
it; Ctrl + click adds another or takes one out; Shift + click selects every trace from
the one clicked last to this one, in the order shown; Esc clears the selection. Selected
traces are drawn in the theme's accent colour (another of its colours where the accent
is too close to the traces). Nothing is read again for any of this.

**Gain.** The drop-down in the strip shows the gain, and its settings are in the same
list. The first row is a checkbox, **Let viewSEG choose**, ticked at first: AGC on shot
and receiver records, none on stacked data. Beside it, dim text says what that picks for
the record shown (**now: AGC 500 ms**, or **now: none, stacked data**). Untick the box
to pick the type yourself; ticking it again hands the choice back. Under a line, the six
types are radios, the one in use selected (the one viewSEG picked, while the box is
ticked; clicking a radio unticks the box and sets that type): **None** (the samples as
recorded, one scale for the record), **Fixed** (one scale for every record, so records
compare), **Normalized** (every trace, or the record, to the same level), **Exponential**
(more gain later in the record: dB per second, or a power of time, rising until the time
in its "until" box, 2 000 ms at first, and held after it, so the deep part of the record
is not blown out), **Float** (the scale follows what is in view) and **AGC**. The bar
says **Gain: AGC 500 ms** when you chose it, and **Gain: auto (AGC 500 ms)** or
**Gain: auto (none)** when viewSEG chose. At the bottom of the list, **Full scale at the
... th percentile** sets which amplitude is drawn at full scale (the colour map's ends:
black and white in grey; a wiggle's full swing): 99 % of |x| at first; 98 clips harder
(more of the record at full scale), 100 is the peak. Beside it stands the amplitude
that gives now. It never reads the file again. Beside the drop-down, the
gain amount in dB works with every type, from -300 to +300 dB: the box shows the unit
("+0.0 dB"; typing a bare number still works). Type a value, click - or
+, or press `]` and `[` (keypad `*` and `/`), 3 dB a step or 12 dB with Shift; the
buttons and keys repeat while held, and the picture brightens or darkens at once. A trace the file
marks dead is never drawn, whatever the gain: it is blank, like a killed trace, it does
not count in the brightness, and the status bar says "dead" over it.

The view never goes past the data: panning and zooming stop at the first and last trace
(in wiggles, past them by their swing) and at the record's start and end, and zoomed out
as far as it goes the record fills the plot (in wiggles, as many traces as the plot has
pixels). Whenever part of the record is out of view, a scroll bar shows how much and
where: under the plot for the traces, right of it for the time. The time axis shows the
times only; its unit is in the ms/in box (the gear's Scales tab) and in the status bar. Making the window larger
or smaller keeps the scale and shows more or less of the record, from the same top-left
corner, also when the whole record was in view.

**Components.** A record whose traces carry more than one component draws each trace
once, side by side as usual. The buttons tell the components apart by the value in the
headers (a SEG-D group index when that is set, otherwise the sensor type; a SEG-Y
identification code). The letter and the colour come from what the trace says it is.
A hydrophone is H, blue; a vertical, inline or crossline geophone is Z, X or Y, green,
yellow and teal. An accelerometer of those three directions uses the same letters and
colours, and the tooltip says accelerometer. A SEG-Y identification code 11..17 is
named the same way. When several components share one sensor, or none is named, the
buttons show the component number (1, 2, 3) and take those colours in order, green
first; any further one stays in the normal ink. The tooltip says what is known. In
density the colour map is unchanged and a thin band of the component's colour sits
along the top of each trace. All are on at first. Turning one off drops its traces
and lays the rest out again; the last one on stays on. While one is off, the
window's title says how many traces are hidden. The choice holds for the other
records of the file: what is switched off, so a component that first appears later
is shown. If every component of a record was switched off, they are all shown again
and a message says so. It starts again on another file. A record with one component is
unchanged: no buttons, the normal ink. The four colours are in the gear, on the Look
tab, under **Component colours**, with Reset.

**Sort.** The **Sort** drop-down in the strip puts the traces in another order. It says
what is in use ("Sort: Line/Station", "Sort: file order", "Sort: custom"). The list is
**File order**, then each preset: **Line/Station** (receiver line, then station), **By
Flag** (the same, with each station's components side by side, in order) and **By
Component** (the traces grouped by component, each group by line, then station). A preset
the file has none of the keys of is greyed, unless it is the order in use; picking the
one already in use does nothing. For an order of your own, click **Custom...**: pick
the header fields to sort by, the first first, each ascending or descending, and click
Sort (the drop-down then says "custom"; *File order* goes back). Sorting never changes the file, and the display header and
the status bar follow the order shown.

**Time across.** A checkbox under **Plot** in the gear's Look tab
turns the plot: time runs from left to right, with its values along the bottom, the
traces are stacked from the top down (the first at the top), and a positive amplitude
swings up, as signals are drawn; click it again for time downwards. The plot shows the
same traces and times after the turn and reads nothing again; everything follows it:
the display header stands in columns left of the plot, time's scroll bar is under the
plot and the traces' at its right, the scale boxes measure along the new directions, the
mouse and the keys act the way you see (the arrows pan the way they point, Ctrl + wheel
zooms up and down), and the strip's mode and fill symbols turn too. Each plot window
keeps its own orientation, and viewSEG remembers it for the next plot.

**Cursor time line.** A checkbox under **Plot** in the gear's Look tab turns
on a thin line from the pointer across to the time axis (down to it when time runs
across), with the pointer's time written at the axis, so a time can be read off against the tick values, and the display
header's values of the trace under the pointer, each in a box over its row (also where
the rows are thinned because the traces are close). It follows the pointer and goes when
the pointer leaves the plot; viewSEG remembers whether it is on.

**Scales.** The two boxes at the top of the gear's Scales tab state the zoom as traces per
inch and ms per inch. Type a value and press Enter to set it; zooming any other way updates
them. Below them, the gear switches to per cm, or time as inches per second, and calibrates the
screen: the scales assume 96 pixels per inch times the display scale until you enter the
monitor's diagonal or make a bar on the screen as long as a ruler held to it says.

**Readout.** The status bar along the bottom reads out what lies under the pointer: the
time, the trace and channel, receiver and source line and point, FFID, offset, the
amplitude as displayed, and the record's UTC time; and, whatever the fields, "dead" for
a trace the file marks dead, "killed" or "polarity reversed" for an edited trace. The
**raw amplitude** (the sample as the file has it, before polarity, edits and gain) is
one of the fields you can add; it is off until you do. Right-click the status bar to choose the fields
and their order.

## The map

The **Map** window (right of the plot at a first start; Window > Map brings it
forward) draws the survey: each survey file's **sources** (the theme's red) and
**receivers** (its blue, or its green where the blue is the selection's colour, as in
Everforest; another of its colours where those would be hard to tell apart) as dots, the open file's own
source and receiver positions (from its trace headers) as rings round them, so where the
headers and the SPS agree each dot sits in its ring. North is up, one foot (or metre) is
as long across as down, and nothing is fetched from the internet: there is no basemap.
Dots get smaller as you zoom out, so lines of stations stay lines; a million points draw
at once (the map draws a point per pixel or two of what is there, and every point once you
zoom in).

The gestures are the plot's:

| Input | Action |
|---|---|
| Wheel, or `+` / `-` | Zoom about the pointer (the map never zooms out past the whole survey) |
| Left or middle drag | Pan |
| Right drag | Zoom to the box |
| Arrows (Shift: a whole view) | Pan |
| Ctrl+0, or the fit button | The whole survey |
| Backspace, Alt+Left, or the back button | The view before |
| Point at a dot | What it is: source or receiver, line and point, coordinates and elevation, its file, the traces of the open file recorded there and their records, and for a source, the field records the relation (X) file gives it; **its traces light up in the plot** |
| Click a source | Show its record in the plot; a ringed source (its record is in a file of the folder listed) shows that file |
| Click a receiver (Ctrl+click: any dot) | Select it and its traces (Ctrl: add it, or take it out) |
| Shift+click a dot | Select the stations of its line from the dot you clicked last to this one |
| Shift+drag | Select every dot in the box, and their traces (Ctrl+Shift+drag adds) |
| Ruler, then left drag | Measure, as Ctrl+drag does. The button stays on until clicked again; clicking it while it is on takes the line away. A click without a drag still selects |
| Ctrl+drag | Measure, and turns Ruler on (the button lights): the distance and the grid bearing, until Esc or until the button is clicked off |
| Right-click a dot | Show its record (a source), select it, add it to the selection or take it out, hide its layer |
| Esc | The drag going on, else the ruler, else the selection |

The **status bar** shows the pointer's coordinates in the survey's unit, named exactly:
`m` (metres), `ft` (international feet) or `ftUS` (US survey feet), as the SPS header says
it (H20, and H201's factor: `feet` with 0.3048006096 m a unit is US survey feet), else as
the seismic file's headers say, else as you confirmed it when importing the survey; where
nothing says,
"units" (never a guess). A **scale bar** and a north arrow stand in the map's corners; the
axes show no values. **Ruler** in the strip (after zoom, before the gear) turns measuring
on: drag on the map for the distance and the grid bearing, in the unit the gear's Lengths
shows (m, ft, ftUS; the survey's own number, with no unit, when nothing says what it is).
The button lights in the same colour as the other on toggles, and stays lit until you
click it again. Clicking it while it is on takes the line and its reading away, and the
next line starts fresh. Ctrl+drag measures too, and turns Ruler on, so the button lights
whichever way the line was started. Esc takes the line away and leaves the button on.
The gear's **Lengths** shows the scale bar's and the ruler's lengths
in another unit instead, converted exactly (1 ft = 0.3048 m, 1 ftUS = 1200/3937 m).

**Layers** in the map's strip lists the layers in two groups, each with its own tick:

- **Preplot**: the survey files (SPS, SEG P1), what the survey planned: each file's
  sources and receivers (dots);
- **Recorded**: what the seismic files say of themselves: each open file's own sources and
  receivers, as its trace headers give them, or as a join made them ("(joined)"), as rings.

Under the Preplot, **Template box** (off until you tick it) draws the box round the spread
planned for the record on show (dark, with its X record and how many receivers it plans)
and for the source under the pointer (orange): the receivers the relation (X) file plans
for that shot. For a file of receiver gathers it is the shots the O records plan for the
receiver. With no relation file loaded, give the template there (lines × stations, or a
distance box along and across the receiver lines): the spreads are generated from it and
the box says **Generated**.

Under the Recorded, **Shots in the folder** rings the survey's sources whose record is in a
file of the folder listed in Files (read in the background, while a survey file with
sources is loaded): point at one and its description names the file; click it and the plot
shows that file at that record. The list says how many of the survey's sources have a file;
a folder listed again is not read again (what was found is kept with the index cache).

Under **Filters: the record shown**, tick what to mark on the map in the record shown, each
in its own colour, with its count beside it: traces **dead** in the headers, **not
decodable**, **killed**; **noisy**, **clipped**, spiky, constant, weak, DC offset, all zero,
not a number (processSEG's amplitude checks, default thresholds); stations **missing from
the template** (planned in the X file, no trace in the record), traces **not in the
template**, stations **recorded twice**; auxiliary traces, traces **without a position**,
**reversed** ones; and the shots whose X record stands out from its template (**spread not
the template**). Hover a filter for what it counts; **Select** selects its traces in the
plot; point at a ringed receiver and its description says which filters mark it.

![Land sample, field record 3: the template box of X record 3 (96 receivers planned), filters on](../images/land-map.png)

Untick a group to hide all of it (its layers keep their own ticks, greyed out, for when it
comes back), or a layer to hide that layer alone; the highlight (the record on show, the
selection, and the source and receiver of the trace under the pointer in the plot) has its
own tick, and a hidden layer's points are not highlighted either. The groups you hide are
remembered. The gear chooses where the description of the dot under the pointer goes: in
a box beside the pointer (the default), or in a strip along the map's bottom.

### The plot and the map, linked

Move the pointer over a trace in the plot: its **source and receiver light up on the map**
(orange, the plot's hover colour). Move it over a receiver on the map: **its trace lights
up in the plot**, in the same colour; over a source, its whole record does. The record on
show is always marked on the map: its receivers in a darker shade (the spread it was
recorded on), its source larger and outlined. With the pointer on a trace, `M` selects its
receiver on the map (the plot's right-click menu has it too). Try it on the land sample:

```
bin/viewSEG samples/land/shots.sgy samples/land/land.?
```

Record 1 of 6 opens (FFID 1, source 2001:101, 96 traces). The map draws two receiver
lines and the six sources, and the scale bar reads ftUS. Field record 3 has one dead
trace; its template box, once ticked, reads "X record 3: 96 receivers planned".

The positions come from the trace headers' coordinates, or from the survey files by the
stations the headers name (line and point); a trace whose headers give only its record
and channel finds its stations through the relation (X) file. When nothing lights up, the
**status bar says why**: a trace with no place on the map (an auxiliary trace, a station
no survey file has), a receiver no trace of the open files was recorded at, or a source
whose traces are all in other records. Once the survey is **imported** for the seismic
file (below), a survey file's dot also lights up the traces whose headers name no station.

The **Plot and map** layout (Window > Plot and map) puts the plot and the map side by side,
as large as each other.

### Import a survey

Field records often carry stations, or only record and channel numbers, and no
coordinates. **File > Import > Import survey** imports the survey: its files are put on the
map (as File > Open puts survey files there) and its stations are matched to an open
seismic file's traces, so that each trace has its source's and receiver's coordinates
(and its stations, offset and midpoint): **in memory only, the file itself is never
changed**. The **Import survey** window goes in the order of the work:

- **Survey files**: those loaded, ticked (untick one to leave it out); **Add files...**
  adds SPS files (S, R, X), SEG P1 files, or a **CSV table** of stations, with columns
  line, point (or station), x (or easting), y (or northing), and index, elevation and a
  kind column (S or R) where you have them; a table without a kind column is all sources
  or all receivers, as you choose beside it. Below, the units the survey's coordinates are
  in, as the files' headers say: read as soon as a file is chosen (added, dropped on the
  window, or loaded already), from its first 64 KiB only, so a file on a slow drive holds
  nothing up. SPS: H20 and H201 (`feet` with 0.3048006096 m a unit is US survey feet,
  0.3048 international feet); SEG P1: H2000; a CSV table: a comment before its first row
  (`# units: US survey feet`) or a unit in brackets in a column's name (`x (ftUS)`,
  `Easting [m]`). "The SPS headers say ..." is written under the box; files that say
  different units are named in a warning, and the first is taken.
- **Seismic file**: the file whose traces the survey is matched to, the one the plot
  shows (or another open file), the units its headers give its coordinates in, and its
  coordinate reference system as the file gives it (SEG-Y Rev 2 stanza, SEG-D Rev 3
  location data), when it has one.

You enter a unit **once at most**. The survey's box starts at what its headers say; the
seismic file's at what its own headers say, but where they say nothing, or only "feet"
(a SEG-Y file's measurement system cannot tell international from US survey feet), it
takes the survey's unit, and a dim line says so ("The headers say feet; taken as US
survey feet, as the survey says"); a CRS in the file that names its unit (US survey foot)
settles it too. Only units that cannot both be right (metres against feet) are a warning.
You need not wait for the reading: a unit you did not choose is taken from the headers
as the import reads the files. **Confirm, or correct** when the headers are wrong: a unit you choose is kept for the
session, for those survey files (or that seismic file), and no later reading replaces it;
it is shown as "(yours)", a survey of other files shows what its own headers say, and
**As the headers say**, the first entry of the dropdown, takes your choice back. Choosing
another file in the seismic file's box shows that file's unit. Nothing is converted; the units label the map's scale bar and the
status bar's coordinates.

**Options** (remembered): **Use the trailing digits of line names** (SPS 1.0 and P1 files
name lines with text: `CLT4960` is line 4960), **line names as numbers** (`name = number`,
one per line, for names without digits), **several channels per station** (X records whose
channel increment covers each station's components), **coordinates the headers give**:
kept, filling only those the headers lack (the default), or replaced by the survey's
(coordinates at (0, 0) count as none when every coordinate the headers give is (0, 0)),
and how the Records window matches a record and its traces to the X records (automatic by
default).

Press **Import**. The SPS and P1 files not on the map yet are loaded onto it, and the
survey files are read and matched to the traces while the plot goes on; only then, for
the moment the keys change, the plot lets go of the file (it keeps its picture), and it
shows the record again with the survey's values. A file already on the map is not loaded
twice. A map that showed all it had shows the whole survey then; one you zoomed in stays
where it is. **Cancel** (beside the progress, or in the Jobs window) leaves the file and
the map as they were. With no seismic file open, Import puts the survey on the map only
(open a file and import again to match its traces). A CSV table's stations are matched,
not drawn on the map yet. The window then says what the import did, in plain words, and
Messages keeps it:

- how many **source and receiver points** are on the map, from which files;
- how many seismic traces **matched** the survey (their source and receiver stations are
  in it) and how: by the stations in their headers, or by record and channel through the
  relation file;
- how many did **not**, and **why**: the headers' lines are not the survey's (a numbering
  a hundred times larger, say), line names that are text (turn on the trailing digits),
  record numbers that are not in the relation file;
- what became of the coordinates the headers gave (kept, and how far they are from the
  survey's; or replaced);
- what the survey files' headers say of the datum, the projection and the units.

**Select unmatched traces** selects the traces the survey has no source or receiver
for, in the plot and on the map (and shows their record when the one on show has none).
Values from the survey are drawn in the accent colour in the display header over the
plot, in the box of header values at the cursor, and in the status bar (the offset, the
stations, the coordinates); their tooltip says they came from the survey. The map shows
the file's own sources and receivers at the survey's places, and the Records window
checks each record against the survey's relation records. A file closed and opened again
is read as it is on disk: import the survey again (the window keeps your files and
options).

```
bin/viewSEG samples/land/shots.sgy samples/land/land.?
```

then File > Import > Import survey, Import (or open only the record, and choose the three
files with Add files...): 6 source points and 96 receiver points are on the map, and all
576 seismic traces match by the stations in their headers. The coordinates the headers
give are kept: they are the survey's. Messages quotes the SPS headers: NAD83, Texas
South Central, US survey feet, factor 0.3048006096. The file itself is never changed.

## Spectra

**FFT in a new window** (right-click a trace, or `F` over it) opens its amplitude
spectrum in a window named for what it shows ("FFT: trace 12 · FFID 1 · shots.sgy");
over a selected trace, the selection's, averaged ("FFT 2: 12 traces ..."). Open as many
as you like and dock them anywhere. Unless **Freeze** is on, a window follows the Seismic
plot: it shows the traces it was opened on until the plot changes, then the selection in
the record on show, or the traces in view when nothing is selected, and a new record or
file. Freeze keeps those traces and that file; the title names them ("Frozen · trace 12 ·
FFID 1 · shots.sgy"). Unfreezing follows at once.
Two curves: **raw**, the trace with its own filter (before the strip's filters), and
**processed**, through the strip's filters only (a band-pass shows as the processed
curve falling away outside its corners, a notch as a dip at its frequency). A trace's
own filter is always in the raw curve: there is no box that leaves it out. The window
names it where it names the trace ("Trace 12: own filter, band-pass 10-60 Hz"; of
several, "N traces have their own filter"). Where that filter runs instead of the
strip's, the processed curve equals the raw one, and the line says "this trace uses
its own filter instead of the plot's". **Response** is the strip's filters' response,
and only when the strip has a filter on. The live panel asks again when a trace it
shows gains, changes or loses its filter. **Processed** and **Response** are drawn
unticked, and will not toggle, while no filter is on in the strip; an own filter
alone does not unlock them. Your choice is kept and shows again as soon as a strip
filter is. In dB both
are on one scale (0 dB at the larger peak, whose amplitude the window's line of words
gives, so that two windows compare); **Linear** shows the amplitude itself (a sine of
amplitude A reads A). **Log frequency** spreads the low frequencies out. **Visible time**
takes the spectrum over the time the plot shows, instead of the whole trace (frozen,
over the time it was frozen on). For one trace, **Phase** (with the curves) draws its
phase under its amplitude. The picture is **Unwrapped** at first (the phase joined up
along frequency); **Magnitude 0-180** (the absolute value, on a fixed 0 to 180 axis),
**Signed +-180** and **Delay removed** are the other choices. Where the amplitude is
more than 60 dB below the peak the phase is left out, so the noise outside a sweep's
band is not drawn. A sweep's phase climbs steeply because its delay grows with
frequency; for vibrator QC, read the phase against the pilot in the vibrator signature
plot. The same line, in the same order, is on an FFT window and on the live Spectrum
panel; the **Freeze** pin sits at the right of its first row. Its tooltip is "Freeze:
keep these traces while the plot moves on". Point at the plot: the line under it reads
the frequency and each curve's level, and, when the phase picture is not the signed
one, the signed value in brackets. The wheel zooms, a drag pans, a double click shows
it all again. The window's line of words says how many traces were averaged and what
was left out (killed, dead, unreadable).

**Window > Spectrum** is the same, docked and live (a tab beside the map at first): the
spectrum of the selection in the record on show, or of the traces in view when nothing
is selected, over the time it shows, updated as you pan, zoom, select, change record or
file, or move a filter's slider. A selection left in another record does not keep it
there. The line is three groups: the scale (**dB**, **Linear**, **Log
frequency**), the curves (**Raw**, **Processed**, **Response**, **Phase**) and **Visible
time**; groups wrap whole. The **Freeze** pin, at the right of the first row, keeps the
traces and the file it shows; the line under the controls names them. Unfreezing follows
at once. It costs nothing while it is hidden
or behind another tab.

## Headers

The **Headers** window (Window > Headers) shows what the file in the Seismic window
holds, read-only, in four tabs:

- **Summary:** what the file is, in plain words: its standard and revision, byte order,
  textual header's character set, sample format, how many traces and records, the field
  record numbers, samples per trace, sample interval and record length, the coordinate
  units and reference (as File > Import > Survey shows them; after an import, the units
  you confirmed there, and the import: its files, how many traces matched, what it did);
  **How it was opened**: the standard read as (detected, or as you chose, with what
  detection says), whether its index came from the cache, from a sample of 64 headers (a
  fixed-length SEG-Y file) or from every header, whether it is read mapped or unmapped
  (a file on a network share is read unmapped, so a drive that fails fails only that
  read), and the options it was reopened with; a **Precision** line when its samples hold
  more digits than viewSEG shows; then the record shown (what tells it apart: FFID,
  source, receiver) with its counts (traces, seismic, auxiliary, dead, missing: the
  Records window's), and for SEG-D that record's channel sets. A unit you chose by hand
  in File > Import > Survey is said as such.
- **File headers:** a tab per header block, as the format has them. SEG-Y: **Text** (the
  textual header's 40 lines of 80 characters), **Binary** (the binary header's fields) and
  **Extended** (the extended textual headers, when the file has them), and a tape label or
  data trailer when it has one. SEG-D, of the record shown: **General** (its general
  headers, typed blocks included), **Channel sets** (one column per channel set, so they
  compare at a glance; 64 side by side, with Previous and Next for a record with more), and **Extended**, **External**, a skew or a trailer when the record
  has them, shown as their bytes (offset, hexadecimal, text). SEG-2: **File**. A SEG-Y
  file's extended textual headers also have **Stanzas** (each stanza by its name: its
  text, or a binary one's bytes) and **User data** (each attachment's label, format,
  description, creator and bytes) when they hold any.
- **Trace:** the selected traces (in the plot, or a receiver's on the map), or, with none
  selected and **Follow the pointer** on (the default), the trace under the pointer in the
  plot (or the traces of the receiver under it on the map); the trace pointed at last
  stays while you move to the Headers window. A line at the top says which traces these
  are. **Header** lists every header field of each trace (extensions included): its
  description, a value column per trace (at most 32 side by side) and its bytes, and the
  fields whose values differ between them in the warning colour. After a survey import
  (File > Import > Survey), the table starts with **From the survey**: the stations,
  coordinates, offset and midpoint the survey gave, in the accent colour for each trace it
  gave them to ("from the survey, not the trace header" when pointed at); the
  header's own fields follow, as the file holds them. **Data** lists the
  samples: index, time in ms and a column per trace, as the file holds them, or **As
  displayed** (after kills, polarity reversals, the trace's own filter and the gain's
  processing: what the status bar's amplitude reads); the row at the time under the pointer in the plot is marked and
  kept in view. A line says so when the file gives no sample interval (the times then
  count samples, 1 ms each) or a trace has no samples.
- **Trace table:** a row per trace of the record shown, or of **The whole file**, with
  the header fields you choose as columns (**Columns...**: the keys the plot and the map
  use, layout-aware inline and crossline and the values a survey import gave included,
  then every field of the traces, with a filter to find one). Click a column's header to
  sort by it, again for the other way; **Find** keeps the rows whose chosen column holds
  a value (`1001`) or a value in a range (`1001..1010`); **Graph** draws a column along
  the rows above the table, the rows in view shaded. The rows are linked with the plot
  and the map: point at a row and its trace lights up in both, click to select it
  (Ctrl+click adds or takes away, Shift+click selects a range), double-click to show its
  record; selected rows are marked, and so is the row of the trace under the plot's
  pointer. Right-click a row to copy it or every row read. Only the rows on screen are
  read; a column you sort, find or graph by is read whole once, in the background (a
  million traces scroll at frame rate).

Above each header table, **Find** keeps the fields whose description, name or value holds
what you type (**Clear** brings them all back). Click a value to see its field's bytes
below the table: its block in hexadecimal and as text with the field's bytes
highlighted, and those bytes read every way a header could hold them (whole numbers
big- and little-endian, signed and not, IEEE and IBM floats, BCD, text), so a value read
in the wrong byte order or format shows what it would be; click it again to hide them. A
SEG-D field that takes only some nibbles of its bytes (the day of the year starts at the
low nibble of a byte) lights those nibbles, not the bytes, and is read as those nibbles.

The header tables list each field's **Description** (cut to fit a narrow window: point at it
to read it whole), its values and its **Bytes** (in its block, from 1, as the standards
number them); right-click a table's header row to show its **Name** (as
parseSEG and header patches name it, `trace.sourceX`) or its file **Offset**, or to hide
one. Right-click a value to copy it, its column or the whole table (Ctrl+C copies the value
with the keyboard's focus on it; a copy of the Data tab takes 200 000 samples at most: of a
longer table its first rows, as the menu item says); right-click a Summary line to copy it or the whole
summary. The tab shown, the toggles and the columns are remembered. Headers and samples
are read in the background, only for the tab on screen, so the window never holds up the
rest; the file is never written (changing header values will be a separate, explicit
action).

### Reopen with options

When a file is read wrongly (not recognised, or taken for another standard; a 20-bit SEG-D
or SEG-2 file whose traces look like noise with spikes), **File > Reopen with options...**
(or the button at the top of the Summary, which also says when a file is not recognised)
opens it again with other options: its **Standard** (Detect, SEG-Y, SEG-D, SEG-2), **Check
every trace header** (slower; reports headers that disagree with the binary header),
**Two's-complement mantissas** (SEG-D format 8015, SEG-2 format 3), how it is **Read**
(Automatic: a network share unmapped; Mapped; Unmapped) and the folder of a multiplexed
SEG-D file's demultiplexed copy. Point at each for what it does. **Reopen** reads the file
again in the windows that show it, at the record they show; its kills and polarity
reversals stay, and so do the selection, the FFT and plot windows of its traces, and the
survey join, when the file has as many traces as before (the join is matched again:
Messages say it was kept once that match succeeds, or that it was dropped and why if it
fails or matches none of its traces; with another count the Messages say what was
dropped). The file is opened first and replaces the one shown only when it has traces: if
the options read it as nothing (a SEG-Y file named SEG-D), the file stays as it was, one
message says why, and the options are not kept. The options hold for that file until
viewSEG quits. **Defaults** puts every option back. A file opened with options says so:
its Seismic window's title and a line above the plot ("Opened as SEG-D · every header
checked"; hover it for the full words), and its tooltip in the Files list. Its shots on
the map are read with the same options. The file is only read, never changed.

**Help > About viewSEG** gives viewSEG's version and those of parseSEG, processSEG, Dear
ImGui, SDL, the OpenGL driver and the compiler, with **Copy** for a bug report.

## Messages

The **Messages** window lists what viewSEG has to say, newest last: files opened, problems
found in them (with the record, trace or header field and the byte offset; hover a line
for all of it), jobs that failed. Its strip:

- **The three counts** (information, warnings, errors) are toggles: click one to hide or
  show those lines.
- **Auto-scroll:** on, the list follows new messages; off, it stays where you scrolled.
- **Copy** puts the lines shown on the clipboard (right-click a line to copy only it).
- **Clear** empties the window; the session's log file keeps everything.
- **Export messages...** writes every message to a text file of your choice (never over a seismic
  file viewSEG has open or lists: it refuses, and says so), as File > Export > Export messages...
  does.

Click a message that names a trace (a damaged trace, say) to see that trace: its record is
shown in the Seismic window with the trace selected, and its file is opened again if you have
stepped away from it.

## Themes

View > Theme lists every theme that comes with viewSEG (Omarchy's, but two whose
licences do not allow it to be shipped, and Everforest Light), dark ones first, each with a swatch of its background, text and accent colours.
Rest the pointer on one and the whole program is drawn in it; move to another to compare;
close the menu (Esc, or a click elsewhere) to go back, or click one to keep it. **Follow
system** (the default) uses Everforest Dark or Everforest Light as your desktop is dark or
light; View > Light / dark switches between those two. Your own themes go in the `themes`
folder of the settings folder: `assets/themes/README.md` says how, and how viewSEG keeps
every theme readable. The seismic colour maps do not change with the theme.

## What viewSEG remembers

Everything you set is kept for the next run, in `settings.nif` in the settings folder
(`config/` next to the program, or the folder `viewSEG --paths` names): the theme, where
the window was and its size, the recent files and folders, how the plot looks (display
mode, fills, overlap, colours, the gain type and amount and every setting of every gain
type, also the ones not in use: the AGC window, Fixed's amplitude, Normalized's choices,
Exponential's rate, power and cutoff; the sort order and the display header: a new plot
starts as you left the last one; polarity is not kept), the cursor
time line, scale units and screen calibrations, the status bar's fields, the sort presets
and your own sort keys, the Messages window's toggles, and the Headers window's tabs,
toggles and columns. It is saved a second after a change and when you quit.

**Layouts.** The windows open where they were when you quit, the hidden ones hidden
(`layout.nif` beside the settings). The **Window** menu arranges them:

| Window menu | What it does |
|---|---|
| **Reset the windows** (Ctrl+Shift+R) | every window shown and docked in the main window, as at a first start; the main window is brought onto a screen if it is off every one |
| **Bring all windows onto this screen** | the windows you dragged out of the main window, wherever they are (another screen, a screen that is gone, past a screen's edge), and the main window itself, wholly onto the screen the main window is on |
| Seismic, Files, Records, Map, Headers, Jobs, Messages | ticked while shown; a click on a window in sight hides it, on one hidden (or behind another tab) shows it in front; the Seismic window is always shown |
| Wide plot, Side by side, Plot and map | the presets that ship with viewSEG |
| Load, Save layout as... | your own layouts: saved under a name, loaded again (a layout file is written and read under File > Export and File > Import) |

A layout saved before a window existed (before the map came, say) docks that window beside
its neighbours, and shows it. A window a layout puts off every screen (left on a monitor
that is not plugged in now) is brought onto the main window's screen, and Messages says so;
so is the main window, when its place is off every screen (it opens in the middle of the
primary screen) or larger than any screen (it is made to fit the screen it was on).

**When the menus cannot be reached** (the main window somewhere you cannot see it, say),
start viewSEG with `--reset-windows`: the windows are as at a first start (every window
shown and docked) and the main window opens in the middle of the primary screen at its
default size. Every other setting stays as it is, and the arrangement is saved as usual
from then on. Ctrl+Shift+R does the same in a running viewSEG, if the main window has the
keyboard. Deleting `layout.nif` in the settings folder also works, with viewSEG closed.

**Your kills, polarity reversals and per-trace filters are remembered with each file**, by what the file
holds, not by its name: rename or move a file, open it again (in this run or the next),
and its edits are back, as Messages says. A copy with one byte changed is another file
and gets none. They are kept in `files/` in the settings folder, one small file per data
file; the data file itself is never changed. What you undo and redo is for this run
only: the next run starts with the edits as you left them, and nothing to undo. Edits an
AI agent makes through agent control are not remembered.

**File > File memory...** lists what is remembered: each file's name when you last saw
it, when you last opened it, what is kept, its size, the entry's size, and whether the
file is still where it was. Remove the entry you select, those not opened for a number of
days, or those whose file is gone: each asks first, listing what goes, and Messages names
each one. **File > Export > Trace edits...** writes the edits of the file shown as a CSV
table (`trace,record,channel,edit,file`, for a processing system) or as viewSEG's own `.nif`;
**File > Import > Trace edits...** takes either back in (here or on another computer;
one step that Undo takes back).

**File > Export > Settings...** writes them to a file of your choice (to keep, or to take
to another computer), **File > Import > Settings...** takes such a file in (what it does
not hold stays as it is), and **File > Reset the settings** puts them back to the defaults
(the recent files and the window's place stay; the settings before are kept in a copy).

Every import is under **File > Import** (a survey, settings, a layout, trace edits) and
every export under **File > Export** (the messages, the settings, the layout, trace
edits), each in that one place.

`settings.nif` is a text file (NIF) you can read and edit while viewSEG is closed. If it
is damaged, viewSEG says so in the Messages window, moves it aside as
`settings.nif.<date-time>.bak` and starts from the defaults; a setting it cannot use (a
typing mistake, say) keeps its default, with the line it is on, and a copy of the file as
it was is kept the same way. If the file can neither be read nor moved aside, viewSEG
leaves it as it is and saves no settings in that run, saying so. A release folder may carry a `config/settings.nif` of site
defaults: settings a user has not set come from it.

## The folders next to the program

| Folder | What it holds |
|---|---|
| `config/` | your settings, and your own vendor header maps in `config/vendormaps/` |
| `logs/` | one log file per session, with every message of the Messages window; the newest 20 are kept |
| `vendormaps/` | the vendor header maps that ship with viewSEG |
| `assets/` | themes, fonts, colour maps and layout presets |
| `licences/` | the licences of viewSEG and of the software it includes |
| `docs/` | this guide |

While `config/` exists and can be written to, viewSEG keeps everything inside its own folder
(portable mode). Without it, viewSEG uses your per-user folders; `config/README.md` lists
them.

## Command line

```
viewSEG --version         the version
viewSEG --paths           the folders in use (settings, logs, cache, assets, vendor maps)
viewSEG --help            the options, each with what it does
viewSEG --reset-windows   start with the windows as at a first start (see Layouts)
```

On Windows these print only when the output is redirected, for example
`viewSEG.exe --paths > paths.txt`.

## Vendor header maps

Manufacturer-specific header blocks are decoded by vendor header maps (`*.nif` files). Put
your own in `config/vendormaps/`; `vendormaps/README.md` explains what they are.
