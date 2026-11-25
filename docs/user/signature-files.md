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
| Force avg %, THD max %, Limits | the controller's QC numbers; the tripped limit letters are in the warning colour. Their meanings are probable only (T torque motor, M mass displacement, V valve displacement, F force: deduced from the controller's channels, not confirmed; R is not known) |

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

## Writing one out

**File > Output...** writes an open signature file like any other open file. As SEG-Y, the file
on disk matches the image in memory, including the file's own header block. As SEG-D, with none
of the boxes that change samples or which traces are written turned on, that header block and
the channel types are kept too. With one of those boxes on (a polarity reversal, a dropped
trace, a filter, processing, a time shift, or a sort), the header block is not carried, and the
result says so: "The signature file's own header block is not carried when traces are changed."
When a survey join has filled positions into the open file's keys, the notes also say those
positions are not written: "Survey positions joined to this file are not written: the file's own
header block is kept."

## What it says

The Headers window's Summary has a "Signature file" section (and, for a `.dat`, the controller's
QC); its File headers tab starts with the file's own fields and bytes (".dat file" or ".vib file"),
then the SEG-Y it is decoded into, labelled "(in memory)". A `.vib` of another kind, an empty file
and a file that breaks its format are refused in words.

## The Vibrator window on a signature file

Under the verdict one strip of buttons (Roles, Limits..., Details, the settings
wheel and Freeze) holds the controls; the wheel's popover has headed groups, only those that apply to the
file (a signature file asks for no masses: its channels are forces already, or the file's own
weights are used; see "Which ground force the window uses" below). A finding a group holds is also told in words under the verdict, and the wheel
carries a warning sign.

- **The project's vibrator QC configuration.** With a project open, what you set in this
  window is kept in the project as the vibrator QC profile, as you set it, with no button:
  the limits, the statistics window, the harmonics, the accelerometer set, a typed 100 % force
  and drive level, the top frequency typed for the reference, and the name of the file you were
  looking at. The force scale is the one in the settings now, and the reference is the project's
  chosen one. Only the settings you change in a window are written into the profile, so a
  second window cannot wipe what the first one set; a window opened on a file starts from the
  profile, and Messages says once what changed. Nothing read from the file is copied. A change made by an agent, or with no
  project open, is for that run only and is not kept. **Reports > Vibrator QC of a folder** reads
  this configuration; until a window has set it, that window says that vibrator signature QC is
  not configured.
- **Job weights.** The wheel's *Job weights (vibrator QC)* group holds the hold-down, baseplate
  and reaction-mass weights of the job, in kilograms, stored once in the project (inactive with
  no project). The folder QC compares them with each `.vib` header's weights and never applies
  them.
- **Which sweep this is.** A line at the top of the window gives the trigger time in UTC to
  the millisecond, the controller and the vibrator, and, only when the file gives them, the
  line and station and the shot and sweep ids (a point is never derived from the GPS position).
  A `.vib` with its `.dat` takes the `.dat`'s trigger; a `.vib` alone says "began HH:MM:SS UTC".
  The window's title carries the time of day. A click on the line (or its copy icon) copies it as
  one line of text with the file name, a tripped limit and the verdict.
- **Limits the controller tripped.** The controller's table shows the tripped letters with
  probable meanings (T torque motor, M mass displacement, V valve displacement, F force), which
  are deduced from the controller's channels and not confirmed; R's meaning is not known. A
  tripped letter is a finding: "The controller tripped: M (mass displacement, probable)" stays
  under the verdict.

The roles come from the trace codes (reference 21, reaction mass 18, baseplate 19, ground force
20) and no typed mass is applied: trace 4 is the ground force, as the file has it. The trace
pickers are read-only; the polarity can be chosen.

## Which ground force the window uses

In the settings wheel, **Ground force** has two values, for every file that has a ground-force
trace and the traces of the mass and the baseplate (an ordinary SEG-Y, the external converter's
SEG-Y from a signature file, a `.dat`, a `.vib`):

- **In the record**: the trace coded as ground force, as it is. This is what every file does
  until you choose otherwise.
- **Made from mass and baseplate**: the window forms the ground force itself from the two
  traces, `Mr x M + Mb x B`. Its plots, numbers, table, verdict and exports then all use that one;
  the other is still drawn as a second curve under Details. The choice is remembered with the
  roles for the file layout, and in a project it is the vibrator QC profile's, which the folder
  QC follows.

In a project the weights typed for a converter's file (with the choice and the made signal's
100 % force) are **one set for the project**, as a line beside the boxes says: the folder QC uses
them and a new window of a converter's file opens with them. They are not kept per vibrator (use
another project, or change them, for another set). When the profile keeps 100 % forces for more
than one vibrator and the ground force is made, one line in the window, and one above the folder
QC's rows, says that the made signal uses that one set for every vibrator.

