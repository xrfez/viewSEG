# Library coverage

viewSEG is built on parseSEG (files) and processSEG (numerics), and aims to put everything
they can do in front of the user, in a form named by the task rather than the API. This page
maps each library capability to the viewer feature that exposes it. The rule: **every
capability gets a feature**. A row without one is a gap to close, not an acceptable omission;
when a library gains a capability, it gains a row here.

The page is complete by name: every name `import parseSEG` and `import processSEG` give, at
the versions this repository pins, is named in a row's "Library calls" cell (an enum by its
type, its values where they are options). `nim coverage` (`tools/coverage.nim`) checks it
and writes the summary below; the test suite runs the same check (`tests/tcoverage.nim`).
It fails when a library exports a name no row names, when a row says `built` or `internal`
for a name the viewer's source never calls, and when the summary is not the tables'. The
tensor API that parseSEG re-exports is Arraymancer's, and is not listed.

Status values:

| Status | Meaning |
|---|---|
| `built` | The viewer calls it and a user reaches the feature: the row names the menu, window or key (it may grow later) |
| `planned` | The viewer feature is designed and scheduled |
| `to plan` | A sensible feature exists but is not scheduled yet; `priority N` orders the list below |
| `internal` | The viewer calls it and the user never sees it directly; the feature column says what uses it |
| `not applicable` | Deliberately not exposed; the reason is given |

A status can have parts, the most advanced first: `built (the map); planned (the export)`.
Then each name the viewer's source calls has the first part's status, and the others the
next part's.

## Summary

<!-- summary: written by `nim coverage` from the tables below -->

Capabilities are the rows below, each counted by the first part of its status ("in part": built, with a part still planned or to plan). Names are the names each library exports, enum values not counted, each at the most advanced status of the rows that name it.

| Status | parseSEG 0.11.0: capabilities | names | processSEG 0.4.0: capabilities | names |
|---|---:|---:|---:|---:|
| `built` | 38 (22 in part) | 96 | 11 (9 in part) | 45 |
| `internal` | 14 | 34 | 4 | 38 |
| `planned` | 38 | 285 | 53 | 352 |
| `to plan` | 2 | 10 | 1 | 5 |
| `not applicable` | 19 | 354 | 5 | 60 |
| all | 111 | 779 | 74 | 500 |

In the next library release (below): parseSEG: 5 capabilities (5 planned); processSEG: 8 capabilities (4 planned, 4 to plan).

**Still to plan, most useful to field QC first** (the rows whose status says `to plan`, by their priority):

1. **Traces by join outcome (conflict, ambiguous, unmatched)** (parseSEG, Survey files and geometry): a selection per outcome
2. **Read SEG P1** (parseSEG, Survey files and geometry): the implied decimals as an option
3. **Join options: line names, trailing digits, multi-component, one tape** (parseSEG, Survey files and geometry): one tape as an option
4. **Per-trace geometry keys, all or on demand** (parseSEG, Opening and indexing): a large file opened without keys, built when first needed with `ensureKeys`
5. **A vibrator's source description in a SEG-D Rev 3 record** (parseSEG, Header objects and codecs): Vibroseis QC: each record's vibrator type, phase control and phase angle beside the vibrator plots
6. **Receiver layout (azimuth, interval, line spacing)** (processSEG, Survey design): Survey summary in File properties; map in the layout frame
7. **A file's own scales** (processSEG, next release): what the file says of its scales, also without a sensor table
8. **Multiplexed SEG-D read transparently** (parseSEG, Opening and indexing): the open path takes such a file, and parseSEG's note goes to Messages, but no multiplexed file has been opened in the viewer yet
9. **Logs as files** (parseSEG, Diagnostics): a file's problems saved as NIF and opened again, attached to the QC report
10. **Location of each problem** (parseSEG, Diagnostics): a header field
11. **Recorded values in physical units: sensors, masses and recorder scales** (processSEG, next release): Amplitudes in volts, m/s, m/s², Pa or N where the user sets up a sensor table (off otherwise): the readout's unit, the vibrator force plots
12. **Calibration of recorded traces** (processSEG, next release): The sensor table's rules applied per trace, before any gain; what each trace was converted with, and what could not be
13. **Calibration in a pipeline** (processSEG, next release): The display pipeline with the calibration first, its plots labelled in the unit

<!-- end of summary -->

## parseSEG

### Opening and indexing

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Open SEG-Y, SEG-D and SEG-2, detected from content | `openSeismic`, `detectKind`, `f.kind`, `f.len`, `f.isOpen`, `SeismicFile`, `SeismicKind`, `f.path`, `close` | File → Open file..., Open files..., Open folder..., Open recent; a file dropped on the window; a click or the arrow keys in Files; files named on the command line. Each is opened read-only on a job; Files tells the kinds apart with `detectKind` | built; not applicable (`isOpen`: the viewer's session says whether its file is open) |
| Progress and cancel while indexing | `Progress`, `SegCancelledError`, `ProgressStep` | Progress bar with Cancel: the status bar's while a file is indexed or its index cache read, and the Jobs window's | built; not applicable (`SegCancelledError`, `ProgressStep`: a cancelled job ends as cancelled, whatever the library raises) |
| Index cache for instant reopening | `OpenOptions.cache`, `saveIndex`, `f.fromCache` | Instant stepping between files in the file browser: the open job reads and saves caches on the local disk (`<cache>/index`, never beside the file, kept under 4 GiB); the next file of the list is opened through it in the background ("Prepare the next file") | built (Files; File → Prepare the next file) |
| Per-trace geometry keys, all or on demand | `keys = true`, `ensureKeys`, `traceKeys(traces)`, `traceKeysInto`, `hasKeys` | The open file's source and receiver positions in the survey (`traceKeysInto` on a job after each open), drawn on the map as rings; status bar, gathers (keys built when first needed) | built (positions, map); to plan (priority 3: a large file opened without keys, built when first needed with `ensureKeys`) |
| Open options: force the standard, verify every header, two's-complement mantissas (SEG-D 8015, SEG-2 format 3), demux folder | `OpenOptions(kind, verify: vfFull, twosComplement8015, demuxDir)`, `VerifyMode` | "Reopen with options…" (offered on a "not recognised" log entry) | planned |
| Multiplexed SEG-D read transparently | `openSeismic` (demux copy), `f.demuxPath`, `dcMultiplexed` | Opens like any file; a log note says a temporary copy is used | internal (`demuxPath`: a demultiplexed copy's index is not cached); to plan (priority 7: the open path takes such a file, and parseSEG's note goes to Messages, but no multiplexed file has been opened in the viewer yet) |
| File facts in one summary | `summary` (`FileSummary`: standard, revision, byte order (`ByteOrder`), format, counts, interval, record length, `coordinateUnits`, `decodable`), `channelSets` (`ChannelSetSummary`), `crsText`, `recordCount`, `maxSamples`, `index.prefersFloat64` | Headers window, Summary tab: what the file is in plain words, the record shown with its counts and (SEG-D) its channel sets, read on the open job; "Reopen with options…" and About to come | built (Summary); planned (`prefersFloat64`) |
| Coordinate reference text | `crsText`, `summary.crsFormat`, `CrsTextFormat` | File → Import → Survey: the file's CRS as it gives it (read-only); the Headers window's Summary tab; default CRS for the basemap | built (join, Summary); planned (basemap) |
| Coordinate units (metres, feet, degrees, arc seconds) | `summary.coordinateUnits`, `CoordinateUnits` | File → Import → Survey: the units the headers give, in a dropdown the user confirms or corrects; the Headers window's Summary tab; map refuses or converts angular units | built (join, Summary); planned (the rest) |
| Library version | `PackageVersion` | `viewSEG --version` and agent control's server name give parseSEG's version; About box: parseSEG and processSEG versions | built (`viewSEG --version`, agent control); planned (the About box) |
| The trace index | `f.index`, `TraceIndex`, `f.traceEntry(i)`, `TraceEntry`, `TraceCodec`, `NoChannelSet`, `sampleOffset`, `dataBytes`, `known` | internal: the Records window reads the format's own headers from `f.index` (the SEG-Y binary header, the SEG-D records), the plot the values a join gave | internal; not applicable (the entries' byte locations and codecs: the viewer reads samples through the prefetcher) |
| Keys made and derived by hand | `initTraceKeys`, `deriveGeometry`, `hasSourceXY`, `hasReceiverXY`, `Coordinates`, `StationKey`, `stationKey`, `hash`, `segdStatus` | internal: the cursor's pick starts from empty keys (`initTraceKeys`); the survey and the join find stations by `StationKey`, a coordinate pair is `Coordinates` | internal; not applicable (`deriveGeometry`, `hasSourceXY`, `hasReceiverXY`, `segdStatus`: the keys parseSEG gives hold the offset, midpoint and status already) |
| The summary's parts | `ChannelSetSummary`, `StandardRevision`, `$` (a summary in one line) | "File properties" panel, with the summary above: the Headers window's Summary tab, a SEG-D record's channel sets | built (the Summary tab); not applicable (`StandardRevision`: the summary's revision, shown without being named) |

