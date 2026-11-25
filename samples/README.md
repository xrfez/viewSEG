# Synthetic samples

A small synthetic survey for screenshots, documentation and demos. It is
not field data, except the four vibrator signature records in
`samples/vib/field/` (see the README there). Share it freely. Regenerate with `nim samples`
(`tools/sampledata.nim`). The committed files are the ones to open: float
samples are not regenerated in tests.

`samples/vibroseis/` and `samples/impulsive/` are two complete little acquisitions (a
survey, a shot log and the same shots as continuous recordings, shot gathers and receiver
gathers) for trying raw data, slicing and correlation: see the last two sections.

Noise uses processSEG's default seed. Wavelets, the sweep, the noise and
the file writers are parseSEG and processSEG.

## Land (`samples/land/`, US survey feet)

State Plane-sized origin, easting 2 000 000, northing 500 000. SPS headers
say US survey feet (H20) and 0.3048006096 m a unit (H201), NAD83, Texas
South Central.

Receivers: lines 1001 and 1002, stations 101..148, 110 ft apart, lines
440 ft apart. Elevation rises about 0.4 ft per station to the east and 1 ft
from line 1001 to 1002, from about 820 ft.

Sources: line 2001, points 101..106, on easting 2 002 585 (between stations
124 and 125), northings 499 560, 499 780, 500 000, 500 220, 500 440 and
500 660, so the line crosses both receiver lines. Shot depth 30 ft, uphole
time 12 ms. Field records 1..6 are those points in order.

`land.x` relates every shot to all 96 receivers. Channels 1..48 are line
1001 stations 101..148; channels 49..96 are line 1002 stations 101..148.

`shots.sgy` is SEG-Y Rev 2.1, IEEE float, 2 ms, 750 samples (1.5 s): 6
records of 96 traces. Headers carry the field record, channel, source and
receiver line and point, coordinates and elevations in ftUS, and the
source-receiver offset. `shots.sgd` is SEG-D Rev 3.0 of the same six
records and the same seismic samples, plus a time-break trace and an
uphole trace (a pulse at 12 ms) on each record. Recording time is
2026-03-01 00:00:00 UTC, then 30 s apart.

| Event | Velocity | Zero-offset time |
|---|---|---|
| Direct wave | 2 500 ft/s | 8 ms |
| Refraction | 7 000 ft/s | 60 ms |
| Reflection | 6 500 ft/s | 220 ms |
| Reflection | 9 500 ft/s | 520 ms |
| Ground roll | 850 ft/s | 0 |

The direct wave, refraction and reflections are Ricker wavelets (40, 25,
30 and 22 Hz). Ground roll is a 10 Hz and a 14 Hz linear train, plus a
ringing tail every 100 ms. Light noise is added.

Record 3, for QC:

| Channel | Station | What is wrong |
|---|---|---|
| 12 | line 1001, station 112 | Dead: zeros, flagged dead |
| 28 | line 1001, station 128 | Polarity reversed |
| 64 | line 1002, station 116 | Strong 60 Hz added |

`shotlog.csv` is 200 invented shots on line 10, points 1000..1199, comma
separated, with a plain header. Times start at 2024-03-01 00:00:00 UTC and
step 10 s. X and Y are small invented metres near (1000, 2000), not a
survey. Row 4 (point 1003) has sentinel source depth -999.9; row 6 (point
1005) leaves water depth blank.

## Vibroseis (`samples/vib/`)

The same foot grid. One source, land point 2001/103, and receiver line
1001 stations 101..148. The reflectivity is the land events above, as
spikes at those travel times. Each seismic trace is an 8 s linear sweep,
8-80 Hz, with 300 ms tapers, convolved with that reflectivity, plus 3 s of
listen. Sample interval 4 ms.

`vib_uncorrelated.sgd` is one SEG-D Rev 3 record: 48 seismic traces, the
pilot, and a weighted-sum ground force 6° ahead of the pilot with an 8%
second harmonic and a 4% third. Reaction-mass and baseplate traces are not
in the file: the library can form a ground force from those accelerations,
and it can build a sweep with a phase lag and harmonics, but it has no
proc that produces the two accelerometer traces for a given sweep.
Recording time 2026-03-01 12:00:00 UTC.

`vib_correlated.sgd` is that record correlated with the pilot (processSEG),
750 samples (3 s). The auxiliary trace is the pilot's autocorrelation.

## Vibrator signature (`samples/vib/vib_signature.sgd`)

One vibrator, six sweeps, four signals: the reference (R, the pilot), the
weighted-sum ground force (GF), the reaction-mass acceleration (M) and the
baseplate acceleration (B). Open it with `bin/viewSEG samples/vib/vib_signature.sgd`.

