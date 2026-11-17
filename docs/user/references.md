# References

A reference is one trace of samples: a vibrator pilot or a sweep, with a name. Plots that
need a reference (a cross-correlation, the vibrator signature's reference) use it when the
file has none, or when you want another than the file's.

**Operations > References** holds two items.

## Generate a reference

**Generate a reference...** makes a sweep and stores it. Set the name (a default is filled
from the parameters, such as "Linear 8-80 Hz 8 s"), the start and end frequency, the
length, the sample interval (the file on show, when there is one), the taper at each end,
and the sweep type: linear, exponential, dB/octave or dB/Hz. The amplitude is 1 unless you
set another. A short preview of the sweep is drawn as you edit (at most a few thousand points; a
longer sweep says it is showing the start). A sweep too long for processSEG is refused
in plain words before any of it is made. The sweep is made by
processSEG; viewSEG adds no sweep of its own.

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

**Use** selects the one reference the plots use. **From the file** is the default: the
plots use the file's own pilot, as they did before. One reference at most is selected.
The choice is kept in the project when one is open, and otherwise across restarts.
Opening or closing a project switches the archive and the choice. A plot whose reference
was deleted says the reference's name, and the choice goes back to From the file, so the
next plot works.

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

When a reference is selected, a cross-correlation and a vibrator signature use it instead
of the file's pilot, and say so: "Reference: <name> (archive)". Its samples are used as
stored: neither the plot's filters nor a trace's own filter apply to them. An open plot
that is not frozen follows the choice; a frozen one keeps the reference it had.

If its sample interval is not the file's, the plot says "the reference is 2 ms, this file
is 4 ms" and does not draw. Nothing is resampled.

If it is shorter than the trace, it is zero-padded. If it is longer, it is not cut. That
is the same rule the plots already use for a file's own pilot: the longer side sets the
length, and the shorter side is zeros after its last sample. The plot says which.
