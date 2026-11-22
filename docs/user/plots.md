# What each plot tells you

**Right-click any plot and choose Explain.** Every plot has it: the Seismic plot, the spectrum, spectrogram, envelope, phase, correlation, vibrator signature and f-k windows (each plot of a window on its own), the map, the header graph, the previews in Generate and in a reference's window, and each plot of Compare. A popover says what that plot shows, what it is computed from, how to read it and what can mislead; Esc closes it. Where right-drag already zooms, a right click that does not drag opens the menu; the Seismic plot's and the map's menus end with Explain.

The text names the settings in force: your filters, the reference, the units. The sections below give each text without a window's settings, as it reads in general. An agent reads the same words in `state`, as `explain`.

## Seismic plot

**Shows.** One wiggle per trace: its amplitude swings sideways from its baseline, with the positive lobes filled. Traces run across the plot in the order shown (the display header names each one), and time runs down it, in ms.

**Computed from.** The samples of the Seismic traces of the record on show. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set. Traces in the file's order. The display gain sets which amplitude is drawn at full strength; the file is never changed.

**Reading it.** Events that run smoothly across neighbouring traces are signal (first arrivals, reflections). A trace that stays flat is dead or silent. A trace far stronger than its neighbours, or a spike over all times, is noise. A trace whose swings mirror its neighbours' may have its polarity reversed.

**Careful.** Amplitudes past the gain's full scale are clipped flat, so strong traces look alike. Wiggles keep each pixel's largest and smallest sample when zoomed out. Compare traces under one gain.

## Spectrum: amplitude

**Shows.** Frequency (Hz) across, from 0 Hz to Nyquist, and amplitude in dB, 0 dB at the larger peak of the raw and processed curves up. Curves: raw is the traces as recorded, with their own filters; processed is the same through the plot's filters.

**Computed from.** One trace, or the power average of several. Over the whole trace, demeaned, tapered 10 % at each end and zero padded. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** Energy should sit in the band the source makes. A hole or a sharp drop shows a missing band; a narrow spike (50 or 60 Hz and its multiples) is power-line noise; a processed curve under the raw one shows what your filters remove.

**Careful.** The window's length sets the frequency step: a short window cannot show low frequencies. Averaging many traces hides a single bad one.

## Spectrum: phase

**Shows.** Phase in degrees up, against frequency in Hz across, for one trace. The phase followed along frequency without jumps: a delay is a straight slope, a sweep a curve.

**Computed from.** The same window, filters and trace as the amplitude above it; phase is measured from the window's first sample, and drawn only where the amplitude is within 60 dB of that curve's peak. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** A straight slope means a pure time delay; a flat line means none. A sweep's phase climbs steeply because its delay grows with frequency (a linear sweep is a parabola); for vibrator QC, read the phase against the pilot in the vibrator signature plot.

**Careful.** Move the window's start and every slope changes: compare phase only between plots cut the same way. Where there is no line the amplitude is too small for the phase to mean anything.

## Spectrogram

**Shows.** Time in ms across, frequency in Hz up; the colour is the amplitude in dB below the largest amplitude in the picture (0 dB is the brightest cell). One cell is one frame and one frequency bin.

**Computed from.** The traces chosen. Each trace's mean is removed first. Hann frames of the length set above (Hann), overlapping by the overlap set above. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** A sweep is a line climbing (or falling) across the picture; a vertical streak is a short broadband burst such as a spike; a horizontal band is a steady tone such as power-line noise; a band that fades shows lost energy at those frequencies.

**Careful.** A longer frame resolves frequency finer (about 2 / W kHz for a frame of W ms) but blurs time. Colours are relative to the one brightest cell, not absolute amplitude.

## Envelope: amplitude and envelope

