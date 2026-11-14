# Library coverage

viewSEG is built on parseSEG (files) and processSEG (numerics), and aims to put everything
they can do in front of the user, in a form named by the task rather than the API. This page
maps each library capability to the viewer feature that exposes it. The rule: **every
capability gets a feature**. A row without one is a gap to close, not an acceptable omission;
when a library gains a capability, it gains a row here.

Status values:

| Status | Meaning |
|---|---|
| `built` | The viewer feature exists (it may grow later) |
| `planned` | The viewer feature is designed and scheduled |
| `to plan` | A sensible feature exists but is not scheduled yet |
| `internal` | Plumbing the user never sees directly; the feature column says what uses it |
| `not applicable` | Deliberately not exposed; the reason is given |

## parseSEG

### Opening and indexing

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Open SEG-Y, SEG-D and SEG-2, detected from content | `openSeismic`, `detectKind`, `f.kind`, `f.len`, `f.isOpen` | File → Open, drag and drop, file browser | planned |
| Progress and cancel while indexing | `Progress`, `SegCancelledError`, `ProgressStep` | Progress bar with Cancel | planned |
| Index cache for instant reopening | `OpenOptions.cache`, `saveIndex`, `f.fromCache` | Instant stepping between files in the file browser | planned |
| Per-trace geometry keys, all or on demand | `keys = true`, `ensureKeys`, `traceKeys(traces)`, `traceKeysInto`, `hasKeys` | Map, status bar, gathers (keys built when first needed) | planned |
| Open options: force the standard, verify every header, two's-complement mantissas (SEG-D 8015, SEG-2 format 3), demux folder | `OpenOptions(kind, verify: vfFull, twosComplement8015, demuxDir)` | "Reopen with options…" (offered on a "not recognised" log entry) | planned |
| Multiplexed SEG-D read transparently | `openSeismic` (demux copy), `f.demuxPath`, `dcMultiplexed` | Opens like any file; a log note says a temporary copy is used | planned |
| File facts in one summary | `summary` (`FileSummary`: standard, revision, byte order, format, counts, interval, record length, `coordinateUnits`, `decodable`), `recordCount`, `maxSamples`, `index.prefersFloat64` | "File properties" panel | planned |
| Coordinate reference text | `crsText`, `summary.crsFormat` | File properties; default CRS for the basemap | planned |
| Coordinate units (metres, feet, degrees, arc seconds) | `summary.coordinateUnits`, `CoordinateUnits` | Map axis units; map refuses or converts angular units | planned |
| Library version | `PackageVersion` | About box: parseSEG and processSEG versions | planned |

### Reading samples

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Ranges, selections and sample windows into reused buffers | `readTraces`, `readTracesInto` (window forms), `newTraceTensor`, `maxSamples(f, traces)` | Trace panel tiles, deep zoom | planned |
| Undecodable traces as zero rows, reported | `readTracesInto(..., failedRows)`, `PrefetchChunk.failed`, `failedRows`, `log` | Failed traces marked on the trace axis and listed in the log | planned |
| Read-ahead on worker threads | `newPrefetcher`, `tryNext`, `next`, `seek`, `quickFirst`, `workers`, `maxRingBytes`, `atEnd`, `traceAt` | internal: each trace panel's reader thread | internal |
| Buffer recycling | `nextInto`, `tryNextInto`, `recycle` | internal: scrolling without allocation | internal |
| Chunks of one channel set and interval | `uniform = true`, `uniformRuns` | internal: one `dt` per processing call | internal |
| Processing on the decode worker | `ChunkTransform`, `user` | internal: background QC attribute passes | internal |
| Row views of keys without copies | `rowsOf`, `TraceRows` (`traceOf`, `keysAt`, `numSamples`, `channelSetIndex`, `sub`) | internal: metadata for processing and drawing | internal |
| Sample codecs | `decodeTrace`, `encodeTrace`, `decodeSamples`, `encodeSamples` | internal: used by the readers and writers | internal |
| Trace start time and interval per trace | `startTimeMs`, `startTimeMsInto`, `sampleIntervalUs(i)`, `TraceKeys.t0Ms`, `intervalUs` | Time axis honours delay and mixed intervals | planned |

