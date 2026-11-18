# Synthetic samples

A small synthetic survey for screenshots, documentation and demos. It is
not field data, except the four vibrator signature records in
`samples/vib/field/` (see the README there). Share it freely. Regenerate with `nim samples`
(`tools/sampledata.nim`). The committed files are the ones to open: float
samples are not regenerated in tests.

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