### Reading samples

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Ranges, selections and sample windows into reused buffers | `readTraces`, `readTracesInto` (window forms), `newTraceTensor`, `maxSamples(f, traces)` | Trace panel tiles, deep zoom: read through the prefetcher (below); `maxSamples` gives the tiles' height | internal (`maxSamples`); not applicable (the direct reads: the panels read through the prefetcher) |
| Undecodable traces as zero rows, reported | `PrefetchChunk.failed`, `failedRows`, `log` | Failed traces drawn blank, and a warning in Messages: how many of the traces shown, and the first reason; marked on the trace axis to come | built (drawn blank, Messages); planned (marks on the trace axis) |
| Read-ahead on worker threads | `newPrefetcher`, `tryNext`, `next`, `seek`, `quickFirst`, `workers`, `maxRingBytes`, `atEnd`, `traceAt`, `Prefetcher`, `chunks`, `depth`, `DefaultRingBytes`, `close` | internal: each trace panel's reader thread; on a slow drive (its reads timed) further ahead, in chunks of 256 traces; the next file's first view read in the background | internal; not applicable (`tryNext`, `seek`, `atEnd`, `Prefetcher`, `DefaultRingBytes`: each view gets a prefetcher of its own, read with `nextInto` to its end) |
| Buffer recycling | `nextInto`, `tryNextInto`, `recycle` | internal: scrolling without allocation | internal; not applicable (`tryNextInto`: the reader waits with `nextInto`) |
| Chunks of one channel set and interval | `newPrefetcher(uniform = true)`, `uniformRuns` | internal: one `dt` per processing call: each panel's reader asks for uniform chunks | internal; not applicable (`uniformRuns`: the uniform chunks give the runs) |
| Processing on the decode worker | `ChunkTransform`, `user` | Background QC attribute passes | planned |
| Row views of keys without copies | `rowsOf`, `TraceRows` (`traceOf`, `keysAt`, `numSamples`, `channelSetIndex`, `sub`) | internal: metadata for processing and drawing | internal; not applicable (`numSamples`, `channelSetIndex`: the reader needs each row's trace and keys only) |
| Sample codecs | `decodeTrace`, `encodeTrace`, `decodeSamples`, `encodeSamples` | internal: used by the readers and writers | not applicable (inside the readers and writers; the viewer is given decoded samples) |
| Trace start time and interval per trace | `startTimeMs`, `startTimeMsInto`, `sampleIntervalUs(i)`, `TraceKeys.t0Ms`, `intervalUs` | Time axis honours delay and mixed intervals: the axis starts at the first seismic trace's delay, at its interval; traces at another interval drawn to scale to come (Messages says when they are not); the Headers window's Trace > Data gives each trace's times by `sampleIntervalUs` | built (the first trace's delay and interval); planned (each trace at its own) |

### Sorting

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Sort by header fields (shot, receiver, CMP, offset, any) | `sortTraces(by[, traces])` | Sort by any raw header field, and gather domains | planned |
| Sort by the viewer's own columns | `sortOrder(columns)` | Seismic window: the sort buttons (Line/Station, By Flag, By Component) and Custom… over the trace keys (`TraceKeys`, among them `component`), each ascending or descending, sorted by the panel's reader; later a gather by a QC attribute (RMS, pick time, SNR) | built (keys); planned (QC attributes) |

### Headers

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Any field by name | `traceField`, `recordField`, `fileField`, `findTraceField`, `findRecordField`, `findFileField`, `FieldValue` | Status-bar fields, header table cells | planned |
| One field for many traces | `traceFieldColumn`, `traceFieldColumnInto` | Header table columns | planned |
| A header field plotted against the trace axis | `traceFieldColumn` | Header graph strip above the panel (offset, elevation, static) | planned |
| Field catalogue | `fieldNames`, `blockKind`, `fieldByName`, `HeaderBlock` | Every field of every block described in plain words in the header tables (`fieldNames` checked against the descriptions in a test); column chooser, status-bar field picker to come | built (descriptions); planned (choosers) |
| Every header block with byte offsets | `traceHeaders`, `recordHeaders`, `fileHeaders`, `HeaderRow`, `copyBytes` | Headers window: File headers (a tab per block: SEG-Y Binary, SEG-D General, Channel sets side by side, blocks without named fields as bytes) and Trace > Header (every field of up to 32 traces side by side, the differences marked), each field's description, name, bytes, offset and value, read off the UI thread; the hex pane beside a field list to come | built (tables, raw blocks as bytes); planned (hex pane) |
| SEG-Y textual header | `textHeader`, `extendedTextHeaders`, `TextEncoding` | Headers window, File headers: Text (the 40 lines) and Extended; its encoding (`TextEncoding`) in the Summary | built |
| Samples of chosen traces, whole | `readTraces(traces, samples)`, `maxSamples` | Headers window, Trace > Data: index, time and a sample column per trace, as recorded or as displayed (edits, polarity, the display gain's processing) | built |
| SEG-Y extended text stanzas and user data | `index.segy.extended`, `ExtendedTextHeader`, `Stanza`, `UserDataBlock`, `toDescXml` | Textual header window: stanza list, user data tab | planned |
| SEG-Y Layout stanza (fields moved to other bytes) | `layoutOf`, `entriesFor`, `fieldValue`, `initGeometryReader`, `TraceLayout`, `LayoutEntry`, `LayoutType`, `GeometryReader` (`geometry`, `timeBasis`), `TraceGeometry` | Header table shows layout-named fields (`iline`, `xline`, `sht_line`…) | planned |
| Inline and crossline of post-stack volumes | `TraceKeys.inline`, `crossline` | "Go to inline / crossline", inline or crossline sections | planned |
| Datum, uphole and statics fields, scaled | `traceStatics`, `traceStaticsInto`, `TraceStatics`, `initTraceStatics` | Statics column group in the header table; statics graph strip | planned |
| SEG-D general, channel set and Rev 3 blocks (position, source description, sensor, time drift, orientation) | `index.segdRecords`, `recordHeaders`, `SegdSourceDescription`, `SegdSensorInfo`, `SegdTimeDrift`, `SegdOrientation` | Headers window, File headers of the record shown: General (typed Rev 3 blocks' fields included), Channel sets, Extended, External, skew and trailer as bytes | built; not applicable (`SegdSourceDescription`, `SegdSensorInfo`, `SegdTimeDrift`, `SegdOrientation`: their fields reach the Headers window as `recordHeaders` rows) |
| SEG-2 keyword strings and notes | `seg2Strings`, `seg2Trace`, `noteLines`, typed getters; the strings as `traceHeaders` and `fileHeaders` rows | Headers window: File (the file descriptor block's fields and strings) and Trace > Header (the trace's); notes in File properties to come | built (headers); planned (notes) |
| UTC and GPS time | `TraceKeys.time`, `generalHeaderUtc`, `timestampToUnix`, `gpsMinusUtc` | Status bar: shot time and time within the record | built (the status bar's fields "shot time" and "UTC at the cursor", from `TraceKeys.time`); not applicable (`generalHeaderUtc`, `timestampToUnix`, `gpsMinusUtc`: parseSEG puts the time in the keys) |
| Values joined from survey files, by group | `joinedTraces`, `joinedGroups`, `JoinGroup`, `changedGroups` | Values from the survey (an import) are drawn in the accent colour in the display header, the cursor's header box and the status bar (`Tile.joined`), and in the Headers window's Trace > Header table, a row per key the join gave above the header's own fields, marked per trace; the Summary names the join, its files and the units confirmed | built; not applicable (`changedGroups`: parseSEG's join records what it changed) |
| Keys revision for stale-data checks | `keysRevision`, `markJoined` | internal: overlays, bins and processed tiles rebuilt when keys change | internal; not applicable (`markJoined`: the viewer joins through parseSEG, which marks what it changes) |
| Vendor header blocks decoded by maps | `loadVendorMaps`, `vendorSearchPath`, `decodeVendorAreas`, `VendorRegistry`, `checkVendorMap`, `registerVendorDecoder` | Header inspector shows decoded vendor blocks; Settings → vendor map folders | planned |
| Starting maps for undecoded vendor blocks | `scaffoldVendorMap`, `toNif` | "Create vendor map for this file…" | planned |
| Byte-level codecs (endians, BCD, IBM float, EBCDIC) | `parseSEG/codecs`, `getNum`, `loadNum`, `loadU24`, `beU8`, `beU16`, `beU24`, `beU32`, `beU64`, `beI8`, `beI16`, `beI24`, `beI32`, `beI64`, `beF32`, `beF64`, `hostOrder`, `swapBytes` | Hex pane value inspector (selected bytes as int, IBM, IEEE, BCD) | planned |
| Field values by kind | `FieldValue`, `FieldValueKind`, `HeaderScope`, `BlockRef`, `toFieldValue`, `toFloat`, `$` | The header tables show each value by its kind (integer, real, text, bytes): the Headers window's File headers and Trace > Header | built (the Headers window); not applicable (`HeaderScope`, `BlockRef`, `toFieldValue`, `toFloat`: the header rows give the values) |
| SEG-2 strings by keyword, typed | `Seg2String`, `value`, `contains`, `find`, `number`, `numbers`, `integer`, `sampleInterval`, `delay`, `channelNumber`, `receiverLocation`, `sourceLocation`, `Seg2Location`, `traceType`, `Seg2TraceType`, `traceSort`, `Seg2TraceSort`, `units`, `Seg2Units`, `acquisitionTime` | Header inspector: a SEG-2 file's strings with their typed values (interval, delay, locations, trace type, units, time) | planned |
| A stanza's text and user data | `stanzaText`, `stanzaBytes`, `isBinary`, `isEndText`, `isUserData`, `key`, `userDataBytes`, `isRetained`, `UserDataItem` | Textual header window: stanza list, user data tab (with the stanzas above) | planned |
| A decoded vendor block | `VendorRegistry.addMap`, `loadVendorMap`, `VendorMap`, `decode`, `VendorBlock` (`[]`, `contains`), `VendorField`, `VendorValue`, `VendorValueKind`, `applies`, `vendorContext`, `VendorContext`, `VendorArea`, `VendorDecoder`, `decodeTarget` | Header inspector: a decoded vendor block's fields and values (with `decodeVendorAreas`, above) | planned |
| Extended textual header, parsed record by record | `initExtendedTextHeader`, `add`, `finish`, `isComplete`, `needsMore`, `hasEndText`, `inBinaryStanza`, `continuesUserData`, `ExtTextIssue`, `streamLimit=`, `startsStanza`, `startsStanzaRecord`, `normalizeStanzaName`; writing: `addText`, `addStanza`, `addUserData`, `addEndText` | The readers parse a file's stanzas into `index.segy.extended`; the writers copy them | not applicable (the readers' and writers' work; the viewer reads the parsed stanzas) |
| Layouts made by hand | `standardLayout`, `parseLayout`, `merge`, `normalizeEntryName`, `size` | The file's own layout (`layoutOf`, above) | not applicable (the viewer shows a file's layout; it makes none) |
| A compiled vendor map's parts | `VendorMatch`, `VendorRevision`, `VendorRevisionRange`, `VendorTarget`, `VendorTargetKind`, `VendorFieldPlan`, `VendorRepeatPlan`, `VendorEncoding`, `VendorTrim`, `VendorEnumLabel`, `VendorBitFlag`, `VendorScaffold` | Maps are text files; `checkVendorMap` says what is wrong with one | not applicable (a map's inner structure, built and used by its decoder) |
| Writing bytes | `putNum`, `putBeU8`, `putBeU16`, `putBeU24`, `putBeU32`, `putBeU64`, `putBeI8`, `putBeI16`, `putBeI24`, `putBeI32`, `putBeI64`, `putBeF32`, `putBeF64`, `ByteBuf`, `byteBuf`, `copyHostOrder` | None | not applicable (the viewer changes a file only through the header editor, which encodes its values itself) |

