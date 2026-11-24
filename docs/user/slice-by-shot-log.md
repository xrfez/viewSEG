# Slice by shot log

A node records without stopping, for days, in segments. **Project > Slice by shot log...** slices
that recording at the times of a shot log: one record per shot, written to a new file, as
SEG-D or SEG-Y. The recording is never changed.

## What it needs

- A recording shown in the **Seismic** window: a seismic file of nodes, with a trace for each
  segment of each component. Not a correlated view (show the file itself) and not a vibrator
  signature file.
- A shot log loaded: **Project > Import shot log...** (see the shot log section of the
  [quick start](QUICKSTART.md)). Only rows with a time are sliced.

Until both are there the menu item is dim, and its tooltip says which is missing ("Show a
seismic file and load a shot log first."). Only one slice runs at a time.

## What the slice accepts

Only a continuous receiver gather. viewSEG asks two questions of the file, comparing only
components of the same type and never re-sorting anything:

1. **Is it a shot gather?** The receiver line and point change from trace to trace. One
   segment per receiver is never proof of continuity, so when every receiver has exactly one
   trace and the file has more than one live trace: if all the traces carry one receiver
   point and start together (the components of one station), the file is one segment of one
   station and is continuous when each component type appears once; when two traces of one
   component share the start time it is not continuous, because the start times could not be
   read; otherwise (the
   points differ, or no trace carries a line and point) it is a shot gather ("This file is a
   shot gather (the receiver changes from trace to trace), not a continuous receiver
   gather."). A file with exactly one live trace is a receiver gather of one segment and is
   continuous. Anything else is a receiver gather.
2. **Is the receiver gather continuous?** Each trace starts a whole number of trace lengths
   after the one before it, with no variance. For one receiver (one component at one point:
   its line and point, else its group coordinates, which within 5 survey units of each other
   are one point, as a node's position written a little differently from record to record)
   the traces are taken in time order and those sharing one start time count as one segment
   (they are its components). The channel
   number tells receivers apart only where two traces of one component at one point start
   together (uncoded components of one station); otherwise it is left out, so a receiver whose
   channel number changes from record to record, or rises from trace to trace, is still one.
   The step is the commonest difference between consecutive start times from 0.9 to 1 times
   the trace length; when none lies there, the commonest difference divided by a whole number
   from 2 to 8 that lies there (every other trace was not recorded); when still none, the step
   is the trace length.
   Every start must then be the previous start plus k steps, k a whole number, to within one
   sample, and every trace must cover the step: not shorter than it, and at
   most a tenth of its length longer (a little repeated data at the ends). A continuous
   recording also needs traces that follow on each other: somewhere in the file a trace must
   start just one step after the one before it (k = 1). When every gap is two steps or more,
   nothing follows on anything, as in records sliced at shot times, and the file is not
   continuous however whole its gaps: "No trace follows directly on the one before it: each of
   a receiver's traces starts 15 trace lengths or more after the last, as records sliced at
   shot times do." If every rule holds, it is a continuous receiver gather. If not, it is a **time-sliced receiver gather**, and the sentence
   says why: the first trace that breaks the rule, with the numbers measured for it (how long
   after the one before it it starts and the trace length, or how long it is and how long the
   others are), or every trace of a component carries the same start time, so the start times
   could not be read (a recorder that keeps each trace's start time in its own trace header
   extension needs a vendor header map that names that field).

A receiver gather that is not continuous is a **shot gather** when, in the order of the file, the
receiver point changes between most consecutive segments of one component: the receivers repeat
from record to record, as shots at uneven times do. Consecutive traces of one point that share a
start time are one segment, whatever their component codes (the channels of one station are never
compared with each other). A receiver point is its line and point, else its group coordinates,
else its channel number: a file with neither of the first two whose single receiver changes its
channel number from trace to trace reads as a shot gather. Otherwise it is time sliced. The
sentence of such a shot gather also says the first trace off the step, as measured: "This file is
a shot gather (the receiver changes from trace to trace), not a continuous receiver gather. Trace
11 starts 2.666 s after the one before it; the traces are 2 s long, so it is not a whole number
of trace lengths later." Shot records a whole number of trace lengths apart, none following on
another, are a shot gather the same way, and their sentence says so ("No trace follows directly
on the one before it: ...").

The kind is asked of any file you open, so the window decides it from the first 8 distinct start
times of each receiver. The slice itself places every segment and checks every start: a trace off
the step anywhere later in the file refuses the slice with the sentence above.

If the recorder was off for a while, the next trace starts after more than one step (k greater
than 1): the box pads with zeros, so a long silence is still a whole number of steps. As long as
some trace in the file follows directly on another (one pair is enough), the missing
segments count as continuous, the times are written as zeros, and the window and Messages say
"The recorder did not record for 67 segments (in 1 place); those times are written as zeros."

When the start times are read from the trace headers, the traces of one component type at a
station that share a start time are its channels, told apart by their order. If one channel
misses a segment the later channel would take its place, so the slice is refused: "The channels
of one component type at a station cannot be told apart and one of them misses a segment, so
the records cannot be assembled safely."

Each record holds the receivers in the order the file shows them: stations by their first
trace, and within a station its components by theirs. Nothing is sorted by station number or
component code.

The window reads the file and refuses the other kinds in a sentence above the buttons (the
tooltip of the dim **Slice** says the same), and the command and the job refuse them the same way
before any file is written.

## The window

The **Slice by shot log** window floats; close it with **Close** or its own close button. A later
opening keeps what you typed. From the top:

- **Source:** the recording that is sliced, the file the Seismic window shows.
- **Shot log:** the log to slice by, from the logs loaded. It starts as the one the Shot log
  window shows.
- **Record length (ms):** how long each record is. It starts at 10000. It must be a whole
  number of samples; the window says when it is not, and what the interval is.
- Every record **begins at the shot's time**, so there is no start to set. The length must be
  under 2147 s.
- **Alignment:** what is done when a record starts between two samples of the recording.
  **Nearest sample** starts at the nearest one and interpolates nothing. **Linear**, **Cubic**
  and **Sinc** shift the part of the start between two samples out by that interpolation; Sinc is the
  most exact and the slowest. Hover an entry for the same in a sentence.
- **Format:** **SEG-D** or **SEG-Y**. SEG-D reads "SEG-D (the source's revision)" when the
  recording is SEG-D (its headers are kept, see below) and "SEG-D Rev 3" otherwise.
- **Folder:** where the file goes, chosen with **Change folder...**. It is "not chosen" until
  you choose one.
- **File name:** a name without a folder. It starts as the recording's name, then `_slice`, then
  the extension of the format (`.sgd` or `.sgy`), and follows the format until you type
  another. When a file of that name is already in the folder, the window says so and **Slice**
  stays dim; nothing is overwritten.

Under the fields, one line sums up what will be written once the options are right: the
number of shots, how many rows of the log have no time and are left out, the number of
components, and about how much disk the file will take ("5 shots (2 rows have no time and are
left out), 3 components, about 1.2 MB to write."). The size is an estimate, in decimal units.
A second line says how the records will be numbered when it is not by the log's file numbers.

**Slice** starts the job. It is dim, and its tooltip says why, while the folder or the name is
missing, the options are wrong, or the headers of the recording are still being read.
The Jobs window shows the job ("n of m shots"); Cancel stops it and removes what was written.
While it runs, the window says so. When it ends, the window gives the outcome, and
**Open the sliced file** shows the new file in the Seismic window and lists its folder.

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
- **What the output keeps of a SEG-D recording's headers.** When the recording is SEG-D and the
  format is SEG-D, the file is written in the recording's own revision (Rev 2.1, say, not
  Rev 3) and its headers are the recording's: the general and extended headers, the channel sets
  with their filter and gain fields, and each trace's header blocks, a manufacturer's own among
  them, taken from the segment that holds the first sample of the shot's window (the first
  segment the window reads, when it starts in a gap or before the recording). What changes is
  what belongs to the slice: the file number (the log's, else 1 to the number of shots), the
  record time, the trace number (one per component, the same in every record: the trace number,
  not the trace's place in the record, tells the components apart, as a component whose segment
  is missing comes from a later segment and so later in its record), the time of the first
  sample in a Rev 3 trace's timestamp block, the start time and the trigger time in a vendor
  block, when a vendor header map names them (`firstSampleTime` and `triggerTime`, in "us GPS"
  or "us UTC"), and the source line and point where the revision has a place for them (Rev 2:
  the source header; its coordinates have none). Messages says what was rewritten, in how many
  traces, and what has no place. The trigger time becomes the time of the slice's first sample,
  like the start time: if the recording's trigger was some time before or after its first
  sample, that gap is not kept. A trigger field the map gives no unit is set only when, in the
  recording, it held the same value as the start time in the same form; otherwise it keeps the
  recording's value, and Messages counts those traces. A record begins at the shot's time: its
  time is the first sample's less the start time of its channel set (0 in most recordings), so
  a reader that adds the set's start finds the first sample there, and a Rev 3 trace's time
  stamp holds its first sample's time. When the channel sets of a record start at different
  times, the record's time goes by the earliest, and Messages says so. A Rev 2 record holds
  whole seconds only, so its reader shows the second its time falls in, and the vendor start
  time carries the exact instant. A trace no segment reaches is written as zeros and marked
  dead. Survey positions and moved receivers are not written: the headers are the recording's.
  The samples are written as 32-bit floats whatever the recording's sample format, and Messages
  names a format that is not 32-bit float. A recording the writer cannot copy (several records,
  multiplexed data, Rev 3 extended recording mode) and any SEG-Y recording or SEG-Y output
  build their headers from the options and the log instead, as Rev 3 for SEG-D; for a SEG-D
  recording, Messages gives the reason and the Format entry reads "SEG-D Rev 3". A shot the
  writer refuses is left out and named in Messages; the others are written.

When a vendor header map names each trace's start time (see `vendormaps/README.md`), the slice
reads the segments' start times from the trace headers and says so in Messages. A trace
without the field is left out and counted; a recording that crosses a leap second shows a
one-second overlap between the segments either side, because each segment's GPS time is
converted to UTC at its own instant. The window
reads the file the same way, in a job, before it sums up: while it does, it says the recording
is being read and **Slice** is dim.

## Where the recording does not fit the shots

Messages reports what the slice found, after the file is written.

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
  the shots they are in. A file that is cut short, or a drive that fails, stops the slice
  instead.

## The file, and what is never replaced

The file is first written next to its destination as `<name>.part-` and twelve letters or
digits. When the slice is whole, it is renamed to the name you gave. A cancelled or failed slice
removes the part file, and says whether that worked. A file that already exists is never
replaced: the slice ends at once with "The destination already exists." If the name is
taken while the slice is running, the output is left under the part file's name and the window
tells you so. The recording, and every other file, is left as it was.