### Sorting

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Sort by header fields (shot, receiver, CMP, offset, any) | `sortTraces(by[, traces])` | Sort by any raw header field, and gather domains | planned |
| Sort by the viewer's own columns | `sortOrder(columns)` | Plot window: the sort buttons (Line/Station, By Flag, By Component) and "Sort by keys…" over the trace keys (`TraceKeys`, among them `component`), each ascending or descending, sorted by the panel's reader; later a gather by a QC attribute (RMS, pick time, SNR) | built (keys); planned (QC attributes) |

### Headers

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Any field by name | `traceField`, `recordField`, `fileField`, `findTraceField`, `findRecordField`, `findFileField`, `FieldValue` | Status-bar fields, header table cells | planned |
| One field for many traces | `traceFieldColumn`, `traceFieldColumnInto` | Header table columns | planned |
| A header field plotted against the trace axis | `traceFieldColumn` | Header graph strip above the panel (offset, elevation, static) | planned |
| Field catalogue | `fieldNames`, `blockKind`, `fieldByName`, `HeaderBlock` | Column chooser, status-bar field picker | planned |
| Every header block with byte offsets | `traceHeaders`, `recordHeaders`, `fileHeaders`, `HeaderRow`, `copyBytes` | Header inspector with hex pane | planned |
| SEG-Y textual header | `textHeader`, `extendedTextHeaders` | Textual header window | planned |
| SEG-Y extended text stanzas and user data | `index.segy.extended`, `ExtendedTextHeader`, `Stanza`, `UserDataBlock`, `toDescXml` | Textual header window: stanza list, user data tab | planned |
| SEG-Y Layout stanza (fields moved to other bytes) | `layoutOf`, `entriesFor`, `fieldValue`, `initGeometryReader`, `TraceLayout` | Header table shows layout-named fields (`iline`, `xline`, `sht_line`…) | planned |
| Inline and crossline of post-stack volumes | `TraceKeys.inline`, `crossline` | "Go to inline / crossline", inline or crossline sections | planned |
| Datum, uphole and statics fields, scaled | `traceStatics`, `traceStaticsInto`, `TraceStatics` | Statics column group in the header table; statics graph strip | planned |
| SEG-D general, channel set and Rev 3 blocks (position, source description, sensor, time drift, orientation) | `index.segdRecords`, `recordHeaders`, `SegdSourceDescription`, `SegdSensorInfo`, `SegdTimeDrift`, `SegdOrientation` | Header inspector, record tab | planned |
| SEG-2 keyword strings and notes | `seg2Strings`, `seg2Trace`, `noteLines`, typed getters | Header inspector; notes in File properties | planned |
| UTC and GPS time | `TraceKeys.time`, `generalHeaderUtc`, `timestampToUnix`, `gpsMinusUtc` | Status bar: shot time and time within the record | planned |
| Values joined from survey files, by group | `joinedTraces`, `joinedGroups`, `JoinGroup`, `changedGroups` | Header table marks values that came from SPS/P1 | planned |
| Keys revision for stale-data checks | `keysRevision`, `markJoined` | internal: overlays, bins and processed tiles rebuilt when keys change | internal |
| Vendor header blocks decoded by maps | `loadVendorMaps`, `vendorSearchPath`, `decodeVendorAreas`, `VendorRegistry`, `checkVendorMap`, `registerVendorDecoder` | Header inspector shows decoded vendor blocks; Settings → vendor map folders | planned |
| Starting maps for undecoded vendor blocks | `scaffoldVendorMap`, `toNif` | "Create vendor map for this file…" | planned |
| Byte-level codecs (endians, BCD, IBM float, EBCDIC) | `parseSEG/codecs`, `getNum`, `beF32`, … | Hex pane value inspector (selected bytes as int, IBM, IEEE, BCD) | planned |