### Gathers and channels

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Gathers derived from geometry | `gathers`, `classify`, `Gather`, `GatherKind` | Record list, next / previous gather: the Records window, a row per gather with its kind; a click, the arrow keys or Page Up / Page Down show one | built (the Records window); not applicable (`classify`: `gathers` classifies each gather) |
| SEG-D channel sets | `channelSets`, `traceEntry(i).channelSetIndex`, `channelType` | Channel chooser; the Records window counts a record's seismic and auxiliary traces by `channelType` | internal (the Records window's counts); planned (the channel chooser) |
| Seismic and auxiliary traces | `isSeismic`, `TraceStatus` (`tsAuxiliary`, `tsDead`) | Seismic window: the Seismic and Aux toggles (auxiliary traces in the same plot); dead traces never drawn, "dead" in the status bar; Records window: traces, aux and dead per record; the Aux window of its own | built (toggles, dead, counts); planned (the Aux window) |
| Multi-component stations | `componentGroups`, `componentGroupIds`, `isMultiComponent`, `TraceKeys.component`, `ComponentGroup` | Components in colour, side-by-side layout | planned |

### Survey files and geometry

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Read SPS 1.0 / 2.1 (S, R, X, O) | `parseSps` (a file a 4 MiB chunk at a time, the revision and layout of the first kept: `SpsOptions`), `detectLayout`, `addSps` (the relations), `relationDomainOf`; `readSps`, `looksLikeSps` not used (the file list tells SPS also from a head of header records only) | File → Open, drag and drop, a click in Files: survey files are loaded into the survey on a job, with progress, and listed as SPS S / R / X; drawn on the map, a layer per file's sources or receivers; File → Import → Survey… reads them again with `addSps` a chunk at a time, with the join's options | built; planned (`readSps` and `looksLikeSps` when parseSEG's next release reads with progress and cancel, below) |
| Read SEG P1 | `parseP1` (whole, up to 64 MiB), `addP1`, `P1Options` (`angleUnit`) | Loaded into the survey as SPS files are (sources; a reshoot is a station of its own); File → Import → Survey joins P1 files (`addP1`, no implied decimals); the implied decimals as an option, to come | built (loading, join); to plan (priority 2: the implied decimals as an option) |
| Survey-file problems | `SurveyGeometry.log`, `SpsFile.log`, `P1File.log` | Messages: each file's first 20 problems by line, then a count; what was left off the map (no coordinates, at (0, 0)) and stations given twice | built; not applicable (`P1File`: the type `parseP1` gives, never named) |
| Station tables | `table`, `sourceCount`, `receiverCount`, `relationCount`, `records` | The survey's own layers (stations found by key as `lookup` finds them); `relationCount` and `records` give a relation file's counts; the map's layers, a point's station in what the map says of it | built; not applicable (`sourceCount`, `receiverCount`: the survey counts its own layers) |
| Join by station, with statistics | `applySurvey(f, g, stats, overwrite)`, `joinStations`, `JoinStats`, `JoinMatch`, `stationKey` | File → Import → Survey: worked out on copies of the keys first (`joinStations` and `applySurvey` per trace), then joined with the readers stopped; matched and unmatched traces, how they matched, why none did, the headers' coordinates kept or replaced, in plain words and in Messages; linked highlighting fills the stations a hovered trace's headers lack from the loaded relation file | built |
| Traces by join outcome (conflict, ambiguous, unmatched) | `joinStations` per trace | Import survey: "Select unmatched traces" (the survey lacks the source or receiver); conflicting and ambiguous traces counted in the words; a selection per outcome, to come | built (unmatched); to plan (priority 1: a selection per outcome) |
| Join options: line names, trailing digits, multi-component, one tape | `mapLine`, `trailingDigits`, `multiComponent`, `tape` | Import survey window, Options (remembered): line names as numbers, trailing digits, several channels per station; one tape, to come | built (but `tape`); to plan (priority 2: one tape as an option) |
| Relation lookups (the spread of a shot, the shots of a receiver) | `relation`, `relations`, `records`, `expectedChannels`, `recordsAt`, `channelOf`, `relationRuns`, `relationsDisjoint` | Map: the point under the pointer names a source's field records (`recordsAt`); the record on show is marked by the stations its relation runs plan (`relationRuns`) when its headers name none; the template box round the spread planned for the record on show and the shot under the pointer (X), or a receiver's planned shots (O); a hovered survey receiver's traces through `channelOf` (headers without stations), to come | built (a source's records, the record on show's planned spread, the template box, a receiver's planned shots); planned (a receiver's traces before the join) |
| Grid unit from the SPS header | `gridUnit`, `GridUnit`, `measurementSystem` | The map's units: the status bar's coordinates, the scale bar, the ruler, a point's coordinates (`m`, `ft`, `ftUS`, named exactly; "units" when nothing says; lengths in another of them on request, converted exactly); Import survey: the units the SPS headers give, confirmed or corrected (and then the map's); File properties | built (map, join); planned (File properties) |
| Coordinates from the user's own table | `GeometryTable`, `addSource`, `addReceiver`, `applyGeometry` | Import survey from a CSV table of stations (`core/join.addCsv`: a header row naming the columns, or line, point, x, y, z; S / R per row or one role for the table), joined with `applyGeometry` | built; not applicable (`GeometryTable`: the survey's `table`, never named) |
| Write SPS and P1 (1.0 ↔ 2.1, byte-exact) | `writeSps`, `spsText`, `encodeSps`, `writeP1`, `p1Text`, `encodeP1`, `SurveyText`, `SpsWriteOptions`, `P1WriteOptions` | Export survey files (corrected, or in another SPS revision) | planned |
| Receiver-domain relations | `receiverRelations` | The map's template box for a file of receiver gathers when only X records are loaded (made on a job); export .ops (receiver gathers) | built (the map); planned (the export) |
| Preview what a geometry write would change | `geometryChanges`, `GeometryChanges`, `$` | "Write geometry…" preview step | planned |
| Write joined geometry in place, journaled | `writeGeometry`, `GeometryFields` | Write geometry into the file (undoable) | planned |
| Copy or convert with geometry | `copyWithGeometry`, `convertWithGeometry`, `GeometryCopy` | Save a copy with geometry; export SEG-Y with geometry | planned |
| SPS and P1 records as data | `SpsFile`, `SpsHeader`, `SpsPoint`, `initSpsPoint`, `SpsPointKind`, `SpsRelation`, `initSpsRelation`, `SpsEntry`, `SpsEntryKind`, `SpsRevision`, `readP1`, `P1Record`, `initP1Record`, `PLogicalFile`, `PFormat`, `AngleUnit` | internal: the survey reads its points and relations from them (`SpsPointKind`, `PFormat`); editing records, to come with the export above | internal; planned (editing and writing survey files) |
| Survey text, line by line | `TextRecord`, `TextLayout`, `textRecords`, `openLayout`, `CardWidth`, `MaxLineBytes`, `MissingInt` | internal: the 4 MiB chunks of a survey file keep the first chunk's layout (`TextLayout`) | internal; not applicable (`textRecords`, `openLayout`, `TextRecord`, `CardWidth`, `MaxLineBytes`, `MissingInt`: the parsers read the lines) |
| A survey built by hand | `initSurveyGeometry`, `RelationDomain`, `RelationRun`, `station`, `StationRelation`, `resolveLine`, `sameStation`, `$` | internal: the survey of the loaded files and the join's own (`core/survey`, `core/join`) | internal; not applicable (`RelationRun`, `StationRelation`, `sameStation`: reached through `relationRuns` and `relation`; stations compared by `stationKey`) |

