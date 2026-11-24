# Binary header of the SEG-Y files written

A SEG-Y file has a binary header of 400 bytes (bytes 3201 to 3600) after its text header: the
job, line and reel numbers, the sweep, the polarity, the measurement system and the
counts the file is read by. The **Output** window (File > Output...) can set values in the
binary header of each SEG-Y file it writes, from a **set** of the project. Only the fields
the set names change; every other byte of the file is what it would have been without a set.

The right pane of the Output window has a **Binary header** row under **Text header**, shown
while **Format** is SEG-Y. Its drop-down lists the sets of the project and **From the source or
library default**, which is the choice when no set is in use: a copy of a SEG-Y file then keeps
the binary header of its source and a file built from header keys gets the library's own. The
result lines of a write say "Binary header: set 'NAME' (N fields)." for each file written with
one.

A set belongs to the project: sets are kept only while a writable project is open. With no
project, or one open read-only, the row is dim and its tooltip says so.

## Edit a set

**Edit...** beside the drop-down opens the **Binary header set** window, with the set in use
(or an empty one).

- **Name.** The name the project keeps the set by ("Name of this set"), at most 64 characters.
  Saving with the name of a kept set, whatever the case, replaces it.
- **The table.** One row for each field that can be set (the table below), in file order: the
  field, the bytes it covers, and a **Value** box. An empty value means the field is not set:
  the file keeps its source's value or the library's. A value is a number; a whole number must
  fit the field's width. A value that is not one is said in the **Note** column, in the warning
  colour, with the range the field holds.
- **In the shown file.** When the Seismic window shows a SEG-Y file, a dim column gives that
  file's own value of each field, read when the editor opens (the column says so while it is
  being read). It is empty for a file that is not SEG-Y, and for a Rev 2 field of a file that
  is not Rev 2.
- **Filter** shows only the fields with those letters in their name; **Only fields that are
  set** hides the others. Neither changes the set.
- **Save** keeps the set in the project and uses it. **Save as new** does the same for a name
  not kept yet. **Delete** removes the set of that name. **Cancel**, Esc and the close button
  leave the project as it was. Ctrl+Enter saves. While the set has a problem Save is dim, its
  tooltip gives the reason, and the reason is under the table. The line under the table counts
  the fields set.

## What is written, and what is not

- A field only Rev 2 has (the table says so) is left out of a file written as Rev 0 or Rev 1;
  the result line says "Binary header: ... is not written in SEG-Y revision 1."
- In a Rev 2 file, a 16-bit field (data traces, aux traces, ensemble fold, original samples per
  trace, original sample interval) is hidden by its extended twin when that is set. The set's
  own twin wins and the result line says so. If the source file has its twin set, the writer
  refuses the 16-bit value; the file is then written without the set and the line says why.
- The fields that size the file or name its revision, and the sample interval (which the writer
  takes from the traces), cannot be set: `samplesPerTrace`, `formatCode`,
  `extSamplesPerTrace`, `byteOrderMarker`, `segyMajor`, `segyMinor`, `fixedLengthTraces`,
  `numExtTextHeaders`, `maxAddlTraceHeaders`, `numTraces`, `firstTraceOffset`,
  `numTrailerRecords`, `sampleInterval`, `extSampleInterval`.
- SEG-D files are not affected, and the result lines say nothing about a set for them.

## The fields

| Field | Name in the project | Bytes | Holds |
|---|---|---|---|
| Job ID | `jobId` | 3201-3204 | -2147483648 to 2147483647 |
| Line number | `lineNumber` | 3205-3208 | -2147483648 to 2147483647 |
| Reel number | `reelNumber` | 3209-3212 | -2147483648 to 2147483647 |
| Data traces per ensemble | `dataTracesPerEnsemble` | 3213-3214 | -32768 to 32767 |
| Aux traces per ensemble | `auxTracesPerEnsemble` | 3215-3216 | -32768 to 32767 |
| Sample interval original | `sampleIntervalOrig` | 3219-3220 | 0 to 65535 |
| Samples per trace original | `samplesPerTraceOrig` | 3223-3224 | 0 to 65535 |
| Ensemble fold | `ensembleFold` | 3227-3228 | -32768 to 32767 |
| Trace sorting | `traceSorting` | 3229-3230 | -32768 to 32767 |
| Vertical sum code | `verticalSumCode` | 3231-3232 | -32768 to 32767 |
| Sweep frequency start | `sweepFreqStart` | 3233-3234 | -32768 to 32767 |
| Sweep frequency end | `sweepFreqEnd` | 3235-3236 | -32768 to 32767 |
| Sweep length | `sweepLength` | 3237-3238 | -32768 to 32767 |
| Sweep type | `sweepType` | 3239-3240 | -32768 to 32767 |
| Sweep channel | `sweepChannel` | 3241-3242 | -32768 to 32767 |
| Sweep taper start | `sweepTaperStart` | 3243-3244 | -32768 to 32767 |
| Sweep taper end | `sweepTaperEnd` | 3245-3246 | -32768 to 32767 |
| Taper type | `taperType` | 3247-3248 | -32768 to 32767 |
| Correlated | `correlated` | 3249-3250 | -32768 to 32767 |
| Binary gain recovered | `binaryGainRecovered` | 3251-3252 | -32768 to 32767 |
| Amplitude recovery | `amplitudeRecovery` | 3253-3254 | -32768 to 32767 |
| Measurement system | `measurementSystem` | 3255-3256 | -32768 to 32767 |
| Impulse polarity | `impulsePolarity` | 3257-3258 | -32768 to 32767 |
| Vibratory polarity | `vibratoryPolarity` | 3259-3260 | -32768 to 32767 |
| Extended data traces per ensemble | `extDataTracesPerEnsemble` | 3261-3264 | 0 to 4294967295 (Rev 2 only) |
| Extended aux traces per ensemble | `extAuxTracesPerEnsemble` | 3265-3268 | 0 to 4294967295 (Rev 2 only) |
| Extended sample interval original | `extSampleIntervalOrig` | 3281-3288 | any number (Rev 2 only) |
| Extended samples per trace original | `extSamplesPerTraceOrig` | 3289-3292 | 0 to 4294967295 (Rev 2 only) |
| Extended ensemble fold | `extEnsembleFold` | 3293-3296 | 0 to 4294967295 (Rev 2 only) |
| Time basis code | `timeBasisCode` | 3511-3512 | -32768 to 32767 (Rev 2 only) |

A set is kept in the project as `(outputBinaries (binary "Survey" (field "jobId" "7")))`, with
the field names of the second column.
