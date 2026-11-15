## Descriptions of the header fields parseSEG names, by block type, for the
## header tables' "Description" column.
##
## Sources: the SEG-Y rev 2.1 and SEG-D rev 2.1 / 3.1 standards, and the doc
## comments of parseSEG's header types. Each block type has a table of
## `(field, description)` pairs in the block's field order; `fieldDescription`
## looks a field up there, and falls back to `wordsOf(field)` for a field the
## tables do not know (a SEG-2 keyword string, a raw block's "").

import std/strutils
import parseSEG

const
  SegyBinaryDocs = [
    ("jobId", "Job identification number"),
    ("lineNumber", "Line number (seismic line on the reel)"),
    ("reelNumber", "Reel number"),
    ("dataTracesPerEnsemble", "Data traces per ensemble"),
    ("auxTracesPerEnsemble", "Auxiliary traces per ensemble"),
    ("sampleInterval", "Sample interval (µs, or Hz or m/ft)"),
    ("sampleIntervalOrig", "Sample interval of the original recording"),
    ("samplesPerTrace", "Samples per trace"),
    ("samplesPerTraceOrig", "Samples per trace of the original recording"),
    ("formatCode", "Data sample format code"),
    ("ensembleFold", "Ensemble fold (expected traces per ensemble)"),
    ("traceSorting", "Trace sorting code (type of ensemble)"),
    ("verticalSumCode", "Vertical sum code (1 no sum, 2 two sum, ...)"),
    ("sweepFreqStart", "Sweep frequency at start (Hz)"),
    ("sweepFreqEnd", "Sweep frequency at end (Hz)"),
    ("sweepLength", "Sweep length (ms)"),
    ("sweepType", "Sweep type code"),
    ("sweepChannel", "Trace number of the sweep channel"),
    ("sweepTaperStart", "Sweep taper length at start (ms)"),
    ("sweepTaperEnd", "Sweep taper length at end (ms)"),
    ("taperType", "Taper type code"),
    ("correlated", "Correlated data traces (1 no, 2 yes)"),
    ("binaryGainRecovered", "Binary gain recovered (1 yes, 2 no)"),
    ("amplitudeRecovery", "Amplitude recovery method code"),
    ("measurementSystem", "Measurement system (1 metres, 2 feet)"),
    ("impulsePolarity", "Impulse signal polarity code"),
    ("vibratoryPolarity", "Vibratory polarity code"),
    ("extDataTracesPerEnsemble", "Data traces per ensemble (32-bit, when non-zero)"),
    ("extAuxTracesPerEnsemble", "Auxiliary traces per ensemble (32-bit, when non-zero)"),
    ("extSamplesPerTrace", "Samples per trace (32-bit, when non-zero)"),
    ("extSampleInterval", "Sample interval (64-bit float, when non-zero)"),
    ("extSampleIntervalOrig", "Original sample interval (64-bit float, when non-zero)"),
    ("extSamplesPerTraceOrig", "Original samples per trace (32-bit, when non-zero)"),
    ("extEnsembleFold", "Ensemble fold (32-bit, when non-zero)"),
    ("byteOrderMarker", "Byte order marker (0x01020304)"),
    ("segyMajor", "SEG-Y major revision number"),
    ("segyMinor", "SEG-Y minor revision number"),
    ("fixedLengthTraces", "Fixed length trace flag (1 every trace the same)"),
    ("numExtTextHeaders", "Number of extended textual headers (-1 variable)"),
    ("timeBasisCode", "Time basis code (1 local, 2 GMT, 4 UTC, 5 GPS)"),
    ("numTraces", "Number of traces in the file (0 unknown)"),
    ("firstTraceOffset", "Byte offset of the first trace (0 unknown)"),
    ("numTrailerRecords", "Number of trailer stanza records (-1 unknown)")]

  SegyTraceDocs = [
    ("traceSeqLine", "Trace sequence number within line"),
    ("traceSeqFile", "Trace sequence number within file"),
    ("fieldRecord", "Original field record number"),
    ("traceNumberInField", "Trace number within the field record"),
    ("energySourcePoint", "Energy source point number"),
    ("ensembleNumber", "Ensemble number (CDP, CMP, ...)"),
    ("traceInEnsemble", "Trace number within the ensemble"),
    ("traceIdCode", "Trace identification code"),
    ("numVertSummed", "Number of vertically summed traces"),
    ("numHorzStacked", "Number of horizontally stacked traces"),
    ("dataUse", "Data use (1 production, 2 test)"),
    ("offset", "Distance from source point to receiver group"),
    ("receiverElevation", "Receiver group elevation (× elevation scalar)"),
    ("sourceSurfaceElevation", "Surface elevation at source (× elevation scalar)"),
    ("sourceDepth", "Source depth below surface (× elevation scalar)"),
    ("receiverDatumElevation", "Datum elevation at receiver group (× elev. scalar)"),
    ("sourceDatumElevation", "Datum elevation at source (× elevation scalar)"),
    ("sourceWaterDepth", "Water depth at source (× elevation scalar)"),
    ("groupWaterDepth", "Water depth at receiver group (× elevation scalar)"),
    ("elevationScalar", "Scalar for elevations and depths"),
    ("coordinateScalar", "Scalar for coordinates"),
    ("sourceX", "Source X coordinate (× coordinate scalar)"),
    ("sourceY", "Source Y coordinate (× coordinate scalar)"),
    ("groupX", "Receiver group X coordinate (× coordinate scalar)"),
    ("groupY", "Receiver group Y coordinate (× coordinate scalar)"),
    ("coordinateUnits", "Coordinate units (1 length, 2 arc sec, 3 deg, 4 DMS)"),
    ("weatheringVelocity", "Weathering velocity"),
    ("subweatheringVelocity", "Subweathering velocity"),
    ("upholeTimeSource", "Uphole time at source (ms × time scalar)"),
    ("upholeTimeGroup", "Uphole time at receiver group (ms × time scalar)"),
    ("sourceStatic", "Source static correction (ms × time scalar)"),
    ("groupStatic", "Receiver group static correction (ms × time scalar)"),
    ("totalStatic", "Total static applied (ms × time scalar)"),
    ("lagTimeA", "Lag time A, shot to time break (ms × time scalar)"),
    ("lagTimeB", "Lag time B, time break to shot (ms × time scalar)"),
    ("delayRecordingTime", "Delay recording time (ms × time scalar)"),
    ("muteStart", "Mute time at start (ms × time scalar)"),
    ("muteEnd", "Mute time at end (ms × time scalar)"),
    ("numSamples", "Number of samples in this trace"),
    ("sampleInterval", "Sample interval (µs, or Hz or m/ft)"),
    ("gainType", "Gain type of field instruments"),
    ("instrumentGainConstant", "Instrument gain constant (dB)"),
    ("instrumentInitialGain", "Instrument early or initial gain (dB)"),
    ("correlated", "Correlated (1 no, 2 yes)"),
    ("sweepFreqStart", "Sweep frequency at start (Hz)"),
    ("sweepFreqEnd", "Sweep frequency at end (Hz)"),
    ("sweepLength", "Sweep length (ms)"),
    ("sweepType", "Sweep type code"),
    ("sweepTaperStart", "Sweep taper length at start (ms)"),
    ("sweepTaperEnd", "Sweep taper length at end (ms)"),
    ("taperType", "Taper type code"),
    ("aliasFilterFreq", "Alias filter frequency (Hz)"),
    ("aliasFilterSlope", "Alias filter slope (dB/octave)"),
    ("notchFilterFreq", "Notch filter frequency (Hz)"),
    ("notchFilterSlope", "Notch filter slope (dB/octave)"),
    ("lowCutFreq", "Low-cut frequency (Hz)"),
    ("highCutFreq", "High-cut frequency (Hz)"),
    ("lowCutSlope", "Low-cut slope (dB/octave)"),
    ("highCutSlope", "High-cut slope (dB/octave)"),
    ("year", "Year the data was recorded"),
    ("dayOfYear", "Day of year"),
    ("hour", "Hour of day (24 hour clock)"),
    ("minute", "Minute of hour"),
    ("second", "Second of minute"),
    ("timeBasisCode", "Time basis code (1 local, 2 GMT, 4 UTC, 5 GPS)"),
    ("traceWeightingFactor", "Trace weighting factor (LSB = 2^-N volts)"),
    ("rollSwitchGroup", "Geophone group number of roll switch position one"),
    ("firstTraceGroup", "Geophone group number of trace number one"),
    ("lastTraceGroup", "Geophone group number of last trace"),
    ("gapSize", "Gap size (total number of groups dropped)"),
    ("overTravel", "Over travel of taper (1 down or behind, 2 up or ahead)"),
    ("cdpX", "CDP X coordinate (× coordinate scalar)"),
    ("cdpY", "CDP Y coordinate (× coordinate scalar)"),
    ("inlineNumber", "Inline number (3D poststack data)"),
    ("crosslineNumber", "Crossline number (3D poststack data)"),
    ("shotpointNumber", "Shotpoint number (× shotpoint scalar)"),
    ("shotpointScalar", "Scalar for the shotpoint number (0 not scaled)"),
    ("traceValueUnit", "Trace value measurement unit code"),
    ("transductionMantissa", "Transduction constant, mantissa"),
    ("transductionExponent", "Transduction constant, power of ten"),
    ("transductionUnits", "Transduction units code"),
    ("deviceTraceId", "Device or trace identifier"),
    ("timeScalar", "Scalar for times in bytes 95-114"),
    ("sourceTypeOrientation", "Source type and orientation code"),
    ("sourceEnergyDirVert", "Source energy direction, vertical (tenths of a degree)"),
    ("sourceEnergyDirXline", "Source energy direction, crossline (tenths of a degree)"),
    ("sourceEnergyDirInline", "Source energy direction, inline (tenths of a degree)"),
    ("sourceMeasurementMantissa", "Source measurement, mantissa"),
    ("sourceMeasurementExponent", "Source measurement, power of ten"),
    ("sourceMeasurementUnit", "Source measurement unit code"),
    ("headerName", "Trace header name (SEG00000)")]

  SegyExt1Docs = [
    ("extTraceSeqLine", "Trace sequence number within line (64-bit)"),
    ("extTraceSeqFile", "Trace sequence number within file (64-bit)"),
    ("extFieldRecord", "Original field record number (64-bit)"),
    ("extEnsembleNumber", "Ensemble number (64-bit)"),
    ("extReceiverElevation", "Receiver group elevation (64-bit float, unscaled)"),
    ("receiverDepth", "Receiver depth below its surface (unscaled)"),
    ("extSourceSurfaceElevation", "Surface elevation at source (64-bit float, unscaled)"),
    ("extSourceDepth", "Source depth below surface (64-bit float, unscaled)"),
    ("extReceiverDatumElevation", "Datum elevation at receiver (64-bit float, unscaled)"),
    ("extSourceDatumElevation", "Datum elevation at source (64-bit float, unscaled)"),
    ("extSourceWaterDepth", "Water depth at source (64-bit float, unscaled)"),
    ("extGroupWaterDepth", "Water depth at receiver group (64-bit float, unscaled)"),
    ("extSourceX", "Source X coordinate (64-bit float, unscaled)"),
    ("extSourceY", "Source Y coordinate (64-bit float, unscaled)"),
    ("extGroupX", "Receiver group X coordinate (64-bit float, unscaled)"),
    ("extGroupY", "Receiver group Y coordinate (64-bit float, unscaled)"),
    ("extOffset", "Source to receiver group distance (64-bit float)"),
    ("extNumSamples", "Samples in this trace (32-bit, when non-zero)"),
    ("nanoseconds", "Nanoseconds to add to the second of the time stamp"),
    ("extSampleInterval", "Sample interval (64-bit float, when non-zero)"),
    ("cableNumber", "Cable number or recording device ID"),
    ("numAddlTraceHeaders", "Number of additional trace headers (including this one)"),
    ("lastTraceFlag", "Last trace flag (1 ensemble, 2 line, 4 file, 8 survey)"),
    ("extCdpX", "CDP X coordinate (64-bit float, unscaled)"),
    ("extCdpY", "CDP Y coordinate (64-bit float, unscaled)"),
    ("headerName", "Trace header extension name (SEG00001)")]

  SegdTraceDocs = [
    ("fileNumber", "File number (BCD)"),
    ("scanTypeNumber", "Scan type number"),
    ("channelSetNumber", "Channel set number"),
    ("traceNumber", "Trace number within the channel set"),
    ("firstTimingWord", "First timing word (ms)"),
    ("traceHeaderExtensions", "Number of trace header extension blocks"),
    ("sampleSkew", "Sample skew (fraction of a base scan interval, in 1/256)"),
    ("traceEdit", "Trace edit code"),
    ("timeBreakWindow", "Time break window (ms)"),
    ("extChannelSetNumber", "Extended channel set number"),
    ("extFileNumber", "Extended file number")]

  SegdExt1Docs = [
    ("receiverLineNumber", "Receiver line number"),
    ("receiverPointNumber", "Receiver point number"),
    ("receiverPointIndex", "Receiver point index"),
    ("samplesPerTrace", "Number of samples per trace"),
    ("extReceiverLineNumber", "Extended receiver line number (fixed point)"),
    ("extReceiverPointNumber", "Extended receiver point number (fixed point)"),
    ("sensorType", "Sensor type (1 hydrophone, 2-5 geophone, 6-9 accel.)")]

  SegdExt1Rev3Docs = [
    ("receiverLineNumber", "Receiver line number"),
    ("receiverPointNumber", "Receiver point number"),
    ("receiverPointIndex", "Receiver point index"),
    ("reshootIndex", "Reshoot index"),
    ("groupIndex", "Group index (component number)"),
    ("depthIndex", "Depth index"),
    ("extReceiverLineNumber", "Extended receiver line number (fixed point)"),
    ("extReceiverPointNumber", "Extended receiver point number (fixed point)"),
    ("sensorType", "Sensor type code"),
    ("extTraceNumber", "Extended trace number"),
    ("numSamples", "Number of samples in the trace"),
    ("sensorMoving", "Sensor moving flag"),
    ("undef30", "Undefined"),
    ("physicalUnit", "Physical unit of the trace data"),
    ("blockType", "Block type (0x40)")]

  SegdGh1Docs = [
    ("fileNumber", "File number (BCD)"),
    ("formatCode", "Data sample format code"),
    ("year", "Year (last two digits)"),
    ("additionalGhBlocks", "Number of additional general header blocks"),
    ("julianDay", "Day of year"),
    ("hour", "Hour of day (UTC)"),
    ("minute", "Minute of hour"),
    ("second", "Second of minute"),
    ("manufacturerCode", "Manufacturer's code"),
    ("manufacturerSerial", "Manufacturer's serial number of the system"),
    ("baseScanInterval16", "Base scan interval (units of 1/16 ms)"),
    ("polarity", "Polarity code"),
    ("unused24L", "Unused (scans per block exponent in Rev 0)"),
    ("unused25", "Unused (scans per block in Rev 0)"),
    ("recordType", "Record type (8 normal record)"),
    ("recordLength", "Record length (× 1.024 s)"),
    ("scanTypesPerRecord", "Scan types per record"),
    ("channelSetsPerScanType", "Channel sets per scan type"),
    ("skewBlocks", "Number of 32-byte skew blocks"),
    ("extendedHeaderBlocks", "Number of 32-byte extended header blocks"),
    ("externalHeaderBlocks", "Number of 32-byte external header blocks")]

  SegdGhNDocs = [
    ("extFileNumber", "Extended file number"),
    ("sourceLineNumber", "Source line number"),
    ("sourcePointNumber", "Source point number"),
    ("sourcePointIndex", "Source point index"),
    ("phaseControl", "Phase control code"),
    ("vibratorType", "Vibrator type code"),
    ("phaseAngle", "Phase angle (degrees)"),
    ("blockNumber", "General header block number"),
    ("sourceSetNumber", "Source set number")]

  SegdGh2Docs = [
    ("extFileNumber", "Extended file number"),
    ("extChannelSetsPerScanType", "Channel sets per scan type (extended)"),
    ("extExtendedHeaderBlocks", "Extended header blocks (extended count)"),
    ("extExternalHeaderBlocks", "External header blocks (extended count)"),
    ("undef10", "Undefined"),
    ("revisionMajor", "SEG-D revision number, major"),
    ("revisionMinor", "SEG-D revision number, minor"),
    ("generalTrailerBlocks", "Number of general trailer blocks"),
    ("extRecordLength", "Extended record length (ms)"),
    ("undef18", "Undefined"),
    ("blockNumber", "General header block number (2)"),
    ("undef20", "Undefined"),
    ("lineSequenceNumber", "Line sequence number")]

  SegdGh2Rev3Docs = [
    ("extFileNumber", "Extended file number"),
    ("extChannelSetsPerScanType", "Channel sets per scan type (extended)"),
    ("extExtendedHeaderBlocks", "Extended header blocks (extended count)"),
    ("extSkewBlocks", "Skew blocks (extended count)"),
    ("revisionMajor", "SEG-D revision number, major"),
    ("revisionMinor", "SEG-D revision number, minor"),
    ("generalTrailerBlocks", "Number of general trailer blocks"),
    ("extRecordLength", "Extended record length (µs)"),
    ("recordSetNumber", "Record set number"),
    ("extAdditionalGhBlocks", "Additional general header blocks (extended count)"),
    ("dominantSamplingInterval", "Dominant sampling interval (µs)"),
    ("extExternalHeaderBlocks", "External header blocks (extended count)"),
    ("undef31", "Undefined"),
    ("blockType", "Block type (0x02)")]

  SegdGh3Rev3Docs = [
    ("timeZero", "Time zero of the record (µs since the GPS epoch)"),
    ("recordSize", "Record size in bytes (0 unknown)"),
    ("dataSize", "Size of the headers and traces in bytes"),
    ("headerSize", "Size of the headers (offset of the first trace)"),
    ("extendedRecordingMode", "Extended recording mode"),
    ("relativeTimeMode", "Relative time mode"),
    ("undef31", "Undefined"),
    ("blockType", "Block type (0x03)")]

  SegdChannelSetDocs = [
    ("scanTypeNumber", "Scan type number"),
    ("channelSetNumber", "Channel set number"),
    ("startTime", "Channel set start time (× 2 ms)"),
    ("endTime", "Channel set end time (× 2 ms)"),
    ("channelCount", "Number of channels in the set (0 unused)"),
    ("channelType", "Channel type (1 seismic, 9 signature filtered, ...)"),
    ("zero11L", "Unused (zero)"),
    ("subscanExponent", "Sample interval exponent (base interval / 2^n)"),
    ("gainControl", "Channel gain control method"),
    ("aliasFilterFreq", "Alias filter frequency (Hz)"),
    ("zero15H", "Unused (zero)"),
    ("aliasFilterSlope", "Alias filter slope (dB/octave)"),
    ("lowCutFreq", "Low-cut filter frequency (Hz)"),
    ("zero19H", "Unused (zero)"),
    ("lowCutSlope", "Low-cut filter slope (dB/octave)"),
    ("notch1Freq", "First notch filter frequency (tenths of Hz)"),
    ("notch2Freq", "Second notch filter frequency (tenths of Hz)"),
    ("notch3Freq", "Third notch filter frequency (tenths of Hz)"),
    ("extChannelSetNumber", "Extended channel set number"),
    ("extendedHeaderFlag", "Extended header flag"),
    ("traceHeaderExtensions", "Trace header extension blocks per trace"),
    ("verticalStack", "Vertical stack (number of records summed)"),
    ("streamerNumber", "Streamer cable number"),
    ("arrayForming", "Array forming code")]

  SegdChannelSetRev3Docs = [
    ("scanTypeNumber", "Scan type number"),
    ("channelSetNumber", "Channel set number"),
    ("channelType", "Channel type code"),
    ("startTime", "Channel set start time (µs)"),
    ("endTime", "Channel set end time (µs)"),
    ("numSamples", "Number of samples per trace"),
    ("descaleMultiplier", "Descale multiplier (mV per unit)"),
    ("channelsInSet", "Number of traces in the set (0 unused)"),
    ("samplingInterval", "Sampling interval (µs)"),
    ("arrayForming", "Array forming code"),
    ("traceHeaderExtensions", "Trace header extension blocks per trace"),
    ("extendedHeaderFlag", "Extended header flag"),
    ("channelGainControl", "Channel gain control method"),
    ("verticalStack", "Vertical stack (number of records summed)"),
    ("streamerNumber", "Streamer cable number"),
    ("blockType1", "Block type (0x30)"),
    ("aliasFilterFreq", "Alias filter frequency (Hz)"),
    ("lowCutFilterFreq", "Low-cut filter frequency (Hz)"),
    ("aliasFilterSlope", "Alias filter slope (dB/octave)"),
    ("lowCutFilterSlope", "Low-cut filter slope (dB/octave)"),
    ("notch1Freq", "First notch filter frequency (Hz)"),
    ("notch2Freq", "Second notch filter frequency (Hz)"),
    ("notch3Freq", "Third notch filter frequency (Hz)"),
    ("filterPhase", "Filter phase code"),
    ("physicalUnit", "Physical unit of the trace data"),
    ("undef63", "Undefined"),
    ("blockType2", "Block type (0x31)"),
    ("filterDelay", "Filter delay"),
    ("description", "Channel set description text"),
    ("blockType3", "Block type (0x32)")]

  SegdPositionDocs = [
    ("timeOfPosition", "Time of the position (µs since the GPS epoch)"),
    ("timeOfMeasurement", "Time of the measurement (µs since the GPS epoch)"),
    ("verticalError", "Vertical error"),
    ("horizErrorSemiMajor", "Horizontal error ellipse, semi-major axis"),
    ("horizErrorSemiMinor", "Horizontal error ellipse, semi-minor axis"),
    ("horizErrorOrientation", "Horizontal error ellipse orientation"),
    ("positionType", "Position type code"),
    ("blockType1", "Block type (0x50)"),
    ("tuple1Coord1", "First position, coordinate 1"),
    ("tuple1Coord2", "First position, coordinate 2"),
    ("tuple1Coord3", "First position, coordinate 3"),
    ("stanzaId1", "First position, coordinate system (CRS) identifier"),
    ("position1Valid", "First position valid flag"),
    ("position1Quality", "First position quality code"),
    ("blockType2", "Block type (0x51)"),
    ("tuple2Coord1", "Second position, coordinate 1"),
    ("tuple2Coord2", "Second position, coordinate 2"),
    ("tuple2Coord3", "Second position, coordinate 3"),
    ("stanzaId2", "Second position, coordinate system (CRS) identifier"),
    ("position2Valid", "Second position valid flag"),
    ("position2Quality", "Second position quality code"),
    ("blockType3", "Block type (0x52)")]

  SegdSourceDescriptionDocs = [
    ("extFileNumber", "Extended file number"),
    ("sourceLineNumber", "Source line number"),
    ("sourcePointNumber", "Source point number"),
    ("sourcePointIndex", "Source point index"),
    ("sourceId", "Source identifier"),
    ("sourceSetNumber", "Source set number"),
    ("reshootIndex", "Reshoot index"),
    ("groupIndex", "Group index"),
    ("depthIndex", "Depth index"),
    ("offsetCrossline", "Source offset, crossline"),
    ("offsetInline", "Source offset, inline"),
    ("offsetDepth", "Source offset, depth"),
    ("blockType", "Block type (source kind)")]

  SegdAdditionalSourceInfoDocs = [
    ("time", "Time of the source information (µs since the GPS epoch)"),
    ("sourceStatus", "Source status code"),
    ("sourceId", "Source identifier"),
    ("sourceMoving", "Source moving flag"),
    ("errorDescription", "Source error description text"),
    ("blockType", "Block type (0x20)")]

  SegdSensorInfoDocs = [
    ("instrumentTestTime", "Instrument test time (µs since the GPS epoch)"),
    ("sensorSensitivity", "Sensor sensitivity"),
    ("instrumentTestResult", "Instrument test result code"),
    ("serialNumber", "Sensor serial number"),
    ("blockType", "Block type (0x41)")]

  SegdTimestampDocs = [
    ("timeZeroOfData", "Time of the first sample (µs since the GPS epoch)"),
    ("blockType", "Block type (0x42)")]

  SegdSensorCalibrationDocs = [
    ("frequency1", "First calibration frequency (Hz)"),
    ("amplitude1", "First calibration amplitude"),
    ("phase1", "First calibration phase"),
    ("frequency2", "Second calibration frequency (Hz)"),
    ("amplitude2", "Second calibration amplitude"),
    ("phase2", "Second calibration phase"),
    ("calibrationApplied", "Calibration applied flag"),
    ("blockType", "Block type (0x43)")]

  SegdTimeDriftDocs = [
    ("timeOfDeployment", "Time of deployment (µs since the GPS epoch)"),
    ("timeOfRetrieval", "Time of retrieval (µs since the GPS epoch)"),
    ("timeOffsetDeployment", "Clock offset at deployment (µs)"),
    ("timeOffsetRetrieval", "Clock offset at retrieval (µs)"),
    ("timeDriftCorrected", "Time drift corrected flag"),
    ("correctionMethod", "Time drift correction method code"),
    ("blockType", "Block type (0x44)")]

  SegdOrientationDocs = [
    ("rotationX", "Rotation about the X axis (radians)"),
    ("rotationY", "Rotation about the Y axis (radians)"),
    ("rotationZ", "Rotation about the Z axis (radians)"),
    ("referenceOrientation", "Reference orientation (radians)"),
    ("timestamp", "Time of the orientation (µs since the GPS epoch)"),
    ("orientationType", "Orientation type code"),
    ("refOrientationValid", "Reference orientation valid flag"),
    ("rotationApplied", "Rotation applied flag"),
    ("rotationNorthApplied", "Rotation to north applied flag"),
    ("blockType", "Block type (0x60)")]

  SegdTrailerDescriptionDocs = [
    ("trailerBlockType", "Block type of the trailer blocks that follow"),
    ("asciiOrBinary", "Trailer data format (1 binary, 2 ASCII)"),
    ("zero3", "Unused (zero)"),
    ("blockSize", "Number of 32-byte trailer data blocks that follow"),
    ("description", "Trailer description text"),
    ("blockType", "Block type (0x70)")]

  Seg2FileDocs = [
    ("blockId", "File descriptor block ID (0x3A55)"),
    ("revision", "SEG-2 revision number"),
    ("pointerBytes", "Size of the trace pointer subblock (bytes)"),
    ("traceCount", "Number of traces in the file"),
    ("stringTermLength", "Length of the string terminator (1 or 2)"),
    ("stringTerm", "String terminator characters"),
    ("lineTermLength", "Length of the line terminator (1 or 2)"),
    ("lineTerm", "Line terminator characters")]

  Seg2TraceDocs = [
    ("blockId", "Trace descriptor block ID (0x4422)"),
    ("blockSize", "Size of the trace descriptor block (bytes)"),
    ("dataSize", "Size of the data block (bytes)"),
    ("numSamples", "Number of samples in the trace"),
    ("formatCode", "Data sample format code")]