To try it: show the record, switch Aux on (all 24 traces are auxiliary, so the
panel is empty until then), select four adjacent traces (sweep 1 is traces 1-4,
sweep 2 is 5-8, and so on: R, GF, M, B in that order), then New plot, vibrator
signature, in the right-click menu. The plot's default roles are the window's
positions 0 to 3 (Ref, GF, M, B), so nothing needs changing; the two masses are
typed in its window.

SEG-D Rev 3.0, IEEE float, one record of 24 traces, a receiver gather: one
receiver (line 9001, point 1), the sweep is the source. Across the record the
traces read R, GF, M, B, R, GF, M, B, ... : sweep 1's four, then sweep 2's, up
to sweep 6's. Each trace has its own channel type (pilot 0x98, measured force
0x94, mass 0x99, baseplate 0x95), its sweep's source point 101..106 (101 for
traces 1-4) and its recording time. The traces are 9 s: the 8 s
linear sweep (8-80 Hz, 300 ms tapers, 4 ms) and 1 s of listen, 2250
samples. Sweep `n` has source point 100 + n, recording time
2026-03-01 12:10:00 UTC + 20 s a sweep, and the traces are numbered 1..24 in file
order.

M and B are made so that the weighted sum is exact: B is a sweep with its own
phase and harmonics, M = (GF - Mb * B) / Mr, with reaction mass Mr = 3600 kg
and baseplate Mb = 1800 kg (the values to type into the plot). GF amplitude
60 000 (N); B amplitude 12 (m/s2). Seeded noise is on GF and B.

| Sweep | GF phase (deg) | 2nd harmonic | 3rd harmonic | Note |
|---|---|---|---|---|
| 1 | 2 | 2 % | 0 | Clean |
| 2 | 4 | 5 % | 1 % | |
| 3 | 6.5 | 9 % | 2 % | |
| 4 | 9 | 15 % | 4 % | |
| 5 | 12 | 24 % | 7 % | Out of tolerance: about 12 deg, THD 25 % |
| 6 | 6 | 6 % | 2 % | GF falls to 40 % for 0.5 s (3.75-4.25 s) |

## Ocean-bottom nodes (`samples/obn/`, metres)

UTM-sized origin, easting 500 000, northing 5 800 000. SPS headers say
metres. One receiver line, 3001, stations 101..124, 50 m apart, on the
seabed at 60 m. Four airgun points, line 4001 points 101..104, 100 m
apart, centred on the nodes, source depth 6 m. `obn.x` lists channels
1..93 step 4, four components at each station.

`obn.sgd` is SEG-D Rev 3.0, 24-bit integer, 2 ms, 1000 samples (2 s), four
records. A unit amplitude is 10 000 counts. Each station is hydrophone,
vertical, inline, crossline (sensor types 1, 2, 3, 4). Recording time
2026-03-02 00:00:00 UTC, then 60 s apart.

Water velocity 1 500 m/s. A flat reflector at 333 m gives a zero-offset
reflection at 400 ms. The receiver ghost is that arrival plus 80 ms, the
two-way time through 60 m of water.

| Arrival | Where | Polarity |
|---|---|---|
| Direct wave | Hydrophone and vertical | Opposite (down-going) |
| Reflection | Hydrophone and vertical | Same (up-going) |
| Ghost, +80 ms | Hydrophone and vertical | Opposite (down-going) |
| Converted wave, 1 000 m/s below the seabed | Mostly inline, weak on the crossline | Follows the offset |

Light noise is added.

## Ocean-bottom receiver gathers (`samples/obn/obn_receiver.sgd`, metres)

The same survey, written as a receiver gather and with the sensors turned: SEG-D
Rev 3.0, 24-bit integer, 2 ms, 1000 samples, four records, one per node (nodes
101..104 of line 3001, 50 m apart). A record's 32 traces are the eight shots that
node recorded (line 4001, points 101..108, 100 m apart, centred on the four nodes,
60 s apart from 2026-03-02 01:00:00 UTC), each with its four components in the order
hydrophone, vertical, inline, crossline (sensor types 1..4), so trace `4n + c` of a
record is shot `n`, component `c`. Each trace carries the node's orientation header (constant over a record but for node 104, below).
Trace order, geometry and arrivals are those of `obn.sgd`; the hydrophone is not
affected by the orientation.

The vertical, inline and crossline traces are recorded in the node's own frame and are
not rotated back (the header says the rotation is not applied). Angles are stored in
radians in the file and given here in degrees. Roll is about X (inline), pitch (tilt)
about Y (crossline), azimuth about Z (down, clockwise seen from above); the sensor
axes are R = Rz(azimuth) Ry(pitch) Rx(roll) in the survey frame, and a sensor reads
R transposed times the survey-frame motion.