### Gathers and channels

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Gathers derived from geometry | `gathers`, `classify`, `Gather`, `GatherKind` | Record list, next / previous gather | planned |
| SEG-D channel sets | `channelSets`, `traceEntry(i).channelSetIndex`, `channelType` | Channel chooser | planned |
| Seismic and auxiliary traces | `isSeismic`, `TraceStatus` (`tsAuxiliary`, `tsDead`) | Auxiliary viewer; dead-trace marks | planned |
| Multi-component stations | `componentGroups`, `componentGroupIds`, `isMultiComponent`, `TraceKeys.component` | Components in colour, side-by-side layout | planned |

### Survey files and geometry

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Read SPS 1.0 / 2.1 (S, R, X, O) | `readSps`, `parseSps`, `addSps`, `SpsOptions`, `looksLikeSps` | File → Join geometry…; survey files as map layers | planned |
| Read SEG P1 | `readP1`, `parseP1`, `addP1`, `P1Options` (`angleUnit`) | Join geometry from P1 | planned |
| Survey-file problems | `SurveyGeometry.log`, `SpsFile.log` | Log window | planned |
| Station tables | `table`, `sourceCount`, `receiverCount`, `relationCount` | Map layers per survey file | planned |
| Join by station, with statistics | `applySurvey`, `joinStations`, `JoinStats`, `JoinMatch` | Join geometry: matched / unmatched counts | planned |
| Traces by join outcome (conflict, ambiguous, unmatched) | `joinStations` per trace | Join report: select the traces of each outcome | planned |
| Join options: line names, trailing digits, multi-component, one tape | `mapLine`, `trailingDigits`, `multiComponent`, `tape` | Join geometry dialog, advanced options | planned |
| Relation lookups (the spread of a shot, the shots of a receiver) | `relation`, `relations`, `records`, `expectedChannels`, `recordsAt`, `channelOf`, `relationRuns`, `relationsDisjoint` | Map: hover a source to see its planned spread, a receiver to see its shots | planned |
| Grid unit from the SPS header | `gridUnit`, `GridUnit`, `measurementSystem` | Map axis units; File properties | planned |
| Coordinates from the user's own table | `GeometryTable`, `addSource`, `addReceiver`, `applyGeometry` | Import geometry from CSV | planned |
| Write SPS and P1 (1.0 ↔ 2.1, byte-exact) | `writeSps`, `spsText`, `encodeSps`, `writeP1`, `p1Text`, `encodeP1` | Export survey files (corrected, or in another SPS revision) | planned |
| Receiver-domain relations | `receiverRelations` | Export .ops (receiver gathers) | planned |
| Preview what a geometry write would change | `geometryChanges`, `GeometryChanges` | "Write geometry…" preview step | planned |
| Write joined geometry in place, journaled | `writeGeometry`, `GeometryFields` | Write geometry into the file (undoable) | planned |
| Copy or convert with geometry | `copyWithGeometry`, `convertWithGeometry` | Save a copy with geometry; export SEG-Y with geometry | planned |

### Writing

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Write traces like the input, any subset and order | `openSeismicWriter(path, like)`, `writeTrace(src, trace, samples)`, `headerOverride` | Export processed traces; export the file without killed traces | planned |
| Write with in-memory geometry | `writeTrace(..., keys, fields)` | Export with joined geometry and edits | planned |
| New SEG-Y from keys | `openSeismicWriter(path, SegyOutputOptions)`, `writeTrace(keys, samples)` | Export a selection, a generated pilot or a stack as SEG-Y | planned |
| Per-standard streaming writers | `openSegyWriter`, `openSegdWriter`, `writeSegd`, `openSeg2Writer` | internal: conversion and test fixtures | internal |

### Header edits

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Pending edits saved as a patch | `writeHeaderPatch`, `initHeaderChange`, `HeaderChange` | Inline edits in the header table, saved as a patch | planned |
| Apply a patch or header document (dry run, into a copy) | `importHeaders`, `ImportOptions` (`dryRun`, `outPath`, `force`, `onChange`) | "Apply patch…": preview, then into the file or a copy | planned |
| Export every header as a document | `exportHeaders` | Export headers (NIF) for editing elsewhere | planned |
| In-place editor on the open file | `openEditor(f)`, `setTraceField`, `setRecordField`, `setFileField`, `beginBatch`, `endBatch`, `currentTraceField`, `release` | Edit headers in place (explicit, confirmed) | planned |
| Journal: undo and redo | `rollbackJournal`, `applyJournal`, `readJournal`, `JournalEdit` | Edit history window: list, undo all, redo | planned |

