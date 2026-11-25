# Correlate

A vibrator record is the sweep spread through time. Correlating each trace with the sweep
turns it into the listen time: the record length minus the sweep length, with each arrival
shaped like the sweep's autocorrelation. The reference is the one chosen in
[References](references.md). The file you correlate is never changed, whether you look at the
result or write it.

## The Correlate button

**Correlate** on the control strip (or `C`; also under Whole record in the plot's menu) shows
the record of the file on show correlated, in place of the raw samples. It is lit while on and
dim, with a tooltip, while no reference is chosen. Turning it off shows the raw record again.

A correlated copy of a whole file is kept in memory. When that copy would be more than the
program may hold at once (2 GiB), the file is not copied: it is **correlated on demand**, a
view that correlates the traces you ask for as you look at them. The picture is the same. The Messages window says so:
"Correlated on demand: the correlated copy would be (the size), more than fits in memory at
once".

If the reference cannot be used, or a trace of the file cannot be read, the button goes off,
the raw record is shown again, and Messages says why.

## Write the correlated data: the Correlated tick

The **Output** window (File > Output...) has a **Correlated** tick among the options on the
right. Ticked, every seismic file of the run is written correlated with the project's reference
instead of as it is on disk.

The tick is dim until a reference is chosen that the write can use; hover it to read why it
is dim. When it is on, the totals line above the results table ends with "correlated with" and the
reference's name.

A stored sweep is loaded once for the whole run. A pilot reference is taken from each record
being written, so every record is correlated with its own pilot; a record without that
auxiliary trace fails the file. The pilot's own trace is correlated only when it is marked,
as any other auxiliary trace.

What is written:

- **The order.** Each trace is correlated first. The edits you chose in the window are applied
  after that, to the correlated trace: **Polarity reversals**, **Time shifts**, **Own filters**
  and **Processing**, each in the order a plain write applies them. A time shift or a filter
  is therefore not applied to the raw trace before the correlation.
- **Length.** The record is the listen time long. The trace headers are the file's, with the
  sample count changed. In SEG-Y the trace header's correlated flag is set to yes; the
  binary header is left as it was.
- **Samples are 32-bit float**, whatever the source format, in the amplitude of the source: an
  arrival shaped like the sweep with amplitude *a* correlates to a peak of *a*.
- **Dead traces stay dead.** A trace marked dead in the file is written as zeros, not
  correlated.
- **Auxiliary traces.** An auxiliary trace is correlated only when it is **marked for
  correlation**; none is marked unless you say so, whatever its trace code (a trace that
  holds a reference included). Any other auxiliary trace is cut to the listen time and written
  as it is.
  A mark is for an auxiliary position: the *N*th auxiliary trace of a record, counted in file
  order as the pilot rule counts "Auxiliary trace *N*" (see [References](references.md)). It
  holds for that position in every record of the file. A mark is made for one file, and is kept
  with that file's edits, or for the whole project, and is kept in the project and applies to
  every file of it. For a position of a file, the file's own entry decides; a file may also say
  *not marked*, which wins over the project's mark. With no entry of the file, the project's
  decides; with neither, the trace is not correlated.
  To mark, right-click an auxiliary trace in the Seismic or the Aux window and open
  **Correlate auxiliary trace *N***. Its first line says what is in force ("Marked in this
  file, shift 500 ms", "Marked in the project, shift 0 ms" or "Not marked: ..."). **In this
  file** ticks or unticks the mark of the file (unticking writes *not marked* when the project
  marks the position, else takes the entry away; Undo takes either back). **In the project
  (every file)** does the same for the project, and is off when no project that can be
  written to is open. **Shift...** asks for the shift in milliseconds of the mark in force
  (the file's when it has one, else the project's); it is off while the position is not
  marked. The menu appears on auxiliary traces only.
  Each mark carries its own **shift**, in milliseconds, positive later (0 when none is given).
  The marked trace is shifted by it before it is correlated: zeros in front, the end cut, the
  record length kept, so both sides of the wavelet show. A shift that is not a whole number of
  samples is taken as the nearest whole number of samples, and the notes give the shift
  applied. The trace is written with a matching negative delay (its own delay less the shift),
  so a reader that honours the delay puts the wavelet peak at time 0; with a shift of 0 the
  delay is left as it was. A SEG-D file written from a SEG-D file keeps its own headers, which
  hold one start time per channel set, so there the shifted traces keep the delay the file had
  and the notes say so; a note also says so when a SEG-Y trace's time scalar cannot hold the
  delay, or when the delay is not where the standard puts it in the file (it is then left as it
  is). viewSEG itself draws every trace of a panel on one time axis, so on reopening the file
  here a shifted wavelet still shows later (its peak at the shift), while a program that
  honours each trace's delay puts the peak at zero.
  A marked position that a record does not have is skipped in that record, and the notes say so
  once for the file. A marked trace at another sample interval than the record is written as
  zeros, and the notes say so. The Correlate button, the on-demand view and the Correlated tick
  of the Output window all take the marks in force: changing a mark asks an open correlated view
  again.
  A file with **no seismic trace** takes its record length and sample interval from its marked
  auxiliary traces (they must share one length and one interval); the unmarked ones are padded
  or cut to that length. With none marked, the file is refused: "the file has no seismic traces
  and no auxiliary trace is marked for correlation." The Correlate button's tooltip and the
  status line then say to right-click an auxiliary trace and mark it for correlation.
- **An unreadable trace fails the file.** A trace that cannot be read (the file is cut short,
  the drive fails) fails that file, with the reason in its row of the results, and the part
  of the file already written is removed. The other files of the run go on.
- **A vibrator signature file** in the run is written as it would be without the tick, and
  its notes say "A signature file is written uncorrelated."
- A SEG-D record with an auxiliary trace at another sample interval is written with that
  trace as zeros at the output's interval, and the notes say so.

A file that is open in the program is correlated as it stands, with its edits. The file on
disk is never changed.
