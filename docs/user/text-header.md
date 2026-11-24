# Text header of the SEG-Y files written

A SEG-Y file starts with a text header of 40 lines (cards) of 80 characters. The **Output**
window (File > Output...) can write the header of each SEG-Y file from a **template** of the
project, filled in for that file: the survey, the file's name, its record numbers, the day
it was written. With no template, a copy of a SEG-Y file keeps the text header of its source
and a file built from header keys gets the library's own one-line header.

The right pane of the Output window has a **Text header** row, shown while **Format** is
SEG-Y. Its drop-down lists the templates of the project and **From the source (the library's
own for a new file)**, which is the choice when no template is in use. The result lines of a
write say "Text header: template 'NAME'." for each file written with one.

A template belongs to the project: templates are kept only while a writable project is
open. With no project, or one open read-only, the row is dim and its tooltip says so.

## Edit a template

**Edit...** beside the drop-down opens the **Text header template** window, with the template
in use (or an empty one).

- **Name.** The name the project keeps the template by ("Name of this template"), at most 64
  characters. Saving with the name of a kept template, whatever the case, replaces it.
- **Character set.** **EBCDIC** (the traditional one) or **ASCII**. A copy of a SEG-Y file is
  always written in the character set of its source: the result line says so when that
  differs from the template's.
- **The lines.** At most 38 lines of 80 characters, in a fixed-width font under a column
  ruler; the line under the box counts the lines and the longest line. Cards 39 and 40 are
  always written by the library. A line holds Latin-1 characters only (no control
  character, no character past U+00FF); ASCII holds the printable ones.
- **Insert a token** puts a token at the cursor, or at the end when the cursor was not in
  the lines.
- **Preview** shows the lines filled in for the file the Seismic window shows, or with
  sample values when none is shown (it says which). A problem is shown in the warning colour
  under it: a token the file has no value for, a line too long once filled in, or a
  character the character set cannot hold.
- **Save** keeps the template in the project and uses it. **Save as new** does the same for
  a name not kept yet. **Delete** removes the template of that name. **Cancel**, Esc and the
  close button leave the project as it was. Ctrl+Enter saves. While the template has a problem
  Save is dim, its tooltip gives the reason, and the reason is under the preview.

A file the template cannot be filled in for is written with the header it would have had
without a template, and the result line says why; the other files of a batch are written.
SEG-D files and the files of **Slice by shot log** are not affected.

## Tokens

A word in braces is replaced by the file's own value when it is written. `{{` and `}}` are a
literal brace. A token that takes a width pads a number with leading zeros: `{record:5}`
(0 to 12 digits). A value that differs between the traces of a file is not one value: the
record, line, point and index tokens then write the **lowest-highest** of them (`5-9`; with
a minus sign at either end, `-5 to 3`, so the hyphen is not read as a sign); any other token
with no single value is a problem.

| Token | What it writes |
|---|---|
| `{stem}` | the source file's name without its extension |
| `{file}` | the source file's name with its extension |
| `{date}` | the day of writing, UTC, as 2026-11-24 |
| `{clock}` | the time of writing, UTC, as 10:15:00 |
| `{record}` (takes a width) | record number (FFID, or the SEG-D file number); lowest-highest when it differs |
| `{srcLine}` (takes a width) | source line |
| `{srcPoint}` (takes a width) | source point |
| `{srcIndex}` (takes a width) | source index |
| `{rcvLine}` (takes a width) | receiver line |
| `{rcvPoint}` (takes a width) | receiver point |
| `{rcvIndex}` (takes a width) | receiver index |
| `{time}` | UTC time of the record, as 20261124T101500Z |
| `{systemSerial}` (takes a width) | SEG-D system serial |
| `{controller}` (takes a width) | signature controller serial |
| `{vibrator}` (takes a width) | vibrator number |
| `{fileNumber}` (takes a width) | signature file number |
| `{sigLine}` (takes a width) | signature line |
| `{sigStation}` (takes a width) | signature station |
| `{shotId}` (takes a width) | shot id |
| `{sweepId}` (takes a width) | sweep id |
| `{sensorSerial}` | serial of the unit that recorded the traces |
| `{vendor:NAME}` | a vendor field by name; lowest-highest when a number differs |

The tokens come from the same values as the parts of a [name pattern](output-file-names.md).

`{vendor:NAME}` writes a field of a vendor header map (see Vendor header maps) over the traces
that go into the file. `NAME` is the name a display line lists for the field: the bare name
when only one field has it, else `block.name`. An integer is written without a decimal point,
a number with a fraction in the shortest form that reads back as the same number (`12.5`),
and a text as it is, without the blanks at its ends. When the traces differ in a number, the
token is `lowest-highest` (`40-41`), as for `{record}`; with a minus sign at either end it is
`lowest to highest` (`-5 to 3`), so the hyphen is never read as a sign. When the traces differ
in a text, or some have no value, the token has no single value; a field that no trace has,
or whose name no loaded map knows, has no value at all. Either way the template is not used
for that file and the result line names the token. A field is read only when a template uses
it, and the preview reads it off the main thread; with no file shown it writes `42`.
