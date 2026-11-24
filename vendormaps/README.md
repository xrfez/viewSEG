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

## The unit serial

A field a map names `unitSerial` is taken as the serial number of the unit that recorded a
trace. The **Sensor serial** part of an output file name (Output window, File names) reads
it: first from the standard SEG-D Rev 3 Sensor Info block of the trace, then from a
`unitSerial` field of the trace's own vendor blocks, then from one in the vendor blocks of
its record (or, for SEG-Y, of the file). A map that describes a serial under another name
needs the field renamed, or a copy of the map with the name added, for the part to find it.
A value that is blank or a sentinel the map declares is no serial.

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
