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
auxiliary trace fails the file.

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
- **Auxiliary traces.** A trace of the file that holds a reference is correlated like the
  others, after it is shifted by its lag. Any other auxiliary trace is cut to the listen
  time and written as it is.
  Reference traces are written with the lead and a matching negative delay (their own delay
  less the lead), so a reader that honours the delay puts the wavelet peak at time 0. A SEG-D
  file written from a SEG-D file keeps its own headers, which hold one start time per channel
  set, so there the reference traces keep the delay the file had and the notes say so.
- **An unreadable trace fails the file.** A trace that cannot be read (the file is cut short,
  the drive fails) fails that file, with the reason in its row of the results, and the part
  of the file already written is removed. The other files of the run go on.
- **A vibrator signature file** in the run is written as it would be without the tick, and
  its notes say "A signature file is written uncorrelated."
- A SEG-D record with an auxiliary trace at another sample interval is written with that
  trace as zeros at the output's interval, and the notes say so.

A file that is open in the program is correlated as it stands, with its edits. The file on
disk is never changed.