### Streams, tape and multiplexed data

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Tape images (.tap) | `openTapeImageSource`, `buildIndex`, `openSegy`, `openSegd` | Import from tape image to a disk file, then open | planned |
| Tape drives | `newDeviceSource`, `openLinuxTape`, `TapeDevice` | Import from tape drive (Linux `st`, Windows tape) | planned |
| Streaming readers, headers only | `readSegyHeaders`, `readSegdHeaders`, `openSegy`, `openSegd(headersOnly)`, `readSeg2` | internal: tape import, layout-named fields | internal |
| Demultiplexed copy | `demultiplexSegd` | Save demultiplexed copy | planned |
| Records, sinks, memory tape | `RecordCursor`, `DiskSink`, `newMemoryTape` | internal: tests and tape import | internal |
| SEG-D tables of contents | `decodeToc`, `isTocFile` | internal: detection | internal |

### Conversion

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Any standard to SEG-Y, with a loss report | `convertFile`, `ConvertOptions`, `convertSegdToSegy`, `convertSeg2ToSegy` | Convert… (file or folder, progress, cancel, losses listed) | planned |
| SEG-Y revision, byte order, sample format | `convertSegy`, `ConvertOptions(revision, byteOrder, format)`, `targetFormat` | Convert… | planned |
| SEG-D between revisions | `convertSegdRevision`, `SegdConvertOptions` | Convert… | planned |
| To SEG-2, SEG-2 to SEG-D | `convertToSeg2`, `convertSeg2ToSegd` | Convert… | planned |
| Descaled amplitudes (millivolts) | `applyDescale`, `descaleFactor(rec, trace)` | Convert option; readout in counts or mV | planned |

### Diagnostics

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Problems as data with severity, code and location | `DiagLog`, `Diagnostic`, `Severity`, `DiagCode`, `Location`, `f.log` | Log window, filtered by severity | planned |
| Location of each problem | `Diagnostic.loc` (record, trace, field), `offset` | Click a log entry to go to its trace or header field | planned |
| Logs as files | `toNif`, `writeNif`, `readDiagnostics`, `parseDiagnostics` | Log window: save and open; attached to the QC report | planned |
| Exceptions turned into entries | `recordException`, `tryRecord`, `tryRecordFatal` | internal: jobs report failures to the log | internal |

## processSEG

