# Output file names

The **Output** window (File > Output...) writes each file under the name of its source file,
with the new extension (`.sgy` or `.sgd`). A **name pattern** builds the name from the file's
own values instead: its record number, its source line, its time. It is for a folder of
files whose names say nothing, or say it in another order than you need.

The right pane of the Output window has a **File names** drop-down. It lists the patterns
of the project, and **As the source file**, which is the choice when no pattern is in use.
The line under the file tree then says how many files are ticked, their size and, when a
pattern is chosen, "named by" its name. The extension still follows **Format**, and **Keep the
sub folders** still decides the folder: a pattern replaces the last part of the path, the
file name, and nothing else.

A pattern belongs to the project, so patterns are kept only while a project is open
("Open or make a project to keep name patterns."), and not when it is open read-only ("The
project is open read-only."). You can still pick the pattern the project already holds.

## Edit a pattern

**Edit...**, under the drop-down, opens or closes the editor below it.

- **File name pattern.** A name for the pattern ("Name of this pattern"), to pick it by in
  the drop-down. It is a label, not a file name, at most 64 characters, and it holds no
  control character. Saving a pattern with the name of a saved one, whatever the case,
  replaces that one.
- **Separator.** What is put between the parts: `"." dot`, `"_" underscore` or
  `"-" hyphen`.
- **The parts**, one row each, in the order they are written. The first box on a row is
  the kind of part. **Up** and **Down** move the row, **Remove** takes it away, and **Add part**
  adds one at the end. A pattern has at least one part and at most 16. The list of kinds
  shows every part. One that only one sort of file can give carries a note: "(signature
  files)" for the parts of a vibrator signature file, "(seismic files)" for the parts only
  a seismic file has. They are not hidden, because one pattern can serve both sorts of file.
- **Example:** shows the name the pattern makes with made-up values and the extension of
  the chosen format, or the reason it cannot make one. Nothing is read from a file for it.
- **Save** keeps the pattern in the project. **Delete** removes the saved pattern of that
  name. While Save cannot keep the pattern (the name is empty, or a part is refused) it is
  dim, its tooltip gives the reason, and the reason is also under the buttons.

### The parts

| Part | What it writes |
|---|---|
| **File name** | the source file's name without its extension |
| **Text** | the text typed in the row, the same for every file |
| **Record** | the record number (the FFID of SEG-Y, the file number of SEG-D) |
| **Source line**, **Source point** | the source's line and point |
| **Source index**, **Receiver index** | the index of the source or receiver (SEG-D only) |
| **Receiver line**, **Receiver point** | the receiver's line and point |
| **Time** | the UTC time of the record, or of a vibrator sweep, as below |
| **System serial** | the system's serial number (SEG-D) |
| **Sensor serial** | the serial of the unit that recorded the traces: the SEG-D Rev 3 Sensor Info block, or a field a vendor map names `sensorSerial` |
| **Vendor field** | a field of a vendor header map, by the name a display line lists for it (a bare name, or `block.name` when two fields share it), typed in the row; the same as `{vendor:NAME}` in a [text header template](text-header.md) |
| **Controller**, **Vibrator**, **File number**, **Line**, **Station**, **Shot id**, **Sweep id** | what a vibrator signature file says of its sweep; they are for signature files only |

A part takes its value from the traces of the file, and a file has one value for it or none.
A trace that is auxiliary is not looked at when the file has others; a killed trace is not
looked at when **Drop killed traces** is on. Parts that belong to a vibrator signature file
(the last row of the table) are missing from any other file, and the record, line, point and
time parts are missing from a signature file, except its source index and its time, which a
sweep can give.

A name needs every one of its parts. A file that lacks one, or whose traces do not all give
the same value for it, is not written, and its row in the results says which part and why
("Source line is not in this file." or "Source line is not one value in this file."); the
other files of the run are written. A **Sensor serial** is read from the traces only when a
pattern uses it, and a signature file has none. A vendor map marks the field that holds the
serial by naming it `sensorSerial` (see Vendor header maps); the standard block of the trace is
looked at first, then the vendor blocks of the same trace; a field in a block of the record
or the file is not used. A file whose headers cannot be read to the end (a
truncated file) is not written, and its row in the results gives the reason.

A **Vendor field** is read from the traces only when a pattern uses it (so a pattern without
one costs nothing). Its value is the field's value over the traces the name is made from; a
trace that has no value for the field is left out, as for **Record**. An integer is written
without a decimal point, a number with a fraction as any number part is (at most four
decimals, the point written `p`: `12p5`), and a text as it is, without the blanks at its ends,
under the rules for text above. A file whose traces that have a value do not all agree is not
written: its row says "Vendor field NAME is not one value in this file.". A file in which no
trace has one, in which the name is unknown (or no vendor map is loaded), or whose number is
not finite or is 1e15 or more, is not written either: "Vendor field NAME is not in this
file."; and a text with a byte that is not printable ASCII gives "Vendor field NAME holds
characters a file name cannot hold." The example under the parts shows `42` for it.

### Numbers

**Least digits** (a column of the parts table) is for the numeric parts: a number shorter
than that gets leading zeros, so a folder sorts in the order of the numbers (`7` with 4 digits
is `0007`). A longer number is never cut. The width is 0 to 12; 0 is no padding. **File name**,
**Text**, **Time**, **Sensor serial** and **Vendor field** have no width.

A number with a fraction is written to at most four decimals, trailing zeros dropped, and the
decimal point is written as a `p`: a source point 1034.5 is `1034p5`. A negative number has its
sign in front of the zeros: `-0042`.

### Time

**Time** is written as year, month, day, `T`, hour, minute, second and `Z`, with no colon, so
it sorts and is a legal name on every system: `20260315T081530Z`. When the time is not
whole seconds, six digits of microsecond follow the seconds: `20260315T081530250000Z`. A SEG-Y
header with no fraction, and the general header clock of an earlier SEG-D, give whole seconds;
every other time gives six digits. A time outside the years 0 to 9999 cannot be a name.

### When a pattern cannot be kept, or a name cannot be made

A pattern is refused (the editor says why) when:

- it has no name, a name longer than 64 characters, or no part;
- it has more than 16 parts, or a width outside 0 to 12;
- a **Text** part is empty, starts or ends with a space, or holds a control character or one
  of `< > : " / \ | ? * .` (so a dot is never in a part), or holds the separator itself.

A name for one file is refused (that file fails, the rest go on) when:

- a part is missing or not one value in that file, as above;
- a value taken from the file (a **Sensor serial**, say) holds a character a text part may
  not;
- the whole name, or a piece, is a name Windows keeps for a device (`CON`, `PRN`, `AUX`,
  `NUL`, `COM1`, `LPT1`, and the like);
- the name ends with a dot or a space, or is longer than 180 characters with its extension;
- two files of the run would take the same name: the first is written and the second fails,
  naming the file it clashes with.

A file that already exists in the destination folder is never replaced: that file fails with
"The destination already exists."
