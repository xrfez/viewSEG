# Vibrator signature files (`.dat` and `.vib`)

viewSEG opens one signature file of a vibrator controller, of either kind, like any other file:
File > Open, a click in the Files list, a drop, the command line or a recent file. The kind is
told from the file's first bytes, not its extension. Nothing is written: the file is decoded in
memory and shown in the Seismic window with Aux on.

## A `.dat`

Four traces, one record (the file number), 1 ms between samples (assumed: the file does not state
its interval):

1. the reference;
2. the reaction-mass force channel;
3. the baseplate force channel;
4. the controller's ground force, the plain sum of 2 and 3.

The samples are raw counts, exactly as recorded: no sign is changed. A recording that was
stopped opens with the samples it holds and a warning in Messages ("the recording stopped after
2.538 s of 12.000 s ... Shown as recorded"); it has no QC record.

## A `.vib`

Thirteen traces, one record (the file counter in its name), 0.5 ms between samples (assumed):

| # | Trace |
|---:|---|
| 1 | reference |
| 2, 3 | reaction-mass and baseplate acceleration, set B |
| 4 | ground force from set B, computed |
| 5, 6 | reaction-mass and baseplate acceleration, set A |
| 7 | ground force from set A, computed |
| 8-11 | torque-motor current, valve displacement, mass displacement, drive output (probable) |
| 12, 13 | the two per-cycle values |

Set B is the set the `.dat` file records, so traces 1 to 4 are the same roles as a `.dat`'s. Set A
is the set the controller's QC report follows (probable). A ground force here is computed: the
baseplate weight times the baseplate acceleration plus the reaction-mass weight times the
reaction-mass acceleration, with the weights in the file's header (pound-counts). It is an
estimate.

Time zero is the trigger the program finds in the reference (a linear-sweep fit, to a few
thousandths of a frame). With no fit (a pulse, a sweep that is not linear) time zero is the first
frame, and Properties says so. The clock time is the second the recording began; the trigger
time to the nanosecond is in the `.dat` of the same sweep.

## What it says

The Headers window's Summary has a "Signature file" section (and, for a `.dat`, the controller's
QC); its File headers tab starts with the file's own fields and bytes (".dat file" or ".vib file"),
then the SEG-Y it is decoded into, labelled "(in memory)". A `.vib` of another kind, an empty file
and a file that breaks its format are refused in words.

In the Vibrator window the roles come from the trace codes and no typed mass is applied.