### Core

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Chunk metadata from parseSEG reads | `initChunkMeta`, `chunkMeta`, `intervalMs`, `ChunkMeta` (`isLive`, `sampleTimeMs`) | internal: every processing call | internal |
| Row views and scratch | `rowBlock`, `RowBlock`, `Workspace`, `reserve`, `WorkspaceSize` | internal: allocation-free processing | internal |
| Remove mean or trend | `demean`, `detrend`, `demeanOp`, `detrendOp` | Processing window: remove DC / trend | planned |
| Scale, clip, polarity | `scale`, `clip`, `reversePolarity`, `scaleOp`, `clipOp`, `polarityOp` | Processing window; display polarity (for now a sign on the plot's scale, density and wiggles alike); the wiggles' clip at the trace overlap is the shader's own | planned |
| Top and bottom mutes (time, table, LMO) | `timeMute`, `tableMute`, `lmoMute`, `muteTop`, `muteBottom`, `muteTopOp`, `muteBottomOp`, `muteTimeMs` | Processing window: mutes, drawn as a line on the panel, table picked by clicking | planned |
| Pad tapers | `cosTaperInto`, `taperPads` | internal: filters and padded kernels | internal |
| Fractional shifts | `shiftSamples`, `ShiftInterp` | internal: statics, LMO, NMO | internal |

### Spectra

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Real FFT, batched | `initFftPlan`, `forward`, `inverse`, `forwardLanes`, `inverseLanes`, `nextFastLen`, `gatherLanes` | internal: f-k window, pilot phase | internal |
| Averaged amplitude spectrum of a selection | `initSpectrumPlan`, `averageAmplitudeInto`, `toDbInto`, `binHz` | Spectrum panel, raw and processed | planned |
| Amplitude and phase of one trace | `amplitudeInto`, `amplitudePhaseInto` | Compare pilots: phase difference; phase tab of the spectrum panel | planned |

### Filters

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Trapezoid band-pass, low-cut, high-cut (zero phase) | `bandPass`, `lowCut`, `highCut`, `Corners`, `bandPassOp`, `filterOp`, `initFilterPlan` | Processing window: band-pass | planned |
| Butterworth magnitudes | `butterBandPass`, `butterLowCut`, `butterHighCut` | Processing window: Butterworth | planned |
| Notches and zero DC | `withNotch`, `withZeroDc` | Processing window: notch (mains 50 / 60 Hz) | planned |
| IIR, zero or minimum phase | `initIirPlan`, `iirOp`, `IirPhase` | Processing window: IIR, phase choice | planned |
| Trend handling at the edges | `TrendRemoval` | Processing window, advanced | planned |
| Filter response | `response`, `responseInto`, `gainAt`, `magnitudeAt`, `narrowestRampHz` | Response curve in the processing window, over the spectrum | planned |
| Zoom margins | `requiredMargin`, `impulseLength`, `decodeWindow` | internal: zoomed tiles decode enough samples | internal |
| Parameter checks against Nyquist | `validate`, `nyquistHz` | internal: parameter ranges in the dialog | internal |

### Gain

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Fixed gain in dB | `scaleDb`, `gainDbOp`, `dbToFactor` | Plot window: the gain amount in dB and the Fixed gain, both as the shader's scale; `gainDbOp` in the processing window | built (display); planned (processing) |
| Normalisation per trace or panel (max, RMS, percentile) | `initNormalizePlan`, `normalize`, `normalizeOp`, `panelFactor` | Plot window: gain "Normalized" (`normalizeOp(stat, perTrace)` per trace; per panel the scale alone, from `panelStats`) | built |
| AGC (RMS, mean absolute) | `initAgcPlan`, `agc`, `agcOp` | Plot window: gain "AGC" (the default on pre-stack gathers); processing window: AGC | built |
| AGC gain kept and removed | `agc(..., gains)`, `removeGain` | Show the AGC gain function; undo AGC on export | planned |
| Time-variant gain (knots, tᵖ, exponential) | `knotGain`, `powerGain`, `exponentialGain`, `gainCurveOp`, `initGainCurvePlan`, `applyGainCurve` | Plot window: gain "Exponential" (`exponentialGain`, `powerGain`); processing window: gain curve editor (knots) | built (display); planned (knots) |
| Statistics for display gain and clip | `traceStatsInto`, `panelStats`, `percentileAbs`, `traceStats` | Plot window: clip at a percentile and the Normalized levels (`panelStats`, a shader uniform), Float's level of the data in view (`percentileAbs`); the same reference is full black in density and the full swing (the trace overlap) of a wiggle; per-trace statistics later | built |

### Pipelines and threads

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Editable processing flow | `initPipeline`, `Op`, `add`, `insert`, `delete`, `compile`, `PipelinePlan`, `generation` | Processing window: the flow list, live update | planned |
| Raw kept, processed into a second buffer | `plan.apply(src, dst, meta, ws)` | Raw / processed toggle key | planned |
| Plan parts for own threads | `checkApply`, `partCount`, `partNeedsPanel`, `panelFactorOf`, `runPart` | internal: not needed while the pool is used | internal |
| Worker pool | `newProcessPool`, `pool.apply`, `ping` | internal: live processing on all cores | internal |

### Velocity and moveout

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Linear and hyperbolic moveout ticks | `linearMoveout`, `hyperbolicMoveout`, `moveoutTimesInto`, `moveoutColumnsInto` | Moveout overlay over the gather | planned |
| Moveout from a velocity model or binning | `moveoutTimesInto(field[, binning])`, `moveoutColumnsInto(field, binning)`, `checkSuits` | Moveout overlay from loaded velocities | planned |
| Apparent velocity at a dragged line | `lmoTime`, `nmoTime`, `nmoStretch` | Velocity ruler on the panel and the f-k window | planned |
| Flatten first breaks for display | `applyLmo`, `removeLmo` | "Flatten (LMO)" display toggle | planned |
| Velocity functions and Dix conversion | `constantVelocity`, `gradientVelocity`, `rmsVelocity`, `intervalVelocity`, `vrmsAt`, `vintAt`, `dixIntervalInto`, `rmsFromIntervalInto` | Velocity editor: Vrms knots, Vint shown | planned |
| Velocity fields (2D, 3D) | `initVelocityField`, `vrmsAt(location)`, `vrmsInto` | Velocity quick-look; field section in colour | planned |
| Velocity files (VELF, HANDVEL, CSV) | `readVelocities`, `parseVelocities`, `parseVelf`, `parseHandvel`, `parseVelocityCsv` | File → Load velocities… | planned |

### Statics, NMO and stacking

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Datum statics from elevations | `datumStatics`, `staticMs`, `staticsInto`, `applyStatics` | Processing window: elevation statics (datum, replacement velocity) | planned |
| Statics recorded in the headers | `headerStaticMs`, `headerStaticsInto`, `applyStatics(staticsMs)` | Processing window: apply header statics | planned |
| NMO with stretch mute | `initNmoParams`, `applyNmo`, `nmoInto`, `nmoSlothInto` | NMO preview on CMP gathers with a velocity slider | planned |
| CMP bins (header CDP, line, 3D grid, inline/crossline) | `cdpBinning`, `lineBinning`, `gridBinning`, `inlineCrosslineBinning`, `binOf`, `binAt`, `location` | Bin grid setup for fold maps and stacks; bin grid layer on the map | planned |
| Stack accumulation | `initStackAccumulator`, `add`, `addLive`, `merge`, `stackInto`, `foldInto`, `finishInto` | internal: brute stack | internal |
| Brute stack of a file, with progress and cancel | `bruteStack`, `BruteStackOptions`, `bruteStackMemory`, `StackResult` | Brute stack window; memory estimate before it starts | planned |
| Stack written as SEG-Y | `writeStack`, `stackKeys`, `stackOverrides`, `maxFold` | Save stack as SEG-Y | planned |

### QC

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Geometry flags from the keys | `checkGeometry`, `checkGeometryInto`, `flaggedRows`, `GeometryQc`, `badGeometry` | Survey QC issue list, flags in table and map | planned |
| First-break picking with confidence | `initFirstBreakPlan`, `pickInto` (also on the pool), `FirstBreakParams`, `FirstBreakPick`, `checkPick` | First-break overlay coloured by confidence | planned |
| Refraction fit per shot (swapped receivers, misplaced source) | `fitShot`, `ShotFitParams`, `ShotFit` (`suspect`, `asymmetryMs`, `v1`, `v2`) | Survey QC issue list; fitted model drawn over the picks | planned |
| Windowed SNR per trace | `windowSnrInto`, `WindowSnrParams`, `powerSnrDb`, `windowSnrDb`, `meanPower` | SNR attribute: table column, map colour, flag threshold | planned |
| Coherence SNR of a flattened gather | `coherenceSnrInto`, `coherenceSnrWorkspace` | SNR-against-time plot for an NMO or LMO flattened gather | planned |
| Amplitude flags per trace (dead, clipped, spiky, DC, weak, noisy) | `traceAmplitudeInto` (also on the pool), `AmplitudeParams`, `AmplitudeFlag`, `TraceAmplitude` | Trace flags with thresholds on a histogram | planned |
| Record-level amplitude outliers | `recordAmplitude`, `RecordAmplitude` (`robustZ`) | Trace flags (weak, noisy) | planned |
| Automatic bin grid of a survey | `surveyGrid` | Fold map: grid proposed from the SPS | planned |
| Pre-plot, actual and difference fold | `preplotFold`, `initFoldMap`, `addFold`, `foldDifference`, `FoldMap` | Fold map layers and their difference | planned |
| Fold by offset class and azimuth sector, offset range | `FoldOptions`, `offsetFold`, `azimuthFold`, `offsetMin`, `offsetMax` | Fold map: offset-class and azimuth layers, min / max offset maps | planned |
| Field records against the XPS | `recordCompleteness`, `RecordCompleteness`, `RecordMatch`, `TraceMatch` | Survey QC issue list: missing, unlisted, duplicate stations | planned |
| Missing stations of a record | `RecordCompleteness.missingStations`, `missingRanges`, `lines` | Missing-stations map layer | planned |
| Completeness over many records | `summarize`, `CompletenessSummary` | QC report section | planned |

### Vibroseis

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Sweep tapers (nine shapes) | `initSweepTaper`, `TaperShape`, `applyTaper`, `taperWeight`, `noTaper` | Compare pilots: generated pilot's tapers | planned |
| Sweep generation (linear, dB/octave, dB/Hz, exponential, table) | `linearSweep`, `dbPerOctaveSweep`, `dbPerHzSweep`, `exponentialSweep`, `tableSweep`, `generatePilot`, `sweepSamples` | Compare pilots: generated source | planned |
| Instantaneous frequency and phase | `frequencyAt`, `phaseAt` | Compare pilots: frequency at the cursor | planned |
| Recorded pilot from a trace | `pilotFromTrace`, `pilotFromRow`, `sweepFromHeaders`, `energyAbove`, `initPilot` | Compare pilots: recorded source | planned |
| Pilot resampled to the data | `resamplePilot` | Compare pilots | planned |
| Recorder's instrument filter on a pilot | `InstrumentFilter`, `applyInstrumentFilter` | Compare pilots: "apply recorder filter" | planned |
| Pilot saved with its sweep fields | `pilotKeys`, `sweepOverrides`, `segySweepType`, `segyTaperType` | Compare pilots: save the generated pilot as SEG-Y | planned |
| Correlation of uncorrelated records | `initCorrelationPlan`, `correlateInto` (also on the pool), `correlate` | Correlate records for display | planned |
| Sweep deconvolution | `initCorrelationPlan(mode = cmDeconvolve)` | Correlate records: deconvolve mode | planned |
| Vertical and diversity stack of repeated sweeps | `initRecordStack`, `addRecord`, `RecordStackParams`, `recordStackMemory` | "Stack repeated sweeps" at a source point | planned |

### Continuous recordings

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Cut continuous node data into records at shot times | `initSliceStreams`, `planSlices`, `extractInto`, `sliceKeys`, `SliceShot`, `SliceWindow` | "Cut at shot times…" (shots from SPS / P1 or a list), result as a virtual file | planned |
| Gaps, overlaps and timing errors | `SliceReport`, `gaps`, `overlapCheck`, `timingIssues`, `untimed`, `otherInterval` | Continuous data QC per receiver | planned |
| Clock drift correction | `driftCorrectTimes`, `driftCorrectedTimes` | Node clock drift correction | planned |

### Survey design

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Receiver layout (azimuth, interval, line spacing) | `receiverLayout`, `inlineOf`, `crosslineOf` | Survey summary in File properties; map in the layout frame | planned |
| Patch description (template, clipped records) | `describePatches`, `PatchDescription`, `RecordPatch`, `spreadOf` | Patch QC: template, clipped records on the map | planned |
| X records generated from a template or distance box | `PatchTemplate`, `initPatchTemplate`, `initDistancePatch`, `patchShots`, `generateRelations` | Generate XPS when relations are missing | planned |
| Listed against generated relations | `compareRelations`, `RecordAgreement`, `jaccard`, `listedFraction` | Compare the XPS with the patch: receivers dropped in the field | planned |

## Not exposed

| What | Why |
|---|---|
| parseSEG command line tool (`parseSEG/cli`) | The viewer offers the same operations through menus. |
| `parseSEG/private`, processSEG `survey/relwalk`, `core/sums`, `vibroseis/kaiser`, and procs marked **Internal** (`planKeys`, `finishKeys`) | Not part of either public API. |
