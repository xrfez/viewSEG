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

## A folder of sweeps

The Files window lists signature files with the SEG-Y and SEG-D ones, and reads each file's header
(never a sample) for these columns, which are there while the folder holds a signature file:

| Column | Says |
|---|---|
| Trigger (UTC) | a `.dat`'s trigger, `2001-02-03 04:05:06.789` (the nanoseconds are in the tooltip); a `.vib` with its `.dat` found, the `.dat`'s; a `.vib` alone, `began 04:05:06` in the muted colour (a `.vib` states only the second its recording began) |
| Controller | the serial, four digits: from the file (a `.dat`), the `.dat` of the sweep, or the number of the folder two levels above a `.vib` (a hint, said in the tooltip) |
| Vibrator | the vibrator ID of the QC record (from the `.dat`) |
| Line, Station, Shot, Sweep id | a `.dat`'s, empty where the file gives 0 |
| Length | the samples at the interval in force |
| State | `stopped 2.5 s` (a `.dat` that stopped; the tooltip says how many blocks it holds of those its header announces), `pulse`, `cut short` (a `.vib` that ends inside a frame), or the reason a file cannot be shown |
| Pair | `.vib` on a `.dat` row, `.dat` on a `.vib` row |
| Force avg %, THD max %, Limits | the controller's QC numbers; the tripped limit letters (their meanings are not known) are in the warning colour |

Trigger, Controller and Vibrator are shown; the others are in the column chooser (right-click a
header). A folder of signature files alone starts sorted by Trigger, so a sweep's `.vib` (which
began 0.2 to 1.5 s before its trigger) lies just before its `.dat`. The Controller and Vibrator
drop-downs above the table show one controller's or one vibrator's sweeps; they combine with the
name filter. **Signature files** (a tick beside Include subfolders, on by default, kept in the
settings) turns the signature rows away: they are left out of the table, the arrow keys and
Follow the latest, and the status line counts them ("11 signature files not listed (Signature
files is off)"); the folder is not scanned again. An explicit open always works.

Stepping goes file to file in the table's order and filters: the arrow keys in Files, and Page
Down and Page Up in the Seismic window, which show a sweep's record and so step to the next or
previous file at the end. "Prepare the next file" decodes the next sweep in the background.

**Follow the latest** treats a newest sweep by its trigger, not the file's modification time. A
file still being written is not shown yet. A `.dat` that stopped never completes: it is shown,
flagged, once a newer `.dat` of the same controller is listed, or after it has stayed as it is for
15 s. A click in Files always shows a file at once.

## The other file of a sweep

A `.dat` and the `.vib` of the same sweep are paired by time: the `.dat`'s trigger lies 0.2 to 1.5 s
after the second the `.vib` began; when several `.dat` files fit, the one of the controller whose
serial is the `.vib`'s folder's. File names are never used. One `.dat` pairs with at most one
`.vib`. A listing pairs what it holds (Include subfolders from the controller's folder lists both
kinds of `<serial>/<date>/`). The Seismic window's menu, File and the Summary's Pair line offer
**Open the .vib of this sweep** (on a `.dat`) and **Open the .dat of this sweep** (on a `.vib`),
which show the partner in the same window; the partner's own offer leads back. With the partner
not listed, a background search looks in the file's folder and the controller's folder and its
subfolders (at most 5000 files); when it finds none, Messages says where it looked.

A `.vib` opened with its `.dat` known takes the `.dat`'s trigger time as its clock time (when a
trigger is found in its reference), and its controller and vibrator ID; Properties says so.

## Reopen with options

File > Reopen with options offers a signature file its own options: the **sample interval**
(1000 us for a `.dat`, 500 us for a `.vib`, assumed), for a `.dat` "this unit's force channels are
wired the other way round" (the second and third channels change places; the trace codes stay 21,
18, 19, 20, so the roles follow the data), and for a `.vib` "t = 0 at the first frame" (for when
the estimated trigger is wrong). **Use these for every .dat file of this listing** applies them
to every file of that kind shown from the list, for this run only. The SEG-Y and SEG-D options
are not shown, and an agent's reopen with them is refused.

