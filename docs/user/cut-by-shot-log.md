# Cut by shot log

A node records without stopping, for days, in segments. **Project > Cut by shot log...** cuts
that recording at the times of a shot log: one record per shot, written to a new file, as
SEG-D or SEG-Y. The recording is never changed.

## What it needs

- A recording shown in the **Seismic** window: a seismic file of nodes, with a trace for each
  segment of each component. Not a correlated view (show the file itself) and not a vibrator
  signature file.
- A shot log loaded: **Project > Import shot log...** (see the shot log section of the
  [quick start](QUICKSTART.md)). Only rows with a time are cut.

Until both are there the menu item is dim, and its tooltip says which is missing ("Show a
seismic file and load a shot log first."). Only one cut runs at a time.

## What the cut accepts

Only a continuous receiver gather. viewSEG asks two questions of the file:

1. **Is it a shot gather?** The receiver line and point change from trace to trace: there is
   more than one receiver point and no receiver has more than one segment. If so, it is a shot
   gather ("This file is a shot gather (the receiver changes from trace to trace), not a
   continuous receiver gather."). If not, it is a receiver gather.
2. **Is the receiver gather continuous?** Each trace starts a whole number of trace lengths
   after the one before it. For one receiver (one channel at one point), the step is the
   commonest difference between consecutive start times; the next start is the previous start
   plus k steps, k a whole number, to within one sample. The traces may be a little longer than
   the step (a little repeated data at their ends, at most a tenth of their length), but not
   shorter (dead time between traces) and not much longer (traces that mostly cover each
   other). At least half of the boundaries must follow the step. If so, it is a continuous
   receiver gather. If not, it is a **time-sliced receiver gather**, and the sentence says why:
   the starts are not on a common step, the traces are shorter than the step, they mostly cover
   each other, or every trace carries the same start time (so their own start times are not in
   the headers viewSEG reads; a vendor header map may have to describe them).

If the recorder was off for a while, the next trace starts after more than one step (k greater
than 1): the missing segments count as continuous, the times are written as zeros, and the
window and Messages say "The recorder did not record for 67 segments (in 1 place); those times
are written as zeros." A file with no receiver line and point in its headers, or with some
points of one segment and others of several, goes through the two questions as they stand.

The window reads the file and refuses the other kinds in a sentence above the buttons (the
tooltip of the dim **Cut** says the same), and the command and the job refuse them the same way
before any file is written.

## The window

The **Cut by shot log** window floats; close it with **Close** or its own close button. A later
opening keeps what you typed. From the top:

- **Source:** the recording that is cut, the file the Seismic window shows.
- **Shot log:** the log to cut by, from the logs loaded. It starts as the one the Shot log
  window shows.
- **Record length (ms):** how long each record is. It starts at 10000. It must be a whole
  number of samples; the window says when it is not, and what the interval is.
- **Start (ms):** where each record starts, relative to the shot. 0 starts at the shot. A
  negative number starts before it. The end of the record, start plus length, must be under
  2147 s.
- **Alignment:** what is done when a record starts between two samples of the recording.
  **Nearest sample** starts at the nearest one and interpolates nothing. **Linear**, **Cubic**
  and **Sinc** shift the part of the start between two samples out by that interpolation; Sinc is the
  most exact and the slowest. Hover an entry for the same in a sentence.
- **Format:** **SEG-D Rev 3** or **SEG-Y**. The default is SEG-D Rev 3.
- **Folder:** where the file goes, chosen with **Change folder...**. It is "not chosen" until
  you choose one.
- **File name:** a name without a folder. It starts as the recording's name, then `_cut`, then
  the extension of the format (`.sgd` or `.sgy`), and follows the format until you type
  another. When a file of that name is already in the folder, the window says so and **Cut**
  stays dim; nothing is overwritten.

Under the fields, one line sums up what will be written once the options are right: the
number of shots, how many rows of the log have no time and are left out, the number of
components, and about how much disk the file will take ("5 shots (2 rows have no time and are
left out), 3 components, about 1.2 MB to write."). The size is an estimate, in decimal units.
A second line says how the records will be numbered when it is not by the log's file numbers.

**Cut** starts the job. It is dim, and its tooltip says why, while the folder or the name is
missing, the options are wrong, or the headers of the recording are still being read.
The Jobs window shows the job ("n of m shots"); Cancel stops it and removes what was written.
While it runs, the window says so. When it ends, the window gives the outcome, and
**Open the cut file** shows the new file in the Seismic window and lists its folder.

## What the file holds

- **One record per shot**, in the time order of the shots, however the log is ordered. Shots
  with the same time are all kept, and Messages counts them.
- **The components as channels.** Each record holds one trace per component of the
  recording, numbered 1 to the number of components, and the shot's own values (its line,
  point, position and file number, where the log has them) in the headers.
- **Record numbers.** The shots' file numbers, when they are whole numbers that rise strictly
  in time order. Otherwise the records are numbered 1 to the number of shots, and Messages and
  the window say so.
- **SEG-Y** has no place for the source line or the point index, and Messages says once that
  they are left out. A point index outside 0 to 255 is written as 0, and counted.
- **The samples** are written as 32-bit floats.

When a vendor header map names each trace's start time (see `vendormaps/README.md`), the cut
reads the segments' start times from the trace headers and says so in Messages. A trace
without the field is left out and counted; a recording that crosses a leap second shows a
one-second overlap between the segments either side, because each segment's GPS time is
converted to UTC at its own instant. The window
reads the file the same way, in a job, before it sums up: while it does, it says the recording
is being read and **Cut** is dim.

## Where the recording does not fit the shots

Messages reports what the cut found, after the file is written.

- **Segments that overlap.** Where two segments of one component cover the same time, the
  data are written once. The later segment, by start time, wins. When both are read, their
  overlapping samples are compared; Messages says how many overlaps it compared, how many
  match and how many differ, and names the segments of those that differ ("source traces 3
  and 4"). A difference means the two segments disagree about the same moment, which points to a
  timing fault in the recording, not to a duplicate. Overlaps no record needed are counted too, and overlaps that
  could not be read are said to be not compared.
- **Segments off the sample grid.** A segment that starts a fraction of a sample off the
  grid of the one before it is named, with the fraction.
- **Gaps.** Time no segment covers is written as zeros, and Messages gives how many output
  samples fall in gaps.
- **Samples that cannot be read** are written as zeros too, and Messages counts them and
  the shots they are in. A file that is cut short, or a drive that fails, stops the cut
  instead.

## The file, and what is never replaced

The file is first written next to its destination as `<name>.part-` and twelve letters or
digits. When the cut is whole, it is renamed to the name you gave. A cancelled or failed cut
removes the part file, and says whether that worked. A file that already exists is never
replaced: the cut ends at once with "The destination already exists." If the name is
taken while the cut is running, the output is left under the part file's name and the window
tells you so. The recording, and every other file, is left as it was.
