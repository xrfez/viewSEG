# References

A reference is one trace of samples: a vibrator pilot or a sweep, with a name. A
cross-correlation always uses the one chosen here. A vibrator signature uses it instead
of the file's pilot when one is chosen.

**Analysis > References** holds two items.

## Generate a reference

**Generate a reference...** makes a sweep and stores it. The dialog is resizable; the
two plots take the extra room, and it does not shrink so far that the settings, the
plots or the buttons leave the window; a long dialog scrolls. The settings are in four groups.

**Sweep.** The name (a default is filled from the parameters, such as "Linear 8-80 Hz
8 s"), the start and end frequency (Hz), the length (ms), the sample interval (ms; the
file on show, when there is one), the amplitude (1 unless you set another) and the
type: linear, exponential, dB/octave or dB/Hz. dB/octave and dB/Hz also ask for the
boost (dB).

The length is samples times the interval: a sweep of 12 000 ms at 1 ms is 12 000 samples
(2 ms: 6 000; 0.5 ms: 24 000), the first at 0 ms and the last at 11 999 ms. The length must
be a whole number of intervals, or Generate says so and stays disabled; hover **Length** for
the count it makes now. The end ramp ends at the length, one interval after the last sample.

**Taper.** The shape of the ramp at each end, every shape processSEG offers, and the
length of the start and end ramps. Cosine squared is the usual one, and the default.
Kaiser, Gaussian and power ask for one more number (beta, sigma, exponent), filled with
that shape's usual value; a value processSEG refuses is said in the dialog and Generate
is disabled. A length of 0 is no ramp at that end. A negative length is refused the
same way, and Generate stays disabled while it stands.

**Phase.** The start phase (deg), one number. 0 starts the sweep at zero. 180 reverses the
polarity; there is no separate polarity control.

**Recording filter.** A recorder's anti-alias filter changes what it writes, so a reference
generated to match its data can be passed through the same filter. The default is
**None**: the sweep is exactly as it was, and nothing more is shown. Every value of the
other kinds is typed here; nothing is read from a file's headers, because a header's
cutoff and slope do not say what a minimum-phase filter's type, order and delay are.

- **Linear phase.** The number of taps, and a high-cut and a low-cut, each a cutoff (Hz; 0
  switches it off) and a slope (dB per octave; the gain is -3 dB at the cutoff). The
  filter is a symmetric FIR of that length. It delays every frequency by (taps - 1) / 2
  samples; the **Delay** field shows that number rounded down (31 for 64 taps), computed
  from the taps, and uses it until you type another. An even number of taps delays by
  half a sample more, which a whole-sample shift cannot back out, and the dialog says so.
  Too few taps cannot make a low-cut that low (below about twice the sampling rate over
  the taps, in Hz); the dialog says so and goes on. **Defined by: Coefficients** takes the
  taps typed or pasted as below instead (the delay is then floor((count - 1) / 2) of the
  count typed, and a note says when the coefficients are not symmetric).
