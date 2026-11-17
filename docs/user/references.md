# References

A reference is one trace of samples: a vibrator pilot or a sweep, with a name. A
cross-correlation always uses the one chosen here. A vibrator signature uses it instead
of the file's pilot when one is chosen.

**Operations > References** holds two items.

## Generate a reference

**Generate a reference...** makes a sweep and stores it. The dialog is resizable; the
two plots take the extra room, and it does not shrink so far that the settings, the
plots or the buttons leave the window. The settings are in three groups.

**Sweep.** The name (a default is filled from the parameters, such as "Linear 8-80 Hz
8 s"), the start and end frequency (Hz), the length (ms), the sample interval (ms; the
file on show, when there is one), the amplitude (1 unless you set another) and the
type: linear, exponential, dB/octave or dB/Hz. dB/octave and dB/Hz also ask for the
boost (dB).

**Taper.** The shape of the ramp at each end, every shape processSEG offers, and the
length of the start and end ramps. Cosine squared is the usual one, and the default.
Kaiser, Gaussian and power ask for one more number (beta, sigma, exponent), filled with
that shape's usual value; a value processSEG refuses is said in the dialog and Generate
is disabled. A length of 0 is no ramp at that end. A negative length is refused the
same way, and Generate stays disabled while it stands.

**Phase.** The start phase (deg), one number. 0 starts the sweep at zero. 180 reverses the
polarity; there is no separate polarity control.

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
trace of the record, and the window cut from it.

- **Which trace.** Auxiliary trace N (counted among the record's auxiliary traces: a
  pilot, a time break), or trace N of the record (counted among all of its traces, in
  file order). N starts at 1.
- **Start** and **Length**, in milliseconds. The length starts as the whole trace of the
  record on show and is required. The window runs from Start for Length and is clipped to
  the end of the trace; if nothing is left of it, that is the error.
- **Name**: filled in from the rule, such as "Pilot: aux 1, 0-12000 ms", and kept in step
  with it while you do not edit it.

Under the settings the dialog shows the pilot of the record on show, the same signal and
spectrum plots as the sweep, and says which record it is from. With no file open it says
to open one. The preview is read in the background.

When this reference is the chosen one, each record uses its own trace by the rule: a
Correlation window of the next record takes that record's trace, and its bar says which
record and which trace the reference is ("Reference: <name> (FFID 2, auxiliary trace
1)"). The trace is used as the plot shows it: a reversed trace (its own reversal or
reverse-all, not both) is turned over, the plot's filters apply (an auxiliary trace
only when Filters > Filter the Aux traces too is on) and so does the trace's own filter,
then the window is cut. A record that lacks the trace says so in place of the plot, naming
the record ("FFID 3 has only 1 auxiliary trace, not an auxiliary trace 2."), and no other
trace is used instead. A frozen window keeps the pilot it showed. A vibrator signature
still uses the file's own pilot while such a reference is chosen. The rule has no sample
interval of its own: the trace's must be the plot's.

In the archive the row says "pilot: auxiliary trace 1", the length in ms and "of each
record", and the interval "the record's". It can be chosen, renamed, deleted and copied
into a project like another. **View** opens the pilot of the record on show, and says
which record; its button **Store this pilot as a fixed reference** keeps the record's cut
pilot as an ordinary stored waveform (the file's raw samples, as Store does). A rule is not
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
sweep), where it came from, and the date. Click a column heading to sort. Click a name to
rename it; a name already used is refused, the reason is shown in the window, and nothing
is overwritten. **Delete** asks
first and names the reference. **View** opens the reference in its own window, titled
"Reference: <name>", docked like a New plot window. It draws the reference's samples
against time, from the archive's From and To and its sample interval, and in the same
window its amplitude spectrum. The Seismic window, the open file, and every other window
stay as they were. The window shows that reference until you close it. If you rename the
reference, the title follows. If you delete it, the window says so.

**Use** selects the one reference the plots use. **None** is the default: no
reference is chosen. Vibrator plots then use the file's own pilot. A
correlation needs a chosen reference. The Correlation window says
"No reference is chosen. Choose one in References."
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
whole trace; if the file's headers give a sweep length, **To** starts there, because the
rest of the record is usually listen time. The length of the trace is shown.

The stored samples are the file's raw samples: no plot filters, no trace filter, no gain,
and no polarity edit. The read runs in the background; the window does not wait on the file.

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