### Writing

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Write traces like the input, any subset and order | `openSeismicWriter(path, like)`, `writeTrace(src, trace, samples)`, `headerOverride`, `SeismicWriter`, `HeaderOverride`, `close` | Export processed traces; export the file without killed traces | planned |
| Write with in-memory geometry | `writeTrace(..., keys, fields)` | Export with joined geometry and edits | planned |
| New SEG-Y from keys | `openSeismicWriter(path, SegyOutputOptions)`, `writeTrace(keys, samples)` | Export a selection, a generated pilot or a stack as SEG-Y | planned |
| Per-standard streaming writers | `openSegyWriter`, `openSegdWriter`, `writeSegd`, `openSeg2Writer`, `SegyWriter`, `SegyWriteOptions`, `initSegyWriteOptions`, `tracesWritten`, `SegdWriter`, `SegdWriteOptions`, `writeRecordHeaders`, `endRecord`, `setRev3Trailer`, `computeRev3Sizes`, `MaxFixedBlock`, `Seg2Writer`, `Seg2WriteOptions`, `initSeg2File`, `abandon` | Conversion and the test suite's fixtures | not applicable (the viewer writes through `openSeismicWriter` and `convertFile`; its tests build their fixtures with these) |

### Header edits

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Pending edits saved as a patch | `writeHeaderPatch`, `initHeaderChange`, `HeaderChange` | Inline edits in the header table, saved as a patch | planned |
| Apply a patch or header document (dry run, into a copy) | `importHeaders`, `ImportOptions` (`dryRun`, `outPath`, `force`, `onChange`), `ImportResult` | "Apply patch…": preview, then into the file or a copy | planned |
| Export every header as a document | `exportHeaders` | Export headers (NIF) for editing elsewhere | planned |
| In-place editor on the open file | `openEditor(f)`, `setTraceField`, `setRecordField`, `setFileField`, `beginBatch`, `endBatch`, `currentTraceField`, `release`, `HeaderEditor`, `currentRecordField`, `currentFileField`, `edits`, `journalPath`, `file`, `close` | Edit headers in place (explicit, confirmed) | planned |
| Journal: undo and redo | `rollbackJournal`, `applyJournal`, `readJournal`, `JournalEdit` | Edit history window: list, undo all, redo | planned |

### Streams, tape and multiplexed data

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Tape images (.tap) | `openTapeImageSource`, `buildIndex`, `openSegy`, `openSegd`, `TapeImageSource`, `TapeImageSink`, `openTapeImageSink` | Import from tape image to a disk file, then open | planned |
| Tape drives | `newDeviceSource`, `openLinuxTape`, `TapeDevice`, `LinuxTape`, `openWindowsTape`, `WindowsTape`, `DeviceSource`, `DeviceSink`, `newDeviceSink`, `device`, `TapeStatus`, `status`, `readBlock`, `writeBlock`, `writeTapeMarks`, `rewind`, `spaceFiles`, `DefaultMaxBlockSize` | Import from tape drive (Linux `st`, Windows tape) | planned |
| Streaming readers, headers only | `readSegyHeaders`, `readSegdHeaders`, `openSegy`, `openSegd(headersOnly)`, `readSeg2`, `SegyReader`, `SegyFile`, `SegyTrace`, `SegyData`, `readSegy`, `readTrace`, `decodeInto`, `isDone`, `tracesRead`, `extractUserData`, `binaryAsRead`, `isBinaryAsRead`, `isExtendedAsRead`, `isTrailerAsRead`, `TapeLabelSize`, `DefaultMaxRetained`, `MaxLayoutBytes`, `SegdReader`, `SegdData`, `SegdRecordData`, `readSegd`, `nextRecord`, `record`, `label`, `toc`, `announcedTraces`, `channelSetCount`, `DefaultMaxHeaderBytes`, `DefaultMaxTraceBytes`, `UnknownTrailerBlocks`, `readSeg2Trace`, `readSamples`, `Seg2File`, `Seg2Trace` | Import from tape, a record at a time; layout-named fields | planned |
| Demultiplexed copy | `demultiplexSegd` | Save demultiplexed copy | planned |
| Records, sinks, memory tape | `RecordCursor`, `DiskSink`, `newMemoryTape`, `MemoryTape`, `TapeItem`, `TapeItemKind`, `dataBlock`, `tapeMark`, `items`, `[]` | Tests of tape reading; the tape import's plumbing | not applicable (a tape in memory, for tests; the records under the tape import, which gives `buildIndex` a source) |
| SEG-D tables of contents | `decodeToc`, `isTocFile`, `SegdToc`, `SegdTocEntry`, `tocEntryCount`, `TocIdentifier`, `TocHeaderSize`, `TocEntrySize` | Detection | not applicable (`detectKind` and `openSeismic` read a table of contents themselves) |
| A SEG-D record's headers and channel sets | `SegdRecord`, `SegdLayout` (`slRev2`, `slRev3`), `isRev3`, `SegdRevision`, `SegdScanType`, `SegdTrace`, `findChannelSet`, `SegdChannelSetRef`, `fileNumber`, `baseScanIntervalUs`, `channelSetsPerScanType`, `generalHeaderCount`, `extendedHeaderBlocks`, `externalHeaderBlocks`, `skewBlocks`, `headerBytes`, `<`, `<=`, `$` | Records window: a SEG-D record's declared seismic and auxiliary traces, from its channel sets in `f.index.segdRecords`; the header inspector's record tab | built (the Records window); planned (the header inspector) |
| A SEG-Y file's binary header, as the rules read it | `SegyBinaryHeader`, `effectiveDataTracesPerEnsemble`, `effectiveAuxTracesPerEnsemble`, `effectiveEnsembleFold`, `effectiveSampleInterval`, `effectiveSampleIntervalOrig`, `effectiveSamplesPerTrace`, `effectiveSamplesPerTraceOrig`, `usableExtInterval`, `SegyRevision`, `rulesRevision`, `bytesPerSample`, `revision=` | Records window: a SEG-Y file's declared traces per record; the header inspector's binary header | built (the Records window); planned (the header inspector) |
| Sources and sinks of records | `RecordSource`, `RecordSink`, `RecordKind`, `initRecordCursor`, `readExactly`, `skip`, `skipTapeMark`, `stoppedAt`, `remainingInRecord`, `atRecordStart`, `readRecordRest`, `preferSmallReads`, `readRecord`, `writeRecord`, `writeTapeMark`, `DefaultChunkSize`, `readRecordImpl`, `seekForward`, `hasRecordBoundaries`, `writeRecordImpl`, `writeTapeMarkImpl`, `read`, `source`, `fileIndex`, `recordIndex`, `DiskSource`, `openDiskSource`, `openDiskSink`, `SinkBufferSize`, `MemFileSource`, `openMemFileSource`, `memory`, `flush`, `DefaultMapChunk` | The plumbing under `openSeismic`, `buildIndex` and the writers | not applicable (a viewer gives `openSeismic` a path and `buildIndex` a source; it reads no records itself) |
| Multiplexed scans decoded by hand | `muxLayout`, `MuxScanLayout`, `MuxChannelSet`, `isStartOfScan`, `scanHeader`, `ScanHeader`, `ScanHeaderSize`, `demuxChannel`, `decodeMux0015`, `timingMs`, `isMultiplexedCode`, `demuxFormat`, `muxBytes`, `muxTraceHeader`, `demultiplexedRecord` | The SEG-D reader demultiplexes with them | not applicable (`openSeismic` and `demultiplexSegd` demultiplex; these are their parts) |