- **Minimum phase.** Either **Coefficients**, the filter's taps pasted or typed into the
  text field (one number per line, or separated by spaces or commas; a line's text after
  # is a comment), or a **Family**, Butterworth or Chebyshev, with an order (poles) and a
  cutoff for the high-cut and for the low-cut (0 Hz switches one off), and for Chebyshev
  the passband ripple (dB). The **Delay** is the bulk delay to back out, typed in whole
  samples; it starts at 0. Beside it the dialog shows a suggestion computed from the
  filter you typed (the least-squares delay over the sweep's band); it is used only when
  you press **Use it**. One sample of error is 79 degrees at 220 Hz at 1 ms, so type the
  recorder's own number when you have it.

The delay is backed out as the recorders do, by one shift of whole samples: the data
move earlier by that many samples (a negative number moves them later). The length stays
what you typed: 12 000 ms at 1 ms is 12 000 samples, filtered and shifted. The filter runs
from rest on the sweep followed by zeros, so the ring-out that the shift brings inside the
length is kept, and what is still past the last sample is cut; zeros fill samples shifted
in at the start. The plots show the filtered, shifted reference, the name and the settings
carry the filter, and it is kept in the reference's archive entry (an entry without a
filter reads as None). A filter and shift exist only here: a reference stored from a record
is never filtered or shifted, because the recorder has already done it.

Whether the headers' numbers are enough, in plain words:

| Case | Enough? | What you type |
|---|---|---|
| Linear-phase anti-alias filter, delay removed by the recorder, sweep well below the cutoff | The filter then does nothing to the sweep | nothing (None is as good) |
| Linear phase, delay not removed | No | the taps; type 0 as the delay |
| Minimum-phase low-cut | Mostly: a Butterworth of the header's order is a fair model | the order and cutoff |
| Minimum-phase anti-alias filter near Nyquist | No: the slope gives no order | the filter's coefficients, or its type and order, and the recorder's delay |
| Any minimum-phase filter | No for the shift | the recorder's bulk delay in samples |

Under the settings, the whole sweep is drawn against time. While the plot holds more
samples than it has pixel columns, each column is drawn from its smallest to its
largest sample, as a filled band, so a long sweep reads as an envelope and a taper
as the band narrowing; no sample is skipped. Zoom in until a column holds about one
sample and the line runs through the true samples. Neither plot has a legend: the
axes say what is drawn. Under it is the amplitude spectrum in dB against frequency. The frequency
axis fits the sweep's band, with about a quarter of
the band spare on each side, held within 0 to Nyquist; it fits again when the
frequencies change. Both follow the settings. A long sweep is worked out in the
background; the last good picture stays until the new one is ready, and a finished
picture is shown only when it is the one just asked. A setting processSEG
refuses is said in place of the plots, in plain words, and Generate stays disabled. The
sweep is made by processSEG; viewSEG adds no sweep of its own.

## A trace of the record

The **Source** choice at the top of the Generate dialog takes **Sweep settings** (the
sweep above) or **A trace of the record**. The second stores a rule, not samples: which
trace of the record, the window cut from it, and a phase.

- **Which trace.** Auxiliary trace N (counted among the record's auxiliary traces: a
  pilot, a time break), or trace N of the record (counted among all of its traces, in
  file order). N starts at 1. The same count names an auxiliary trace that is marked for
  correlation (see [Correlate](correlate.md)): the pilot's own trace is correlated only
  when its position is marked.
- **Start** and **Length**, in milliseconds. The length starts as the whole trace of the
  record on show (samples times the interval) and is required. The window is Length / interval
  samples (12 000 ms at 1 ms: 12 000 samples; a length that is not a whole number of intervals
  is cut down to whole samples) from the sample nearest Start, and is clipped to
  the end of the trace; if nothing is left of it, that is the error.
- **Phase**: 0 or 180 degrees, as the sweep's start phase is, limited to what a recorded
  trace can take. 180 reverses the polarity of the cut. It is stored in the rule (a rule
  stored before it reads as 0). A trace you also reversed on the plot is turned twice: back
  as recorded.
- **Name**: filled in from the rule, such as "Pilot: aux 1, 12000 ms from 0 ms" (with
  ", 180 deg phase" when it is 180), and kept in step with it while you do not edit it.

Under the settings the dialog shows the pilot of the record on show, the same signal and
spectrum plots as the sweep, and says which record it is from. With no file open it says
to open one. The preview is read in the background.

When this reference is the chosen one, each record uses its own trace by the rule: a
Correlation window of the next record takes that record's trace, and the window's note
(under the plot) names the record and the trace ("Reference: <name> (FFID 2, auxiliary
trace 1)"). The trace is the recorded trace: the file's samples, turned over only when
the trace itself is reversed (R); then the window is cut; then the rule's phase (180
turns the cut over). A reference never carries a filter: not the plot's filters (the Aux
traces too option included), not the trace's own filter (F), not "Reverse polarity of all
traces", not gain or any other display processing; excluding the trace from the plot's
filters (E) makes no difference to it. The dialog's preview and the reference's window
show it the same way, with a line saying it is the recorded trace, reversed when the trace
is (and turned again by the 180 deg phase). (Earlier versions used the pilot as the plot showed
it: with reverse-all and, in the preview and the View window, the filters.) Reversing the
pilot or killing it asks an open correlation again; a change of any filter or of
reverse-all does not, for the pilot's sake. A record that lacks the trace says so
in place of the plot, naming the record ("FFID 3 has only 1 auxiliary trace, not an
auxiliary trace 2."), and so does a pilot that is killed or marked dead ("FFID 3's
auxiliary trace 1 is killed."); no other trace is used instead. A window whose traces
come from more than one record is refused ("These traces come from 2 records; a record's
pilot needs traces of one record."). A frozen window keeps the pilot it showed. A vibrator
signature still uses the file's own pilot while such a reference is chosen, and its note
says so. The rule has no sample interval of its own: the trace's must be the plot's.

In the archive the row says "pilot: auxiliary trace 1", the length in ms and "of each
record", and the interval "the record's". It can be chosen, renamed, deleted and copied
into a project like another. **View** opens the pilot of the record on show, and says
which record; its button **Store this pilot as a fixed reference** keeps the record's cut
pilot as an ordinary stored waveform, exactly as the rule gives it for the record on show:
the recorded trace, reversed when the trace is, the cut and the rule's phase. A rule is not
one waveform, so it cannot be compared as A or B.

## Reference archive

**Reference archive...** lists the references you can use. The window's title says which
archive it shows.

- With no project open, the list is the main archive: yours, kept beside what viewSEG
  remembers about files, and there again next time you start.
- With a project open, the list is the project's. The references travel with the project
  folder. The main archive is shown below, collapsed, and each of its rows can be copied
  into the project. It is not changed from here.

Each reference is a one-trace SEG-Y file (IEEE float, the sample interval in the header,
the name in the textual header) in a `references` folder, with an index beside it. Any
SEG-Y tool can open one. An index entry whose file is not a single name in that folder
is reported and left alone: it is not opened, renamed, deleted or copied. A SEG-Y left
in the folder with no index entry (a write that did not finish) is reported once and
left; it is not deleted.

The table shows the name, length, sample interval, frequency range (for a generated
sweep), where it came from, and the date. Click a column heading to sort. The first column
is the **Use** mark, then the name, which takes the spare width of the window.

Click anywhere on a row to select it: one row is selected at a time, and the Up, Down,
Page Up, Page Down, Home and End keys move the selection. The buttons above the table act on
the selected row: **Use**, **View**, **Rename**, **Delete**, **Compare as A**, **Compare as
B** and, for a row of the main archive under a project, **Copy to project**. A button that
does not apply is dimmed, and its tooltip says why (nothing selected, a main archive row
cannot be renamed, a pilot cannot be compared). The same actions are in the menu of a
right click on a row. Double-click a row to view it; the Delete key deletes it and F2
renames it. Renaming edits the name in the row: Enter keeps it, Escape leaves the name as
it was; a name already used is refused, the reason is shown in the window, and nothing is
overwritten. **Delete** asks first and names the reference; the question opens in the middle of
the main window, and the archive has the keyboard again when it closes.

**View** opens the reference in its own window, titled
"Reference: <name>", docked like a New plot window. It draws the reference's samples
against time, from the archive's From and To and its sample interval, and in the same
window its amplitude spectrum. The Seismic window, the open file, and every other window
stay as they were. A stored waveform needs no file open: it is read from the archive, and
when it cannot be read the window says why. (A pilot of the record is a rule, not a
waveform: it needs the file whose record is on show, and says so when none is open.) The window shows that reference until you close it. If you rename
the reference, the title follows. If you delete it, the window says so.

The table takes the height of the window. With a project open, the **Main archive** header
stays at the window's bottom; open it and the two tables share the height.

**Use** (the mark in the first column, or the button) selects the one reference the plots
use. The **None** row is the default: no reference is chosen; the mark of a chosen row,
clicked again, goes back to it. Vibrator plots then use the file's own pilot. A
correlation needs a chosen reference. The Correlation window says
"No reference is chosen. Choose one in References." The Envelope window takes the chosen
reference too: its phase plot is then the phase of the trace minus the reference's, in
degrees, against time ("Phase against the reference"; a trace against itself is 0). With
none chosen, or with the window's **Phase** drop-down set to "Of the trace itself", it
draws the trace's own instantaneous phase, which turns once per cycle. A reference at
another sample interval is not used (the window says so); a shorter or longer one is
zero-padded, as for the correlation.
One reference at most is selected.
The choice is kept in the project when one is open, and otherwise across restarts.
Opening or closing a project switches the archive and the choice. A plot whose reference
was deleted says the reference's name, and the choice goes back to None. The log says
"No reference is chosen. Choose one in References." An
open cross-correlation that is not frozen says that name and does not draw.

## Store a trace

Right-click a trace in the Seismic window, seismic or auxiliary, and choose **Store as
reference...**. The name starts as "<file> rec <record> tr <trace>" and can be changed. A
name already used is refused. **From** and **To** are in milliseconds and start as the
whole trace; if the file's headers give a sweep length, **To** starts at that sweep's last
sample (its length less one interval), because the
rest of the record is usually listen time. **From** and **To** are the times of the first
and last sample taken, both included: a trace of 12 000 samples at 1 ms runs from 0 to
11999 ms and is 12 000 ms long, and the dialog says it under the boxes ("Takes 0 to 11 999
ms: 12 000 samples at 1 ms = 12 000 ms (12 s)"; hover **To** for the same in a tooltip). A
**To** typed past the last sample is brought back to it, and the dialog says so. The
length of N samples at an interval of dt is N times dt everywhere: here, in the archive's
Length column ("12000 ms (12000)"), in the stored file's text header and in the message
that says the reference was stored.

The stored samples are the file's samples with the trace's own reversal: a trace you
reversed is stored reversed. No filter is applied (not the plot's, not the trace's own),
nor "Reverse polarity of all traces" or the gain. The dialog says "stored as recorded" or
"stored reversed (this trace is reversed)". The dialog's **Phase**
(0 or 180 degrees) turns the stored window over after that, as the pilot's rule does. A
killed trace, or one the file marks dead, is refused. (Earlier versions stored the file's
samples never reversed; references stored then keep their samples, nothing is recomputed.) The read runs in the background; the window does not wait on the file.

## Compare as A or B

Each row has Compare as A and Compare as B. That copies the reference into a compare
slot (the user guide, Compare two traces). The slot keeps that copy for this run only;
it is not saved with the archive or the project.

## What a plot does with it

A cross-correlation always uses the reference chosen here, and no other. Its bar says
"Reference: <name>" and a button opens this window. With none chosen, the plot area says
"No reference is chosen. Choose one in References." With the chosen one
gone, or a different sample interval, the plot area says which and does not draw. A
vibrator signature uses the chosen reference instead of the file's pilot when one is
selected, and says so: "Reference: <name> (archive)". Its samples are used as
stored: neither the plot's filters nor a trace's own filter apply to them. An open plot
that is not frozen follows the choice; a frozen one keeps the reference it had.

If its sample interval is not the file's, the plot says "the reference is 2 ms, this file
is 4 ms" and does not draw. Nothing is resampled.

If it is shorter than the trace, it is zero-padded. If it is longer, it is not cut. That
is the same rule the plots already use for a file's own pilot: the longer side sets the
length, and the shorter side is zeros after its last sample. The plot says which.