## What it says

The Headers window's Summary has a "Signature file" section (and, for a `.dat`, the controller's
QC); its File headers tab starts with the file's own fields and bytes (".dat file" or ".vib file"),
then the SEG-Y it is decoded into, labelled "(in memory)". A `.vib` of another kind, an empty file
and a file that breaks its format are refused in words.

## The Vibrator window on a signature file

The roles come from the trace codes (reference 21, reaction mass 18, baseplate 19, ground force
20) and no typed mass is applied: trace 4 is the ground force, as the file has it. The role
pickers are read-only.

- **The ground force against the reference.** A line under the verdict says how the ground force
  stands to the reference over the judged part, as recorded: "opposite" with its mean phase in
  degrees, "in phase", "neither in phase nor opposite", or "unclear" when it follows the
  reference weakly (little drive, a pulse). Nothing is changed or corrected. If you want the analysis to
  take the ground force the other way round, press **Reverse the ground force for the analysis**:
  it affects the analysis only (the samples and the file stay as recorded), is remembered for
  this file layout (in the project when one is open, else in your settings), and is said in the
  roles line ("GF reversed for the analysis: your choice") and in the polarity line. **As
  recorded** takes it back. Automatic polarity is not offered for a signature file. For a `.dat`
  that stores the controller's own correlation, the line also says where its peak at lag 0 lies
  and, when the ground force is opposite and that peak is negative, that the controller counts the
  same relation as in phase.
- **Accelerometer set (a `.vib`).** Set B is the default: the set the `.dat` file records. Set A
  (traces 5 to 7) is the set the controller's QC report follows, probably. The choice is this
  window's only; it is not remembered for the next file.
- **Force units.** The ground force is in counts (a `.dat`) or pound-counts (a `.vib`) until you
  give a scale in the window's Setup: counts per lbf for a `.dat`, the accelerometer constant for
  a `.vib` (with the header's sensitivity of the set judged). The force then reads in newtons
  (pounds-force with the Units setting), for the display and the verdict only; the samples stay as
  recorded. The scale is a local setting and ships with nothing. With a scale, the 100 % force
  is the controller's target force (a `.dat`, once you have typed the drive level: a default nobody typed does not count) or the header's
  hold-down weight (a `.vib`), unless you typed one.
- **The controller's QC beside this window's.** A table gives the controller's force, THD and
  phase numbers and the limits it tripped next to this window's; a `.vib` shows its `.dat`'s
  (when the pair is known), headed "from the .dat of this sweep". The controller's force numbers are % of the hold-down weight, and this window's are given
  on that base too (% of the 100 % force, whatever the drive level), compared only when the 100 % force
  comes from the file itself; the THD is defined differently
  by the controller (compare its trend, not its value); the phase compares once the polarity is as
  the controller treats it.
- **The header's weights (a `.vib`).** Under "Weights from the header" (closed, and open by
  itself when the folder has a finding) the window shows the hold-down, baseplate and
  reaction-mass weights and the two accelerometer sensitivities the header states. The reference
  scaled to a force depends on the hold-down weight, which differs with the vibrator type the
  controller's electronics are set up for. The same values are given per vibrator across the
  listed folder, with a finding in words when one vibrator's sweeps state different weights, when
  its weights differ from those the other vibrators share (the controller may be set up for the
  wrong vibrator type), when exactly two vibrators state different weights (it does not say which
  is odd), or when only the accelerometer sensitivities differ (told as that). Sweeps whose
  vibrator is not known are listed and not compared. It is a finding only: nothing is corrected
  or rescaled.
- **A typed 100 % force** keeps the unit it was typed in and belongs to its window. It is
  converted when a scale makes that exact; otherwise it is not applied and the window says so
  ("type it again").