| Node | Record | Roll | Pitch (tilt) | Azimuth |
|---|---|---|---|---|
| 101 | 1 | 0 | 0 | 0 |
| 102 | 2 | 0 | 5 | 30 |
| 103 | 3 | 0 | 0 | 90 |
| 104 | 4 | 3, then 7 | 0 | -20, then -5 |

Node 104 is bumped: it keeps the angles of its first row for shots 1 to 4 (traces 1
to 16 of its record) and lies turned by 4 degrees of roll and 15 degrees of azimuth
from shot 5 (traces 17 to 32), its recorded horizontals and vertical rotated with
it. Its orientation headers step there, and the other nodes' stay constant, which
the Node orientation plot (New plot) shows as a step in the roll and azimuth lines.

Node 101 is the reference. On node 103 the converted wave, strong on the inline
trace of node 101, is on the crossline trace.

## The two survey sets (`samples/vibroseis/`, `samples/impulsive/`, metres)

Each folder describes ONE acquisition in five forms that agree with each other: open any
of them with the survey and the shot log and the lines, points, times and field file
numbers (FFIDs) match. The coordinates are invented round numbers: easting 500 000,
northing 4 000 000, SPS headers say metres, WGS 84, zone 15N.

| Folder or file | What it is |
|---|---|
| `survey/` | SPS 2.1: `<set>.s` (sources), `<set>.r` (receivers), `<set>.x` (relations) |
| `shotlog.csv` | one row a shot: time (UTC), GPS time, sequence, FFID, source line and point, index, X, Y, Z, status |
| `continuous/` | one SEG-D file a receiver: the whole recording, 10 s segments one after another |
| `shots/` | one uncorrelated shot gather a shot, as SEG-D (`ffid_<FFID>.sgd`) and SEG-Y (`.sgy`) |
| `receiver-gathers/` | one SEG-D file a receiver: a record per shot, what Slice by shot log cuts from `continuous/` |
| `reference/` | (vibroseis only) the sweep as Analysis > References keeps one |

The survey, the same in both sets. Receiver lines 10 and 20, stations 1001..1012 on
each, 50 m apart, lines 200 m apart: line 10 at northing 4 000 000, line 20 at
4 000 200, easting 500 000 (1001) to 500 550 (1012). Elevation about 100 to 107.5 m.
Source line 30, points 1001..1006 at easting 500 275 (between stations 1006 and 1007),
northings 3 999 850, 3 999 950, 4 000 050, 4 000 150, 4 000 250 and 4 000 350, so the
source line crosses both receiver lines. `<set>.x` lists, for each shot, channels 1..12
as line 10 stations 1001..1012 and channels 13..24 as line 20 stations 1001..1012. No O
records are written: the program derives the receiver-side relations from X.

Shot gathers: SEG-D Rev 3, IEEE float, 2 ms. The 24 receiver traces are channels 1..24
in that order, then two auxiliary traces (channels 25 and 26). The SEG-Y copy is the
program's own conversion of the SEG-D with the survey, so its headers carry the
receiver and source line and point too. Every trace carries the shot's time (the shot
log's UTC row) as its time zero, the FFID as its record number, the source line, point
and coordinates, and the receiver line, point and coordinates. The shot log's GPS
column is the same instant, UTC plus the 18 leap seconds of 2024. The record has no
lead-in: sample 0 is the shot instant.

Continuous files are named `<line>_<station>.sgd` (`10_1001.sgd`). A file is one receiver,
its segments are 5 000 samples (10 s) each, one record each, and each segment's time is the
time of its first sample, so the program reads it as one continuous recording. The
recording runs from the start time below to past the end of the last shot's record. Every
shot's response sits in it at the shot's time, with seeded noise (sigma 0.02) everywhere.

Receiver gathers are what Slice by shot log (SEG-D Rev 3, the record as long as the shot
record, start 0 ms, nearest sample) makes of the continuous files with `shotlog.csv`: the
generator calls the program's own cutter, so a trace is the shot's window of the continuous
recording sample for sample, with the FFID as its record number. A shot gather's trace
for a receiver is the same samples as that receiver's trace for that shot.

Model of the records, both sets: a direct wave with velocity 2 000 m/s (time |x| / 2 000)
and one reflection hyperbola, zero-offset time 800 ms, velocity 2 400 m/s, amplitude
0.6, each placed at its modelled sample (the time rounded to the 2 ms sample).

| Set | Vibroseis | Impulsive |
|---|---|---|
| Continuous recording starts | 2024-03-01 06:00:00 UTC | 2024-03-01 09:00:00 UTC |
| FFIDs | 101..106 | 201..206 |
| Shot times | 06:00:04, then every 8 s to 06:00:44 | 09:00:03, then every 4 s to 09:00:23 |
| Record | 6 s, 3 000 samples (4 s sweep, 2 s listen) | 2 s, 1 000 samples |
| Continuous | 5 segments, 50 s | 3 segments, 30 s |
| Auxiliary traces | pilot (channel 25), ground force (26) | time break (25), uphole (26) |
| Size | about 8.2 MB | about 3.6 MB |