func wordsOf*(name: string): string =
  ## A camelCase field name in words: "receiverLineNumber" -> "Receiver line
  ## number", "SAMPLE_INTERVAL" -> "Sample interval", "" -> "".
  for i, c in name:
    if c == '_':
      if result.len > 0 and result[^1] != ' ': result.add ' '
    else:
      if i > 0 and result.len > 0 and result[^1] != ' ':
        let p = name[i - 1]
        if (p in {'a'..'z'} and c in {'A'..'Z'}) or
            (p in {'a'..'z', 'A'..'Z'} and c in {'0'..'9'}) or
            (p in {'0'..'9'} and c in {'a'..'z', 'A'..'Z'}):
          result.add ' '
      result.add c.toLowerAscii
  result = result.strip
  if result.len > 0: result[0] = result[0].toUpperAscii

func lookup(table: openArray[(string, string)]; field: string): string =
  # The description of `field` in `table`, or its words.
  for (name, text) in table:
    if name == field: return text
  wordsOf(field)

func fieldDescription*(kind: HeaderBlock; field: string): string =
  ## Plain words for field `field` of a header block of type `kind`, as the
  ## SEG-Y and SEG-D standards describe it; for a field the table does not
  ## know (a SEG-2 keyword string, a raw block's ""), `wordsOf(field)`.
  result = case kind
    of hbSegyBinary: lookup(SegyBinaryDocs, field)
    of hbSegyTrace: lookup(SegyTraceDocs, field)
    of hbSegyExt1: lookup(SegyExt1Docs, field)
    of hbSegdTrace: lookup(SegdTraceDocs, field)
    of hbSegdExt1: lookup(SegdExt1Docs, field)
    of hbSegdExt1Rev3: lookup(SegdExt1Rev3Docs, field)
    of hbSegdGh1: lookup(SegdGh1Docs, field)
    of hbSegdGhN: lookup(SegdGhNDocs, field)
    of hbSegdGh2: lookup(SegdGh2Docs, field)
    of hbSegdGh2Rev3: lookup(SegdGh2Rev3Docs, field)
    of hbSegdGh3Rev3: lookup(SegdGh3Rev3Docs, field)
    of hbSegdChannelSet: lookup(SegdChannelSetDocs, field)
    of hbSegdChannelSetRev3: lookup(SegdChannelSetRev3Docs, field)
    of hbSegdPosition: lookup(SegdPositionDocs, field)
    of hbSegdSourceDescription: lookup(SegdSourceDescriptionDocs, field)
    of hbSegdAdditionalSourceInfo: lookup(SegdAdditionalSourceInfoDocs, field)
    of hbSegdSensorInfo: lookup(SegdSensorInfoDocs, field)
    of hbSegdTimestamp: lookup(SegdTimestampDocs, field)
    of hbSegdSensorCalibration: lookup(SegdSensorCalibrationDocs, field)
    of hbSegdTimeDrift: lookup(SegdTimeDriftDocs, field)
    of hbSegdOrientation: lookup(SegdOrientationDocs, field)
    of hbSegdTrailerDescription: lookup(SegdTrailerDescriptionDocs, field)
    of hbSeg2File: lookup(Seg2FileDocs, field)
    of hbSeg2Trace: lookup(Seg2TraceDocs, field)
    of hbRaw: wordsOf(field)
