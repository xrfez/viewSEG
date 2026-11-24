# Vendor header maps

Seismic files often carry header blocks whose layout is defined by the manufacturer of the
recording system rather than by the SEG standard: SEG-D extended and external headers, and
the proprietary bytes of SEG-Y trace headers. Without a description of that layout, viewSEG
can only show those bytes as raw numbers.

A **vendor header map** is that description: a small text file (`*.nif`) that names each
field in such a block, where it starts, how long it is and how to read it. With a matching
map, viewSEG shows the fields by name, like any standard header.

## Adding a map

1. Get or write a `.nif` map for your recording system: `WRITING-A-MAP.md`, in this folder,
   is the guide to the format.
2. Put it in a `vendormaps` folder:
   - **for one job**: the `vendormaps` folder of the project (made with the project);
   - **for you**: `vendormaps/` inside your viewSEG settings folder (`viewSEG --paths`
     prints where that is; make the folder if it is not there);
   - **for everyone using this copy of the program**: this folder, `vendormaps/`, next to the
     program (viewSEG makes it at start when it can write there).
3. Choose File > Reload vendor maps. A map dropped in while the program runs is read without
   a restart, and the files already open show the new decode.

## The sensor serial

A field a map names `sensorSerial` is taken as the serial number of the unit that recorded a
trace: a node, a field unit or a digitizer module. It must be in a trace-level block (a trace
header block or a trace header extension); the **Sensor serial** part of an output file name
(Output window, File names) reads it from the trace's own Sensor Info block of SEG-D Rev 3
first, then from a `sensorSerial` field of the trace's own vendor blocks, and from nothing
else: a field in a record-level or file-level block is not used. A controller or recorder
serial must not use this name: a file name would then carry the serial of the wrong device.
A map that describes a unit serial under another name has to name that field `sensorSerial`
for the part to find it (the fields of a map may not overlap, so the bytes have one name). A value that is blank or a sentinel the map declares is no
serial.

## The field that gives each trace's start time

A recorder may keep the start time of every trace in a vendor block of the trace header,
while the record's general header holds one time for all of them. When a map names such a
field `firstSampleTime`, a count of microseconds with the unit `"us GPS"` (since 1980-01-06,
converted with the leap seconds) or `"us UTC"` (since 1970), the cut by shot log reads it for
every trace. At one station and component, traces that share a start time are different
channels; traces with different start times are the segments of one channel, one after the
other. A trace whose field is missing, in another unit, zero or not a time of 1970 to 2200 is
left out, and the cut says how many were. A recording that crosses a leap second shows a
one-second overlap between the segments either side of it, because each segment's GPS time is
converted to UTC at its own instant. A file whose traces of one station and component all
carry one start time is not taken for a recording: its own start times are in a header no
loaded map describes.

## Where viewSEG looks

In this order, and only in folders that exist. When two maps apply to the same block, the one
that is more specific about the file (format, revision, manufacturer code, serial number,
text) is used; of two maps with the same name, the one of the folder first in this list; of
two equally specific maps of different names, the one of the folder first in this list as well.

1. the `vendormaps` folder of the project open;
2. your own folder, `vendormaps/` in the settings folder;
3. this folder, `vendormaps/`, next to the program;
4. every folder listed in the environment variable `PARSESEG_VENDOR_PATH` (separated by `:`
   on Linux and macOS, `;` on Windows).

Run `viewSEG --paths` to see the folders in use on your machine (the `vendormaps:` lines).

Messages says how many maps were loaded from where, and why a map that could not be read was
left out.

Leave the files of this folder as they are when it came with a release: a new release replaces
them. Keep your own maps in your settings folder or in the project.

---

*In the source repository, this folder holds viewSEG's own maps; `nim package` copies them,
with parseSEG's, into every release.*