### Conversion

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Any standard to SEG-Y, with a loss report | `convertFile`, `ConvertOptions`, `convertSegdToSegy`, `convertSeg2ToSegy` | Convert… (file or folder, progress, cancel, losses listed) | planned |
| SEG-Y revision, byte order, sample format | `convertSegy`, `ConvertOptions(revision, byteOrder, format)`, `targetFormat`, `SegyTargetFormat` | Convert… | planned |
| SEG-D between revisions | `convertSegdRevision`, `SegdConvertOptions`, `SegdTargetFormat`, `scanSegdRecords`, `SegdRecordScan` | Convert… | planned |
| To SEG-2, SEG-2 to SEG-D | `convertToSeg2`, `convertSeg2ToSegd`, `Seg2ConvertOptions`, `Seg2TargetFormat` | Convert… | planned |
| Descaled amplitudes (millivolts) | `applyDescale`, `descaleFactor(rec, trace)` | Convert option; readout in counts or mV | planned |

### Diagnostics

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Problems as data with severity, code and location | `DiagLog`, `Diagnostic`, `Severity`, `DiagCode`, `Location`, `f.log` | Log window, filtered by severity: Messages shows each file's diagnostics with their severity, and filters them by severity | built (Messages); not applicable (`Diagnostic`: an entry of a `DiagLog`, never named) |
| Location of each problem | `Diagnostic.loc` (record, trace, field), `offset` | Click a log entry to go to its trace or header field: a click on a line of Messages that names a trace shows it | built (a trace); to plan (priority 9: a header field) |
| Logs as files | `toNif`, `writeNif`, `readDiagnostics`, `parseDiagnostics` | Log window: save and open; attached to the QC report (Messages exports its own text, File → Export messages...) | to plan (priority 8: a file's problems saved as NIF and opened again, attached to the QC report) |
| Exceptions turned into entries | `recordException`, `tryRecord`, `tryRecordFatal` | internal: jobs report failures to the log | not applicable (a job's failure goes to Messages in the viewer's own words) |
| The log, read and counted | `add`, `report`, `count`, `hasErrors`, `isFatal`, `items`, `pairs`, `[]`, `$`, `len` | internal: Messages takes each file's entries; the Headers window's Trace > Data tells a trace that could not be decoded (`hasErrors`) | internal; not applicable (`isFatal`: Messages counts its entries by severity itself) |
| Exceptions for custom decoders | `SegError`, `SegFormatError`, `SegTruncatedError`, `SegUnlocatableError`, `raiseFormat`, `raiseTruncated`, `raiseUnlocatable`, `raiseCancelled` | Every failure of a read is reported in Messages as it is | not applicable (the viewer reports a read that fails, whatever it raises; raising them is for code that decodes) |

### Header objects and codecs

The objects behind `traceHeaders`, `traceField` and the readers. The viewer reads headers by
name, so these are building blocks for code that works on raw headers.

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| SEG-Y binary and trace headers from bytes | `BinaryHeaderSize`, `binaryHeaderFields`, `decodeBinaryHeader`, `encode`, `validate`, `detectByteOrder`, `ByteOrderDetection`, `looksLikeBinaryHeader`, `ByteOrderMarker`, `SegyTraceHeader`, `SegyTraceHeaderExt1`, `TraceHeaderSize`, `traceHeaderFields`, `traceHeaderExt1Fields`, `decodeTraceHeader`, `decodeTraceHeaderExt1`, `initTraceHeaderExt1`, `applyScalar`, `scaleCoordinate`, `scaleElevation`, `scaleTime`, `shotpoint`, `headerBlockName`, `headerNameText`, `LastInEnsemble`, `LastInLine`, `LastInFile`, `LastInSurvey` | The same fields by name in the header tables | not applicable (the viewer reads fields by name) |
| SEG-Y textual header from bytes | `SegyTextHeader`, `TextHeaderSize`, `CardCount`, `CardWidth`, `CardNumber`, `initTextHeader`, `card`, `setCard`, `cardPrefix`, `decodeTextHeader`, `detectTextEncoding`, `decodeText`, `encodeText`, `looksLikeText`, `text`, `text=` | The textual header as text (`textHeader`, above) | not applicable (`textHeader` gives the cards; a written file's text is `SegyOutputOptions.text`) |
| SEG-D headers from bytes | `SegdStorageUnitLabel`, `decodeLabel`, `isStorageUnitLabel`, `SegdGeneralHeader1`, `SegdGeneralHeader2`, `SegdGeneralHeaderN`, `SegdChannelSetDescriptor`, `SegdTraceHeader`, `SegdTraceHeaderExt1`, `SegdTrailerBlock`, `SegdHeaderBlock`, `SegdBlock`, `segdGeneralHeader1Fields`, `segdGeneralHeader2Fields`, `segdGeneralHeaderNFields`, `segdChannelSetDescriptorFields`, `segdTraceHeaderFields`, `segdTraceHeaderExt1Fields`, `segdTrailerBlockFields`, `SegdBlockSize`, `SegdTraceHeaderSize`, `decodeBlock`, `encoded`, `invalidBcdFields`, `asciiText`, `baseScanIntervalMs`, `recordLengthMs`, `sampleIntervalMs`, `channelSetNumber`, `endTimeMs`, `mpFactor`, `receiverLine`, `receiverPoint`, `isFixedRecord`, `bytesPerScan`, `scansPerBlock` | The same fields by name in the header tables | not applicable (the viewer reads fields by name) |
| SEG-D Rev 3 blocks from bytes | `SegdGeneralHeader2Rev3`, `SegdGeneralHeader3`, `SegdChannelSetDescriptorRev3`, `SegdTraceHeaderExt1Rev3`, `SegdPositionBlock`, `SegdAdditionalSourceInfo`, `SegdSensorCalibration`, `SegdTimestampHeader`, `SegdTrailerDescription`, `SegdRev3Block`, `segdGeneralHeader2Rev3Fields`, `segdGeneralHeader3Fields`, `segdChannelSetDescriptorRev3Fields`, `segdTraceHeaderExt1Rev3Fields`, `segdPositionBlockFields`, `BlockTypeGeneralHeader2`, `BlockTypeGeneralHeader3`, `BlockTypeChannelSet1`, `BlockTypeChannelSet2`, `BlockTypeChannelSet3`, `BlockTypeTraceHeaderExt1`, `BlockTypePosition1`, `BlockTypePosition2`, `BlockTypePosition3`, `BlockTypeCrs`, `BlockTypeTrailerDescription`, `blockTypeName`, `isDefinedBlock`, `isUserBlock`, `findBlock`, `blocks`, `blockText`, `descriptionText`, `traceNumber`, `traceBytes`, `recordLengthUs`, `crsFormat`, `depth`, `unixToTimestamp`, `GpsEpochUnix` | The same fields by name in the header tables | not applicable (the viewer reads fields by name) |
| A vibrator's source description in a SEG-D Rev 3 record | `SegdSourceDescription` (`vibratorType`, `phaseControl`, `phaseAngle`) | Vibroseis QC: each record's vibrator type, phase control and phase angle beside the vibrator plots | to plan (priority 4) |
| SEG-2 blocks from bytes | `Seg2Header`, `Seg2FileFixed`, `Seg2TraceFixed`, `Seg2FixedSize`, `Seg2FileBlockId`, `Seg2TraceBlockId`, `Seg2MaxTraces`, `isSeg2`, `seg2Order`, `toSeg2String`, `[]=`, `sortStrings`, `formatNumber`, `blockStrings`, `fileBlockSize`, `dataOffset`, `stringListEnd`, `sampleCount` | The same fields and strings by name in the header tables | not applicable (the viewer reads fields and strings by name) |
| Sample formats | `SampleFormat`, `SampleType`, `sampleSize`, `toSampleFormat`, `isRev2Format`, `definedSampleFormats`, `SegdSampleFormat`, `SegdSampleType`, `segdSampleFormats`, `toSegdFormat`, `isLittleEndian`, `bigEndianOf`, `Seg2SampleFormat`, `Seg2SampleType`, `toSeg2Format`, `samplesIn`, `prefersFloat64` | The file's format, by its code, in File properties (`summary`) | not applicable (the readers decode every format; `summary` says which a file has) |
| Field layouts | `FieldSpec`, `FieldKind`, `fieldTable`, `BcdInvalid`, `BcdAllF` | Fields by name (`fieldNames`) | not applicable (the layouts under the header objects) |

## processSEG

### Core

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Chunk metadata from parseSEG reads | `initChunkMeta`, `chunkMeta`, `intervalMs`, `ChunkMeta` (`isLive`, `sampleTimeMs`, `isFailed`, `liveSamples`, `len`, `rows`, `dtMs`, `firstSample`, `failedCount`, `failedRow`, `keys`, `t0Ms`, `sub`), `sameInterval`, `checkShape` | internal: every processing call; killed traces are passed as failed rows, so the processing and the levels pass them by | internal; not applicable (`chunkMeta`, `intervalMs`, `ChunkMeta`, `isLive`, `sampleTimeMs`, `failedCount`, `failedRow`, `sameInterval`, `checkShape`: the reader makes each meta with `initChunkMeta` from its chunk's rows, interval, failed and killed rows) |
| Row views and scratch | `rowBlock`, `RowBlock` (`len`, `cols`, `row`, `rowPtr`, `sub`), `Workspace`, `initWorkspace`, `reserve`, `capacity`, `fits`, `scratch`, `WorkspaceSize` (`+`, `max`), `SampleType` | internal: allocation-free processing | internal; not applicable (`WorkspaceSize`, `fits`, `SampleType`: the reader reserves what its plan needs) |
| Remove mean or trend | `demean`, `detrend`, `demeanOp`, `detrendOp` | Processing window: remove DC / trend | planned |
| Scale, clip, polarity | `scale`, `clip`, `reversePolarity`, `scaleOp`, `clipOp`, `polarityOp` | Seismic window: "Reverse polarity" of a trace or the selection (`R`, the plot's menu: `reversePolarity` on its live samples where the reader prepares them, before the pipeline, as `polarityOp` would) and "Reverse polarity of all traces" (`polarityOp` first in the window's display pipeline); processing window: scale and clip; the wiggles' clip at the trace overlap is the shader's own | built (polarity of a trace, of the selection, of all traces); planned (the rest) |
| Top and bottom mutes (time, table, LMO) | `timeMute`, `tableMute`, `lmoMute`, `muteTop`, `muteBottom`, `muteTopOp`, `muteBottomOp`, `muteTimeMs`, `MuteKind`, `MuteCurve`, `kind` | Processing window: mutes, drawn as a line on the panel, table picked by clicking | planned |
| Pad tapers | `cosTaperInto`, `taperPads` | processSEG's filters pad and taper with them | not applicable (inside processSEG's filters; for a caller's own padded kernels) |
| Fractional shifts | `shiftSamples`, `ShiftInterp` | processSEG's statics, LMO and NMO shift with them | not applicable (inside processSEG's statics, LMO and NMO) |

### Spectra

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Real FFT, batched | `initFftPlan`, `forward`, `inverse`, `forwardLanes`, `inverseLanes`, `nextFastLen`, `gatherLanes`, `scatterLanes`, `FftPlan` (`len`, `bins`, `workspaceSize`), `isFastLen`, `fftLanes` | Inside the spectra and filters; the f-k window takes an f-k transform of processSEG's own | not applicable (the spectrum, filter and f-k plans run them) |
| Averaged amplitude spectrum of a selection | `initSpectrumPlan`, `averageAmplitudeInto`, `toDbInto`, `binHz`, `SpectrumPlan` (`bins`, `windowLen`, `nfft`, `dtMs`, `workspaceSize`), `DbReference` | Spectrum panel, raw and processed | planned |
| Amplitude and phase of one trace | `amplitudeInto`, `amplitudePhaseInto` | Compare pilots: phase difference; phase tab of the spectrum panel | planned |

### Filters

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Trapezoid band-pass, low-cut, high-cut (zero phase) | `bandPass`, `lowCut`, `highCut`, `Corners`, `bandPassOp`, `filterOp`, `initFilterPlan`, `FilterPlan` (`samples`, `nfft`, `spec`, `dtMs`, `workspaceSize`), `applyFilter`, `FilterSpec`, `ResponseKind` | Processing window: band-pass | planned |
| Butterworth magnitudes | `butterBandPass`, `butterLowCut`, `butterHighCut` | Processing window: Butterworth | planned |
| Notches and zero DC | `withNotch`, `withZeroDc`, `Notch` | Processing window: notch (mains 50 / 60 Hz) | planned |
| IIR, zero or minimum phase | `initIirPlan`, `iirOp`, `IirPhase`, `IirPlan` (`order`, `phase`), `iirLanes`, `causalEnergyFraction` | Processing window: IIR, phase choice | planned |
| Trend handling at the edges | `TrendRemoval` | Processing window, advanced | planned |
| Filter response | `response`, `responseInto`, `gainAt`, `magnitudeAt`, `narrowestRampHz` | Response curve in the processing window, over the spectrum | planned |
| Zoom margins | `requiredMargin`, `impulseLength`, `decodeWindow`, `energyFraction` | internal: zoomed tiles decode enough samples | internal; not applicable (`impulseLength`, `energyFraction`: a plan's `requiredMargin` gives the margin) |
| Parameter checks against Nyquist | `validate`, `nyquistHz` | The processing window's parameter ranges | planned |

### Gain

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Fixed gain in dB | `scaleDb`, `gainDbOp`, `dbToFactor` | Seismic window: the gain amount in dB and the Fixed gain, both as the shader's scale (the viewer's own conversion); `gainDbOp` in the processing window | planned (the processing window's gain) |
| Normalisation per trace or panel (max, RMS, percentile) | `initNormalizePlan`, `normalize`, `normalizeOp`, `panelFactor`, `NormalizePlan`, `NormStat`, `NormScope` | Seismic window: gain "Normalized" (`normalizeOp(stat, perTrace)` per trace; per panel the scale alone, from `panelStats`) | built (Seismic window: gain Normalized); not applicable (`initNormalizePlan`, `normalize`, `panelFactor`, `NormalizePlan`: the display pipeline runs `normalizeOp`) |
| AGC (RMS, mean absolute) | `initAgcPlan`, `agc`, `agcOp`, `AgcMode`, `AgcPlan` (`windowMs`, `windowSamples`, `epsilon`, `target`, `percentile`, `stat`, `scope`) | Seismic window: gain "AGC" (the default on pre-stack gathers); processing window: AGC | built (Seismic window: gain AGC); not applicable (`initAgcPlan`, `agc`, `AgcMode`, `AgcPlan`: the display pipeline runs `agcOp`) |
| AGC gain kept and removed | `agc(..., gains)`, `removeGain` | Show the AGC gain function; undo AGC on export | planned |
| Time-variant gain (knots, tᵖ, exponential) | `knotGain`, `powerGain`, `exponentialGain`, `gainCurveOp`, `initGainCurvePlan`, `applyGainCurve`, `GainKnot`, `GainCurve`, `GainCurveKind`, `gainDbAt`, `factorAt`, `GainCurvePlan` (`curve`, `tableLen`, `tableMs`) | Seismic window: gain "Exponential" (`exponentialGain`, `powerGain`, held after its cutoff time as a `knotGain`); processing window: gain curve editor (knots) | built (display); planned (the editor) |
| Statistics for display gain and clip | `traceStatsInto`, `panelStats`, `percentileAbs`, `traceStats`, `TraceStats`, `PanelStats`, `panelStatsWorkspace`, `percentileWorkspace` | Seismic window: clip at a percentile and the Normalized levels (`panelStats`, a shader uniform), Float's level of the data in view (`percentileAbs`); the same reference is full black in density and the full swing (the trace overlap) of a wiggle; killed traces left out of each; per-trace statistics later | built (Seismic window: the levels of Normalized and Float, the clip); planned (per-trace statistics) |

### Pipelines and threads

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Editable processing flow | `initPipeline`, `Op`, `add`, `insert`, `delete`, `compile`, `plan.apply(b, meta, ws)`, `PipelinePlan`, `generation`, `Pipeline` (`len`, `[]`, `[]=`, `items`, `pairs`, `clear`), `OpKind`, `recordSamples`, `workspaceSize` | Processing window: the flow list, live update; meanwhile each Seismic window's display pipeline (polarity, then its gain type's op), compiled and applied by its reader | internal (the display pipeline); planned (the processing window) |
| Raw kept, processed into a second buffer | `plan.apply(src, dst, meta, ws)` | Raw / processed toggle key | planned |
| Plan parts for own threads | `checkApply`, `partCount`, `partNeedsPanel`, `panelFactorOf`, `runPart` | internal: not needed while the pool is used | not applicable (each panel's reader applies its plan whole; a per-panel level is the shader's) |
| Worker pool | `newProcessPool`, `pool.apply`, `ping`, `ProcessPool`, `workers` | Live processing on all cores (the processing window); each panel's reader applies its plan on its own thread meanwhile | planned |
| The ops' parameters, edited in place | `factor`, `dB`, `clip`, `mute`, `filter`, `iir`, `agc`, `norm`, `gainCurve`, `ClipParams`, `MuteParams`, `FilterParams`, `IirParams`, `AgcParams`, `NormalizeParams`, `GainCurveParams` | Processing window: each op's settings (windows, corners, levels) changed in place, the panel following | planned |

### Velocity and moveout

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Linear and hyperbolic moveout ticks | `linearMoveout`, `hyperbolicMoveout`, `moveoutTimesInto`, `moveoutColumnsInto`, `Moveout` (`kind`, `velocity`, `t0Ms`, `timeMs`), `MoveoutKind` | Moveout overlay over the gather | planned |
| Moveout from a velocity model or binning | `moveoutTimesInto(field[, binning])`, `moveoutColumnsInto(field, binning)`, `checkSuits` | Moveout overlay from loaded velocities | planned |
| Apparent velocity at a dragged line | `lmoTime`, `nmoTime`, `nmoStretch` | Velocity ruler on the panel and the f-k window | planned |
| Flatten first breaks for display | `applyLmo`, `removeLmo` | "Flatten (LMO)" display toggle | planned |
| Velocity functions and Dix conversion | `constantVelocity`, `gradientVelocity`, `rmsVelocity`, `intervalVelocity`, `vrmsAt`, `vintAt`, `dixIntervalInto`, `rmsFromIntervalInto`, `VelocityFunction`, `VelocityKind`, `VelocityKnot`, `knots` | Velocity editor: Vrms knots, Vint shown | planned |
| Velocity fields (2D, 3D) | `initVelocityField`, `vrmsAt(location)`, `vrmsInto`, `VelocityField` (`len`, `samples`, `tMaxMs`, `locations`, `crosslines`), `FieldKind`, `VelocityPick` | Velocity quick-look; field section in colour | planned |
| Velocity files (VELF, HANDVEL, CSV) | `readVelocities`, `parseVelocities`, `parseVelf`, `parseHandvel`, `parseVelocityCsv`, `MinPickVelocity` | File → Load velocities… | planned |

### Statics, NMO and stacking

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Datum statics from elevations | `datumStatics`, `staticMs`, `staticsInto`, `applyStatics`, `DatumStatics` (`datumZ`, `vReplacement`) | Processing window: elevation statics (datum, replacement velocity) | planned |
| Statics recorded in the headers | `headerStaticMs`, `headerStaticsInto`, `applyStatics(staticsMs)` | Processing window: apply header statics | planned |
| NMO with stretch mute | `initNmoParams`, `applyNmo`, `nmoInto`, `nmoSlothInto`, `NmoParams` (`interp`, `maxStretch`, `taperMs`), `nmoWorkspace`, `vrmsToSloth` | NMO preview on CMP gathers with a velocity slider | planned |
| CMP bins (header CDP, line, 3D grid, inline/crossline) | `cdpBinning`, `lineBinning`, `gridBinning`, `inlineCrosslineBinning`, `binOf`, `binAt`, `location`, `Binning` (`inlines`, `is3D`), `BinningKind`, `BinLocation`, `binsInto`, `locationOf` | Bin grid setup for fold maps and stacks; bin grid layer on the map | planned |
| Stack accumulation | `initStackAccumulator`, `add`, `addLive`, `merge`, `stackInto`, `foldInto`, `finishInto`, `StackAccumulator` (`bins`, `startMs`, `foldAt`, `sumAt`, `tracesAt`, `cmpXAt`, `cmpYAt`, `addMidpoint`), `stackMemory`, `FoldNorm`, `liveSpan` | The brute stack window (`bruteStack` accumulates) | not applicable (`bruteStack` stacks a file, a range or a selection itself) |
| Brute stack of a file, with progress and cancel | `bruteStack`, `BruteStackOptions`, `bruteStackMemory`, `StackResult`, `initBruteStackOptions` | Brute stack window; memory estimate before it starts | planned |
| Stack written as SEG-Y | `writeStack`, `stackKeys`, `stackOverrides`, `maxFold` | Save stack as SEG-Y | planned |

### QC

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Geometry flags from the keys | `checkGeometry`, `checkGeometryInto`, `flaggedRows`, `GeometryQc`, `badGeometry`, `GeometryCheck`, `GeometryFlag`, `GeometryFlags` | Survey QC issue list, flags in table and map | planned |
| First-break picking with confidence | `initFirstBreakPlan`, `pickInto` (also on the pool), `FirstBreakParams`, `FirstBreakPick`, `checkPick`, `FirstBreakPlan` (`params`, `pick`), `PickMethod`, `noPick` | First-break overlay coloured by confidence | planned |
| Refraction fit per shot (swapped receivers, misplaced source) | `fitShot`, `ShotFitParams`, `ShotFit` (`suspect`, `asymmetryMs`, `v1`, `v2`), `RefractionModel` | Survey QC issue list; fitted model drawn over the picks | planned |
| Windowed SNR per trace | `windowSnrInto`, `WindowSnrParams`, `powerSnrDb`, `windowSnrDb`, `meanPower`, `SnrEstimator`, `DefaultSnrFloorDb` | SNR attribute: table column, map colour, flag threshold | planned |
| Coherence SNR of a flattened gather | `coherenceSnrInto`, `coherenceSnrWorkspace` | SNR-against-time plot for an NMO or LMO flattened gather | planned |
| Amplitude flags per trace (dead, clipped, spiky, DC, weak, noisy) | `traceAmplitudeInto` (also on the pool), `AmplitudeParams`, `AmplitudeFlag`, `TraceAmplitude`, `traceAmplitude`, `traceAmplitudeWorkspace` | The map's filters on the record shown (each flag a filter, default thresholds, a job per record shown); trace flags with thresholds on a histogram | built (the map's filters); planned (thresholds, the survey) |
| Record-level amplitude outliers | `recordAmplitude`, `RecordAmplitude` (`robustZ`), `recordAmplitudeWorkspace` | The map's filters weak and noisy on the record shown; trace flags (weak, noisy) survey-wide | built (the map's filters); planned (the survey) |
| Automatic bin grid of a survey | `surveyGrid` | Fold map: grid proposed from the SPS | planned |
| Pre-plot, actual and difference fold | `preplotFold`, `initFoldMap`, `addFold`, `foldDifference`, `FoldMap` (`fold`, `binned`, `outside`, `noCoordinates`, `notLive`, `options`), `clone` | Fold map layers and their difference | planned |
| Fold by offset class and azimuth sector, offset range | `FoldOptions`, `offsetFold`, `azimuthFold`, `offsetMin`, `offsetMax` | Fold map: offset-class and azimuth layers, min / max offset maps | planned |
| Field records against the XPS | `recordCompleteness`, `RecordCompleteness`, `RecordMatch`, `TraceMatch` | Records window: each record's stations missing against the loaded relation file, or the relation records of the survey imported (`expected`, `missing`, `unlisted`, `duplicates` in the cell's tooltip; a job per open file; the record and trace match chosen in Import survey's options); the map's filters missing from the template (`missingStations`), not in the template, recorded twice, on the record shown; survey QC issue list: missing, unlisted, duplicate stations | built (Records, the map's filters); planned (the issue list) |
| Missing stations of a record | `RecordCompleteness.missingStations`, `missingRanges`, `lines`, `StationRange`, `LineCompleteness` | Missing-stations map layer | planned |
| Completeness over many records | `summarize`, `CompletenessSummary` | QC report section | planned |

### Vibroseis

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Sweep tapers (nine shapes) | `initSweepTaper`, `TaperShape`, `applyTaper`, `taperWeight`, `noTaper`, `SweepTaper`, `checkFits` | Compare pilots: generated pilot's tapers | planned |
| Sweep generation (linear, dB/octave, dB/Hz, exponential, table) | `linearSweep`, `dbPerOctaveSweep`, `dbPerHzSweep`, `exponentialSweep`, `tableSweep`, `generatePilot`, `sweepSamples`, `SweepSpec`, `SweepLaw`, `SweepPoint`, `sweepLen`, `sweepInto` | Compare pilots: generated source | planned |
| Instantaneous frequency and phase | `frequencyAt`, `phaseAt` | Compare pilots: frequency at the cursor | planned |
| Recorded pilot from a trace | `pilotFromTrace`, `pilotFromRow`, `sweepFromHeaders`, `energyAbove`, `initPilot`, `Pilot` (`lengthMs`) | Compare pilots: recorded source | planned |
| Pilot resampled to the data | `resamplePilot` | Compare pilots | planned |
| Recorder's instrument filter on a pilot | `InstrumentFilter`, `applyInstrumentFilter` | Compare pilots: "apply recorder filter" | planned |
| Pilot saved with its sweep fields | `pilotKeys`, `sweepOverrides`, `segySweepType`, `segyTaperType` | Compare pilots: save the generated pilot as SEG-Y | planned |
| Correlation of uncorrelated records | `initCorrelationPlan`, `correlateInto` (also on the pool), `correlate`, `CorrelationPlan` (`outSamples`, `pilotSamples`, `mode`), `checkCorrelate`, `CorrelationMode` | Correlate records for display | planned |
| Sweep deconvolution | `initCorrelationPlan(mode = cmDeconvolve)` | Correlate records: deconvolve mode | planned |
| Vertical and diversity stack of repeated sweeps | `initRecordStack`, `addRecord`, `RecordStackParams`, `recordStackMemory`, `RecordStack` (`countAt`), `RecordStackMode`, `DiversityWeight` | "Stack repeated sweeps" at a source point | planned |

### Continuous recordings

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Cut continuous node data into records at shot times | `initSliceStreams`, `planSlices`, `extractInto`, `sliceKeys`, `SliceShot`, `SliceWindow`, `SliceStreams` (`rowCount`, `receiverKeys`), `SlicePlan` (`margin`, `order`, `align`, `window`, `shotCount`, `receiverCount`, `shotOf`, `receiverOf`, `rowsNeeded`, `tracesNeeded`, `maxColumn`, `fraction`), `initSliceShot`, `SliceOrder`, `SliceAlign`, `SlicePiece`, `pieces`, `sliceWorkspace` | "Cut at shot times…" (shots from SPS / P1 or a list), result as a virtual file | planned |
| Gaps, overlaps and timing errors | `SliceReport`, `gaps`, `overlapCheck`, `timingIssues`, `untimed`, `otherInterval`, `initSliceReport`, `gapSamples`, `gapCount`, `SliceGap`, `SliceOverlap`, `SliceTimingIssue`, `OverlapStatus`, `SliceOverlapCheck`, `mismatches`, `overlaps` | Continuous data QC per receiver | planned |
| Clock drift correction | `driftCorrectTimes`, `driftCorrectedTimes` | Node clock drift correction | planned |

### Survey design

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Receiver layout (azimuth, interval, line spacing) | `receiverLayout`, `inlineOf`, `crosslineOf`, `ReceiverLayout`, `ReceiverLine`, `LineStation` | Survey summary in File properties; map in the layout frame | to plan (priority 5) |
| Patch description (template, clipped records) | `describePatches`, `PatchDescription`, `RecordPatch`, `spreadOf`, `PatchSide`, `PatchLine`, `Spread`, `$` | Patch QC: template, clipped records on the map | planned |
| X records generated from a template or distance box | `PatchTemplate`, `initPatchTemplate`, `initDistancePatch`, `patchShots`, `generateRelations`, `receiverLayout` | The map's template box when no relation file is loaded: the spreads generated on a job from the user's template (lines × stations, or a distance box), said to be generated; writing them as an XPS file | built (the map); planned (the export) |
| Listed against generated relations | `compareRelations`, `RecordAgreement`, `jaccard`, `listedFraction`, `describePatches` | The map's filter "spread not the template": the shots whose X record agrees with the template the records describe far less than the survey's do; receivers dropped in the field, per shot | built (the filter); planned (per shot) |
| A template's edges and placement | `PatchEdge`, `PatchPlacement`, `NumberMap`, `PatchBox`, `PatchShot`, `hasTemplate`, `hasDistance` | The template's options where X records are generated (above): the map's template box makes its shots (`PatchShot`) | built (the map's template box); planned (the edge and placement options) |