**Shows.** Amplitude against time in ms: the trace as a line, and its envelope (the trace's strength whatever its sign) over it.

**Computed from.** The first trace chosen. The envelope is the size of the trace's analytic signal (the trace and its Hilbert transform). Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** The envelope should follow the peaks of the trace smoothly. A sweep has a flat envelope between its tapers; a sudden drop or a spike in it shows a dropout or a burst.

**Careful.** Only one trace is shown, the first chosen. The envelope rings near abrupt starts and ends.

## Envelope: instantaneous phase

**Shows.** The trace's own instantaneous phase in degrees (-180 to 180) against time in ms.

**Computed from.** The first trace chosen. The angle of the trace's analytic signal; no value where the envelope is zero. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** A steady signal makes a sawtooth that wraps at ±180°; its steepness is the frequency. Where the sawtooth steepens or flattens the frequency changes, as through a sweep; irregular jumps mean noise or no signal. It turns once per cycle: choose a reference to compare.

**Careful.** The phase wraps, so a jump from +180° to -180° is not an event. A sweep's own phase moves a lot; that is not a fault, nothing is compared.

## Envelope: instantaneous frequency

**Shows.** Instantaneous frequency in Hz against time in ms.

**Computed from.** The first trace chosen. The step of the instantaneous phase per sample; left out where the envelope is more than 60 dB below its peak. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** A linear sweep is a straight line from its start frequency to its end frequency. A line that wanders or jumps means the signal is not the sweep, or carries noise.

**Careful.** Frequency is not defined where the signal is weak, so the line has gaps there; at the two ends of the trace there is no value. The step is taken over two samples, so a frequency above a quarter of the sampling rate wraps and reads negative.

## Phase spectrum: amplitude

**Shows.** Amplitude in dB below its peak (0 dB at the top) against frequency in Hz.

**Computed from.** The first trace chosen. The whole trace, its mean removed, with no taper, zero padded to four times its length; phase is drawn only where this curve is within the dB set above dB of its peak. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** It tells where the phase below can be trusted: the phase means something only where the amplitude is high.

**Careful.** The whole trace is used, not the part shown in the Seismic window.

## Phase spectrum: phase

**Shows.** Phase in degrees up, against frequency in Hz across, for one trace. The phase followed along frequency without jumps: a delay is a straight slope, a sweep a curve.

**Computed from.** The first trace chosen. Phase from the trace's first sample, the trace's mean removed and zero padded to four times its length, drawn where the amplitude is within the dB set above dB of its peak. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** A straight slope means a pure time delay; a flat line none. A sweep's phase climbs steeply because its delay grows with frequency (a linear sweep is a parabola); for vibrator QC, read the phase against the pilot in the vibrator signature plot.

**Careful.** Phase depends on where the trace starts. Where there is no line the amplitude is too low for the phase to mean anything.

## Cross-correlation: correlation

**Shows.** How well each trace matches the reference, up (1 is the reference's own shape whatever its amplitude, -1 its mirror image), against the time shift in ms across, one line per trace and its envelope over it.

**Computed from.** The traces chosen (the first eight at most). Against the reference chosen in References (a stored trace, a generated sweep, or the record's own pilot), or, when you pick it in the window, the record's own vibrator reference trace (code 21). Lags within ±the span set above of zero. Raw: the plot's filters and a trace's own filter are not applied against a reference, on either side (the raw trace against the raw reference). A reversed polarity is applied as set. A trace that is the reference delayed by T peaks at +T.

**Reading it.** One sharp peak at 0 ms near +1 means the trace has the reference's shape and timing. A lower peak means a different shape; a peak away from 0 is a time shift of that many ms (a positive shift: the trace arrives after the reference). A peak near -1 means reversed polarity. The words under the plot give each trace's best match (the envelope's peak: the shape's match whatever the phase turn), its shift between samples and its phase turn ("rotated 90°", "reversed polarity"); under 0.3 there is no clear match, and a peak at an end of the lags means the shift is past them. The reference's own trace, among others, is said so and not drawn.

**Careful.** The envelope peaks at the delay even when the phases of trace and reference differ, where the line itself peaks lower. A different reference gives a different picture.

## Cross-correlation: amplitude to the reference

**Shows.** Amplitude ratio in dB up, against frequency in Hz across: each trace's amplitude over the reference's; 0 dB is the same amplitude.

**Computed from.** The traces chosen. Against the reference chosen in References (a stored trace, a generated sweep, or the record's own pilot), or, when you pick it in the window, the record's own vibrator reference trace (code 21). Drawn only where the reference has energy, within the dB set above dB of its peak. Raw: the plot's filters and a trace's own filter are not applied against a reference, on either side (the raw trace against the raw reference). A reversed polarity is applied as set.

**Reading it.** A flat line near 0 dB means the trace has the reference's spectrum. A line that falls with frequency means high frequencies are lost; a step shows a band that is weaker or stronger.

**Careful.** A ratio is only as good as the reference's energy: near the ends of its band the values are noisy.

## Cross-correlation: phase to the reference

**Shows.** Phase difference in degrees up, against frequency in Hz across: each trace's phase minus the reference's. Shown absolute (0 to 180 degrees; the bracketed value is the signed one); the Phase drop-down above the plot changes it.

**Computed from.** The traces chosen. Against the reference chosen in References (a stored trace, a generated sweep, or the record's own pilot), or, when you pick it in the window, the record's own vibrator reference trace (code 21). Drawn where the reference has energy, within the dB set above dB of its peak. Raw: the plot's filters and a trace's own filter are not applied against a reference, on either side (the raw trace against the raw reference). A reversed polarity is applied as set.

**Reading it.** A flat line at 0° means no phase difference. A straight slope means a time delay (a delay T reads -360° × frequency × T). A flat line at 180° means reversed polarity.

**Careful.** A phase is only known to a turn: Absolute shows its size, so it never jumps between -180° and 180°; Signed keeps it within 180° of its own mean.

## Vibrator signature: phase to the reference

**Shows.** Phase in degrees up, against sweep time in ms across (a point every 10 ms): the signal judged (GF, or GF (M, B)) measured against the pilot, Ref. Shown absolute (0 to 180 degrees; the bracketed value is the signed one); the Phase drop-down above the plot changes it.

**Computed from.** The traces of the window's roles. Each signal's phase to the reference where the pilot's envelope is within 40 dB of its peak. Raw: the plot's filters and a trace's own filter are not applied against a reference, on either side (the raw trace against the raw reference). A reversed polarity is applied as set. A stretch in the error colour is a window past a limit of the verdict.

**Reading it.** A ground force within a few degrees of 0° along the sweep means the vibrator follows the pilot. A drift means poor control; a steady 180° means the polarity is reversed (see Polarity).

**Careful.** The values are as recorded, with no calibration. M and B take one polarity as a pair, because the baseplate moves against the mass.

## Vibrator signature: force

**Shows.** Force against sweep time in ms: the ground force's fundamental amplitude and its peak.

**Computed from.** The traces of the window's roles. The fundamental is tracked along the pilot's frequency. Raw: the plot's filters and a trace's own filter are not applied against a reference, on either side (the raw trace against the raw reference). A reversed polarity is applied as set. A stretch in the error colour is a window past a limit of the verdict.

**Reading it.** A steady fundamental through the sweep is a vibrator putting out constant force. Dips mean lost output or hold-down; a peak far above the fundamental means distortion or bouncing.

**Careful.** Values are as recorded: the axis names the unit, the file's own units unless its headers say force.

## Vibrator signature: force from M and B

**Shows.** GF (M, B), the ground force generated from the masses' accelerations, against sweep time in ms: its fundamental amplitude and its peak.

**Computed from.** The traces of the window's roles. GF (M, B) = Mr·a(M) + Mb·a(B). Needs the reaction mass and the baseplate mass, both entered above. Raw: the plot's filters and a trace's own filter are not applied against a reference, on either side (the raw trace against the raw reference). A reversed polarity is applied as set.

**Reading it.** It should follow the recorded ground force's shape. A large difference between the two means a wrong mass or a bad accelerometer channel.

**Careful.** Without the accelerometers' sensitivities this force is uncalibrated and on an axis of its own: do not compare its level with the recorded force, and the force limits are in % of the judged signal's own 100 % force.

## Vibrator signature: frequency

**Shows.** Instantaneous frequency in Hz up, against sweep time in ms across: the pilot's (Ref) and the ground forces'.

**Computed from.** The traces of the window's roles. Each signal's frequency is tracked along the sweep. Raw: the plot's filters and a trace's own filter are not applied against a reference, on either side (the raw trace against the raw reference). A reversed polarity is applied as set.

**Reading it.** The ground force's line should lie on the pilot's. A gap between them means the vibrator does not follow the sweep.

**Careful.** Tracking is lost where a signal is weak, which leaves gaps.

## Vibrator signature: distortion

**Shows.** Distortion in % up, against sweep time in ms across: the total harmonic distortion (THD) of each ground force, and each harmonic (H2 up to the highest harmonic set) of the ground force as a % of its fundamental.

**Computed from.** The traces of the window's roles. THD is the in-band distortion a vibrator controller reports: it sums the harmonics, from the 2nd, whose frequency stays within the top frequency box (the sweep's top, Hz); where none is in band it is 0. A harmonic above 80 % of Nyquist is never measured. Raw: the plot's filters and a trace's own filter are not applied against a reference, on either side (the raw trace against the raw reference). A reversed polarity is applied as set. A stretch in the error colour is a window past a limit of the verdict.

**Reading it.** Lower is better. A smooth low THD is a clean sweep; a rise at one point is a resonance or a stroke limit; one harmonic standing out is a specific fault.

**Careful.** Distortion falls to 0 in the later part of a sweep, where the 2nd harmonic is above the top frequency: that is how the controller reports it. A wrong top frequency changes every number (the box and the verdict use it). Read from the reference's own samples when nothing is typed, it is marked uncertain, with how far it could be off, when noise hides the end of the sweep or its taper is long and the sweep fast.

## f-k

**Shows.** Wavenumber (cycles per km or per kft with a regular spacing and a length unit, else per trace) across, frequency in Hz up; the colour is the amplitude in dB below the largest value.

**Computed from.** The traces chosen (4 at least). A box of the whole time of the traces and every trace, each trace's mean removed, tapered 10 % at each end in both directions. Through the filters set in the Seismic window, if any are on. A trace's own filter and a reversed polarity are applied as set.

**Reading it.** An event of constant speed lies on a straight line through the origin, steeper for a faster one: its slope is the apparent velocity. Slow events such as ground roll lie at high wavenumber, reflections near the frequency axis.

**Careful.** Wavenumbers past the traces' spatial Nyquist wrap around. An irregular spacing makes the axis per trace, and the picture only a guide.

## Node orientation

**Shows.** The node's roll (about X, inline), pitch (about Y, crossline) and azimuth (about Z, down) in degrees (up), for each trace in the order the plot shows them (across): three lines.

**Computed from.** The traces the plot shows. The orientation header each trace carries: no samples are read, and the plot's filters do not matter. A trace without one leaves a gap in the lines. One point is drawn per trace as shown, so a record with several components per shot repeats each reading once for each component.

**Reading it.** A constant line is a node at rest. A step or a drift in the lines means the node moved (it was bumped, dragged or settled) at that trace; the traces after it were recorded in the new orientation.

**Careful.** Azimuth jumps where it wraps past 180 or 360 degrees without the node having moved. A header may state an orientation that was not measured.

## Header graph

**Shows.** The value of the graphed column (up) for each row of the table, the rows in the order shown (across): a band from the least to the most of each run of rows, and a line along the most.

**Computed from.** The rows of the record shown or the whole file, sorted and narrowed as the table is. The rows on screen in the table are shaded.

**Reading it.** A smooth line is a steady header; steps are changes (a new line, a new record); a spike is one trace that differs, often a mistake in the headers.

**Careful.** Many rows share a pixel: a narrow band hides single traces inside it (it keeps each run's least and most).

## Map

**Shows.** Sources and receivers at their survey coordinates, north up, at equal scale, with no basemap. Discs are the surveyed positions (Preplot), rings the positions the seismic files carry (Recorded).

**Computed from.** The survey files you loaded and the open files' own positions. The record on show is marked on top, its source larger and outlined. No QC filter is marking stations.

**Reading it.** Receivers should lie in regular lines and sources between or beside them. A station off its line, a gap in a line, or two stations on one place suggests a positioning problem in the files.

**Careful.** Positions come from headers or files and are taken as given, with no check against the real world. Points merge when zoomed out.

## Generate: signal

**Shows.** Amplitude up, against time in ms across: the sample values of the sweep, or the record's pilot, being made, as one line.

**Computed from.** The settings in the dialog, or the pilot trace of the record on show. The whole signal is shown, not the file under QC; nothing is stored until you press Generate.

**Reading it.** A sweep fills its length with a steady swing and ramps up and down over its tapers; a pilot taken from a record looks like the recording of that sweep. A flat or empty line means nothing was cut.

**Careful.** A long sweep at a fine sample interval has far more samples than pixels: each pixel shows the largest and smallest sample under it.

## Generate: spectrum

**Shows.** Amplitude in dB below its peak (0 dB at the top) up, against frequency in Hz across.

**Computed from.** The signal above, whole, transformed with its own sample interval. The axis spans the sweep's band and a quarter more on each side, within Nyquist (a pilot taken from the record: 0 Hz to Nyquist).

**Reading it.** A linear sweep gives a flat spectrum across its band, with ripple at its edges; a boost in dB per octave or per Hz slopes it up or down; tapers round the band's ends.

**Careful.** It is the amplitude only, not the phase.

## Reference window: signal

**Shows.** Amplitude up, against time in ms across: the samples of the reference.

**Computed from.** It is what a correlation against this reference uses; the file under QC is not touched.

**Reading it.** A sweep should look like a sweep: a steady swing between its tapers. A flat line or a spike means the wrong trace or window was stored.

**Careful.** Each pixel shows the largest and smallest sample under it when the reference is long.

## Reference window: spectrum

**Shows.** Amplitude (linear, in the reference's own units) up, against frequency in Hz across.

**Computed from.** The reference's whole samples, transformed with their own sample interval.

**Reading it.** It shows the band the reference covers. A correlation can only judge a trace over that band.

**Careful.** Not in dB: a weak band looks flat. Use Generate's preview, or the spectrum window, for dB.

## Compare: signals

**Shows.** Amplitude up, against time in ms across: trace A, trace B, and B minus A when you ask for the difference.

**Computed from.** The two traces set as A and B.

**Reading it.** Matching traces lie over each other and their difference is flat near zero. A gap in time is a timing error, a mirror image is reversed polarity, and a steady scale factor is a gain difference.

**Careful.** A difference needs both traces on one sample grid: other grids show the traces only.

## Compare: spectra

**Shows.** Amplitude in dB up (0 dB at amplitude 1), against frequency in Hz across, for A and for B, up to the lower of the two Nyquist frequencies.

**Computed from.** The traces A and B. Each over the common window, after the alignments you set.

**Reading it.** Matching traces give curves on top of each other. A gap between them is a level difference at those frequencies; a band where one drops is a filter or a bad channel.

**Careful.** A short window cannot resolve low frequencies; B is shown after its flip, scale and shift.

## Compare: phase of B minus A

**Shows.** Phase of B minus A in degrees up, against frequency in Hz across. The phase followed along frequency without jumps: a delay is a straight slope, a sweep a curve.

**Computed from.** The traces A and B. Drawn where both spectra are within 60 dB of their peak.

**Reading it.** A flat line at 0° means the traces are in phase. A straight slope means B is delayed against A. A flat line at 180° means B is reversed.

**Careful.** Phase depends on the window; the wrapped picture jumps at ±180°.

## Compare: correlation

**Shows.** Correlation coefficient up, against lag in ms across, of A with B.

**Computed from.** The traces A and B. Before any alignment you set (flip, scale, shift) is applied.

**Reading it.** One sharp peak near +1 at 0 ms means the traces match. A peak off zero is the delay of B against A, in ms. A peak near -1 is reversed polarity.

**Careful.** Needs both traces on one sample grid; otherwise it is not drawn and the reason is written under the plots.