What the two traces are decides the weights, so the window treats each kind of file its own way:

| File | What M and B are | "Made from mass and baseplate" |
|---|---|---|
| An ordinary SEG-Y | accelerations of the reaction mass and the baseplate | `Mr x M + Mb x B` with the masses typed in the Masses group (the old behaviour of the window) |
| The external converter's SEG-Y (traces coded 21, 19, 18, 20) | each force channel, mean removed and divided by its own weight, so acceleration-like | the same sum with the two **weights** typed as the masses: they undo the converter's scaling. With the weights typed exactly, the result is the true ground force minus a constant offset (the two channels' means, which the converter removed); a constant factor appears only when the weights are in another unit than the converter's |
| A `.dat` | forces already, weighted by the controller | their plain sum, with no mass applied (typed masses are never used here): the same curve as the file's own ground-force trace |
| A `.vib` | accelerations | the file's own weights from its header times the two accelerations: the same curve as the file's computed ground force |

In a converter file the fourth trace (hold-down weight times the sum of the two channels with
equal weights) is **not** the ground force: it adds two accelerations as if both had the same
weight, and on a poorly coupled sweep it hardly resembles the true one. Choose **Made from mass
and baseplate** and type the file's reaction-mass and baseplate weights to judge the real thing.
The converter codes its two channels the other way round from a `.dat`: the trace coded 19 is the
reaction mass's channel and the one coded 18 the baseplate's. For this layout only, the window opens with
the reaction mass on the trace coded 19 and the baseplate on the one coded 18 (the other way
round from the codes' usual meaning), so no swap is needed; the Masses group says which trace
each mass multiplies (trace number and code), and **Swap mass and baseplate** in Roles still
works and is remembered for the file layout. The role pickers are free for these files. When
the ground force is made and the two weights on the other traces follow the reference clearly
better (a mean phase more than 20° lower), a line says so and nothing is swapped. No such line
does not prove the order is right: when the two channels are nearly in phase with each other,
both orders give much the same phase and the check cannot tell them apart. The folder QC judges a converter's file on the roles the window takes for its layout, a swap
included, and its row carries the same word when the other order fits the reference clearly
better (the polarity stays as recorded there).

For a `.dat` and a `.vib` a line under the choice says that both choices give the same ground
force. When a file cannot follow the choice (no mass or baseplate trace, masses not typed, a `.vib`
whose header gives no weights), a line says why and the ground force in the record is judged.

**Two peaks, and what each says.** The average force is read from the fundamental, in % of the
target as well as in % of the 100 % force ("121 % of 100 % force = 201 % of the 60 % target"). The
peak force limit stays on the raw envelope's peak (the fundamental with its harmonics), and the
fundamental's own peak is shown beside it, both in % of the 100 % force and named apart ("peak
force (with harmonics)", "peak fundamental force"); the Force plot's legend says which curve is
which. The fundamental says whether the drive level is at target; a raw peak well above it points
at distortion or decoupling. The fundamental's peak decides nothing.

**Where the 100 % force comes from.** Beside its box a note says whether it was typed, or set
from a sweep (on which file, at which target force), or taken from the project's QC profile, and
for which vibrator. Set it once on a high-force sweep and every later sweep of that vibrator is
read against it, so a low-force sweep simply reads low. It is kept **per vibrator** in the
project's QC profile: a vibrator with no value says so and is not judged on force (it never takes
another vibrator's); a project saved before keeps its one value as the default for every
vibrator until a vibrator gets its own. Each vibrator's value keeps the unit (and, for
pound-counts, the accelerometer set) it was given in, so one set in counts before the force scale
was given is converted exactly with the scale for the window and the folder QC, and one set in
newtons is not read as counts when the scale is taken away (that vibrator is not judged on force,
and says to set it again). A value kept by a version that had one unit for every vibrator has no
known unit: set it again. With no project open, each vibrator's value is kept the same way for
the run only (never saved): a window moved to another vibrator's sweep has none until you set
it, says so, and is not judged on force; moved back, it has the first vibrator's again. If the file carries the controller's own average force
and it differs from the target you typed by more than 10 percentage points when you press Set from
this sweep, the value is set all the same and a line under the box (and Messages) says what a
sweep at the target would then read. The force in pounds (the force scale) is under **Advanced:
force in pounds**, closed at first: only for those who know the electronics' calibration.
The mass and weight boxes show kg or lb, as the Units setting says (one choice for the window).

**The 100 % force.** The force limits are percent of a 100 % force in the unit of the signal
judged: the recorded ground force's in counts (or newtons with your scale), the made one's in
weight times the traces' unit. The box shows and stores the one for the choice made and its unit
is said next to it. Changing the choice never reuses the other value: when the one needed is
not set, the force limits read "not judged" and say which box to fill. A `.dat` and a `.vib`
share one value (same unit, same curve).

- **The ground force against the reference.** A line under the verdict says how the ground force
  stands to the reference over the judged part, as recorded: "opposite" with its mean phase in
  degrees, "in phase", "neither in phase nor opposite", or "unclear" when it follows the
  reference weakly (little drive, a pulse). Nothing is changed or corrected. When it is opposite
  the line ends with **Roles...**, which opens the roles at the GF row. If you want the analysis to
  take the ground force the other way round, choose **reversed** in the GF polarity (the one
  place to reverse a polarity; M's choice carries B with it): it affects the analysis only (the
  samples and the file stay as recorded), is remembered for
  this file layout (in the project when one is open, else in your settings), and is said in the
  roles' notes ("GF reversed for the analysis: your choice") and in the polarity line. **as
  recorded** takes it back. Automatic polarity is not offered for a signature file. For a `.dat`
  that stores the controller's own correlation, the line also says where its peak at lag 0 lies
  and, when the ground force is opposite and that peak is negative, that the controller counts the
  same relation as in phase.
- **Accelerometer set (a `.vib`).** Set B is the default: the set the `.dat` file records. Set A
  (traces 5 to 7) is the set the controller's QC report follows, probably. The choice is this
  window's only; it is not remembered for the next file.
- **Force units.** The ground force is in counts (a `.dat`) or pound-counts (a `.vib`) until you
  give a scale in the settings wheel (Force): counts per lbf for a `.dat`, the accelerometer constant for
  a `.vib` (with the header's sensitivity of the set judged). The force then reads in newtons
  (pounds-force with the Units setting), for the display and the verdict only; the samples stay as
  recorded. The scale is a local setting and ships with nothing. With a scale, the 100 % force
  is the controller's target force (a `.dat`, once you have typed the drive level in this window)
  or the header's hold-down weight (a `.vib`), unless you typed one.
- **The drive level (Target force %).** On a signature file's window the box is empty until you
  type the level the sweep was set to; the limits then take 100. It belongs to the window: it is
  not remembered for the next window, it follows the window to the next file, Reset options and
  clearing the box empty it again.
- **The controller's QC beside this window's.** A table gives the controller's force, THD and
  phase numbers and the limits it tripped next to this window's; a `.vib` shows its `.dat`'s
  (when the pair is known), headed "from the .dat of this sweep". The controller's force numbers are % of the hold-down weight, and this window's are given
  on that base too (% of the 100 % force, whatever the drive level), compared only when the 100 % force
  comes from the file itself; the THD is defined differently
  by the controller (compare its trend, not its value); the phase compares once the polarity is as
  the controller treats it.
- **The header's weights (a `.vib`).** In the settings wheel, under "Weights from the header", the window shows the hold-down, baseplate and
  reaction-mass weights and the two accelerometer sensitivities the header states. The reference
  scaled to a force depends on the hold-down weight, which differs with the vibrator type the
  controller's electronics are set up for. The same values are given per vibrator across the
  listed folder, with a finding in words when one vibrator's sweeps state different weights, or
  when a single vibrator's weights differ from those the others share (the controller may be set
  up for the wrong vibrator type). When the weights are not all alike and no single odd one can
  be named (two vibrators, three all different, two and two), the finding says how many sets of
  weights the vibrators state and lists each with its vibrators, naming none as odd. A difference
  in the accelerometer sensitivities alone is told in the same way, as sensitivities. Sweeps whose
  vibrator is not known are listed and not compared. It is a finding only: nothing is corrected
  or rescaled.
- **A typed 100 % force** keeps the unit it was typed in (counts, pound-counts or newtons) and
  belongs to its window. It is converted only from the file's own unit (counts for a `.dat`,
  pound-counts for a `.vib`) to newtons when a scale is given. A value in pound-counts belongs to
  the accelerometer set it was typed on. Any other case is not applied, and the window says so
  ("type it again"): another unit, the other set, or a window that followed from a `.vib` to a
  `.dat` or back. The file's own 100 % does not take its place until you clear the box. Reset
  options clears it, with its unit.

## Writing a folder

**File > Output...** lists signature files with the other seismic files. A file that is
not already open is decoded and written as SEG-Y or SEG-D, one file at a time, and then
dropped. The source is not changed. A file that cannot be decoded is a failed row with
the opener's sentence; the rest of the folder is still written. The output name replaces
`.dat` or `.vib` with the output extension. When `a.vib` and `a.dat` would otherwise be
written as one file, each keeps its own extension in the name (`a.vib.sgy`, `a.dat.sgy`),
and the results say so.