## In the next library release

What the branches about to be released add, read from their working trees: parseSEG's next
release after 0.11.0 and processSEG's after 0.4.0. The check holds these tables to the new
names when a working tree of each is linked at `deps/next/parseSEG` and
`deps/next/processSEG`.

### parseSEG (after 0.11.0)

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| A file cut short while it is open, and a read that fails: no crash | `cutShort`, `readFailed` (`SeismicFile`, `MemFileSource`), `readable`, `dcTruncated`, `dcIo` | The viewer's own `cutShort` (a `stat` before each read) gives way to parseSEG's: another program cutting the file shown no longer ends the program with "Bus error"; the traces past the cut drawn blank and said so; a share that stops answering fails its rows with `dcIo` | planned |
| Datum and projection as values | `crs` (an SPS file's, a seismic file's), `parseCrsText`, `CoordinateReference`, `CrsKind`, `GeodeticDatum`, `MapProjection`, `CrsParameter`, `parameter`, `kindOf`, `known` | Join geometry and File properties: the datum, ellipsoid, projection and zone in words, to check the survey files against the seismic files; the basemap's coordinate system | planned |
| Survey files read with progress and cancel | `readSps(..., progress)`, `readP1(..., progress)`, `SpsOptions` (`skipBinary`, `maxJunkBytes`), `looksLikeSps` (a head of header records) | Loading survey files: one call with parseSEG's progress and cancel, in place of the viewer's 4 MiB chunks and its own test of a head of header records | planned |
| Sources released on any thread | `openMemFileSource`, `MemFileSource` | Files closed on the viewer's closer thread without the cycle collector's care | planned |
| A file on a network share opened without mapping it (being written, not on the branch yet) | `openSeismic`, `OpenOptions` | Files on a slow or failing share read by `pread`, as the viewer's reads of network drives want | planned |