Shot 4 of the vibroseis set (06:00:28 to 06:00:34) starts in one continuous segment and
ends in the next; so does shot 5 of the impulsive set (09:00:19 to 09:00:21).

### Vibroseis

An uncorrelated vibrator record. The source is a linear sweep, 10 to 80 Hz, 4 000 ms, 2 ms,
cosine-squared tapers of 200 ms at each end, amplitude 1, start phase 0. Each arrival is that
whole sweep (the data are the sweep convolved with the arrivals), so a correlation with the
sweep puts a zero-phase wavelet at each arrival's time. Auxiliary trace 1 (channel 25, SEG-D
channel type pilot) is the sweep, then zeros to the end of the record, exactly the samples of
the reference. Auxiliary trace 2 (channel 26, measured ground force) is the same sweep with
amplitude 2, 6 degrees ahead of the pilot and an 8 % second and a 4 % third harmonic.

`reference/` holds `index.nif` and `sweep-1.sgy`, the form Analysis > References keeps a
reference in: a one-trace SEG-Y (IEEE float, 2 ms, 2 000 samples) and the index entry
"Linear 10-80 Hz 4 s". To use it, copy both files into a project's `references` folder (the
reference archive then lists it; choose it with Use). To make the same reference yourself:
Analysis > References > Generate a reference, linear, 10 to 80 Hz, length 4 000 ms,
interval 2 ms, taper 200 ms at the start and the end (cosine squared), phase 0, amplitude 1.
The sweep is also trace "auxiliary 1" of every record, so the rule "A trace of the record",
auxiliary trace 1, start 0, length 4 000 ms, gives the same result as the stored reference.

### Impulsive

The same survey, shot log layout and folders with an impulsive source: no pilot, no sweep
and no `reference/` folder. Each arrival is a Ricker wavelet of 30 Hz, zero phase, its
centre at the modelled sample, amplitude 1 for the direct wave and 0.6 for the reflection.
The two auxiliary traces are the time break (channel 25, a Ricker at 0 ms) and the uphole
(channel 26, a pulse at 12 ms). Records are 2 s.

### The deliberate defects (both sets)

| What | Where | Found by |
|---|---|---|
| Two stations the survey calls for are not in the file | the shot 4 gathers (FFID 104, 204; `.sgd` and `.sgy`): channels 16 and 21, line 20 stations 1004 and 1009 are absent, the other channels keep their numbers | Missing traces: 144 expected, 142 present, 2 missing |
| A dead trace | line 10 station 1005 (channel 5, file `10_1005.sgd`), shot 2 (FFID 102, 202): all zeros, flagged dead in the headers | Trace quality: header-dead; the trace is blank in the plot |
| A noisy trace | the same receiver, shot 5 (FFID 105, 205): noise of sigma 5 (vibroseis) or 0.4 (impulsive) added to the record | Trace quality: noisy |

The defects are in `continuous/` too (the receiver 10_1005 is zero for shot 2's window and
loud for shot 5's), so `receiver-gathers/` have them. The continuous files and the receiver
gathers still hold shot 4's two stations: only the shot gathers lack them.

### Try this

1. Open `samples/vibroseis/shots` (or one `ffid_101.sgd`). **Project > Import survey** with the
   three files of `survey/`, then **Project > Import shot log...** with `shotlog.csv`: the log
   imports with no problems, and its six rows are the six records (FFID, source point, time).
2. Open `samples/vibroseis/continuous/10_1001.sgd`, a continuous receiver recording. With the
   shot log loaded, **Project > Slice by shot log...**, record length 6 000 ms, start 0 ms:
   the file written is the one in `receiver-gathers/` (same samples).
3. Open `samples/vibroseis/receiver-gathers/10_1001.sgd`: a receiver gather sliced at the shots,
   six records.
4. Open a shot gather. In **Analysis > References**, copy `reference/` into the references
   folder and Use the sweep (or Generate a reference with the parameters above, or store
   "A trace of the record", auxiliary trace 1), then Correlate (`C`): the direct wave and the
   reflection come out as zero-phase wavelets at the modelled times (direct wave at
   |offset| / 2 000 s, reflection at the hyperbola).
5. With the survey imported, open `samples/vibroseis/shots` and run **Reports > Missing
   traces**: two stations of FFID 104. **Reports > Trace quality** on the same folder: line 10
   station 1005 has a dead trace (FFID 102) and a noisy one (FFID 105).
6. Do the same with `samples/impulsive` (FFIDs 201..206): there is nothing to correlate (the
   wavelets are already in the shot gathers); slicing, the survey join, Missing traces and
   Trace quality work as above.