### processSEG (after 0.4.0)

| Capability | Library calls | Viewer feature | Status |
|---|---|---|---|
| Recorded values in physical units: sensors, masses and recorder scales | `AmplitudeUnit` (`auRecorded`, `auVolt`, `auVelocity`, `auAcceleration`, `auPressure`, `auForce`), `Sensitivity`, `SensitivityUnit`, `SensitivityForm`, `sensitivity`, `openCircuitSensitivity`, `form`, `unit`, `valueIn`, `voltsPerUnit`, `quantityOf`, `isSet`, `Mass`, `MassUnit`, `mass`, `kilograms`, `Descale`, `DescaleUnit`, `descale`, `voltsPerCount`, `FileScale`, `initFileScale` | Amplitudes in volts, m/s, m/s², Pa or N where the user sets up a sensor table (off otherwise): the readout's unit, the vibrator force plots | to plan (priority 10) |
| Calibration of recorded traces | `Calibration`, `CalibrationPlan`, `CalibrationRule`, `CalibrationStatus`, `CalibrationSummary`, `CalibrationTarget`, `FactorSource`, `FileFactors`, `RatioRange`, `RowCalibration`, `RuleMatch`, `calibrate`, `calibrateInto`, `initCalibration`, `initCalibrationPlan`, `ratioDbInto`, `resolveInto`, `scaleInto`, `scaleRows`, `scaleRowsInto`, `uncalibrate`, `uncalibrateInto` | The sensor table's rules applied per trace, before any gain; what each trace was converted with, and what could not be | to plan (priority 10) |
| A file's own scales | `ScaleGroup`, `fileScalesInto`, `scaleReport`, `segyUnitOverrides`, `fileScale`, `hasFileScales` | File properties: each channel set's recorder scale and units as the file gives them, to check against the sensor sheet | to plan (priority 6: what the file says of its scales, also without a sensor table) |
| Calibration in a pipeline | `calibrateOp`, `uncalibrateOp`, `OpKind` (`opCalibrate`, `opUncalibrate`), `PlanAmplitude`, `amplitudeUnits`, `calibration` | The display pipeline with the calibration first, its plots labelled in the unit | to plan (priority 10) |
| Vibrator signature analysis: roles, ground force, limits | `analyzeVibrators`, `VibUnit`, `initVibUnit`, `VibRole`, `VibSignal`, `vibUnitsInOrder`, `defaultOrder`, `groundForceInto`, `VibLimits`, `LimitKind`, `limitFlagsInto`, `UnitSignature`, `TrackSummary`, `vibratorWorkspace` | Vibrator signature analysis: the selected traces' roles (reference, ground force, mass, baseplate), ground force from mass and baseplate, limits drawn when asked | planned |
| Phase, force and frequency against sweep time; harmonics and THD | `SweepTrack`, `SweepTrackPlan`, `initSweepTrack`, `initSweepTrackPlan`, `trackInto`, `compareTracksInto`, `distortionInto`, `harmonics`, `SweepReference`, `initSweepReference`, `referenceInto`, `ThdReference`, `TrackParams`, `isMeasured`, `pointMs`, `points`, `span`, `stepSamples`, `wrapDeg` | Vibrator signature analysis: the QC analysis and distortion plots | planned |
| Correlation with its envelope, spectrum and phase; comparisons | `CrossCorrelationPlan`, `initCrossCorrelationPlan`, `crossCorrelateInto`, `compareInto`, `lagSpectrumInto`, `CorrelationNorm`, `lagMs`, `lags`, `maxLag`, `HilbertPlan`, `initHilbertPlan`, `hilbertInto`, `envelopeInto` | Vibrator signature analysis: the correlation and comparison plots | planned |
| Time-variant spectrum | `SpectrogramPlan`, `initSpectrogramPlan`, `spectrogramInto`, `frames`, `frameCol`, `hop` | Vibrator signature analysis: time-variant spectral analysis | planned |

## Not exposed

| What | Why |
|---|---|
| parseSEG command line tool (`parseSEG/cli`) | The viewer offers the same operations through menus. |
| `parseSEG/private`, processSEG `survey/relwalk`, `core/sums`, `vibroseis/kaiser`, and procs marked **Internal** (`planKeys`, `finishKeys`) | Not part of either public API. |
| Arraymancer's tensor API and `std/options`, which the libraries re-export | Not the libraries' own. |
