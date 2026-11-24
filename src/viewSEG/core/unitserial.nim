## The serial number of the unit that recorded a trace, read in the viewer from the header
## fields it already decodes (the Headers window's): the serial of the first SEG-D Rev 3
## Sensor Info block in the trace's header extensions, then the field a vendor map names
## `unitSerial` (docs/user/vendor-maps.md), in the trace's own vendor blocks, then in the
## vendor blocks of its record (or of the SEG-Y file). Nothing here decodes samples; a file
## with no vendor map loaded and no Sensor Info block costs one header listing per trace.

import std/[options, tables]
import parseSEG
import vendormaps

const SensorSerialField* = "sensorSerial"
  ## the name by which a vendor map marks the field that holds the unit serial

type SerialReader* = object
  ## Reads unit serials of the traces of one file; keeps what the file-level vendor blocks
  ## of each record gave.
  vendors: VendorRegistry
  perRecord: Table[int, Option[string]]

func initSerialReader*(vendors: VendorRegistry): SerialReader =
  ## A reader that consults `vendors` after the standard header.
  SerialReader(vendors: vendors)

func printable(text: string): Option[string] =
  ## `text` without the blanks and NULs at its ends; none when nothing is left or a byte is
  ## not printable ASCII (the bytes are not text).
  var first = 0
  var last = text.high
  while first <= last and text[first] in {' ', '\0'}: inc first
  while last >= first and text[last] in {' ', '\0'}: dec last
  if first > last: return
  for i in first .. last:
    if text[i] notin {' ' .. '~'}: return
  some(text[first .. last])

proc sensorInfoSerial(file: SeismicFile; trace: int): Option[string] =
  ## The serial of the first Sensor Info block of the trace's header extensions.
  for row in file.traceHeaders(trace):
    if row.kind == hbSegdSensorInfo and row.field == "serialNumber":
      return printable(if row.value.kind == fvText: row.value.text else: "")

proc vendorSerial(shown: VendorShown): Option[string] =
  for b in shown.blocks:
    for f in b.fields:
      if f.name == SensorSerialField: return printable(f.value)

proc unitSerialOf*(r: var SerialReader; file: SeismicFile; trace: int): Option[string] =
  ## The unit serial of trace `trace` of `file`, as text; none when no source has one (a
  ## blank value, an "absent" sentinel, or no such field). May raise `ValueError` for a
  ## trace out of range or a closed file, as `traceHeaders` does.
  if file.kind == skSegd:
    result = sensorInfoSerial(file, trace)
    if result.isSome: return
  if r.vendors.maps.len == 0: return
  result = vendorSerial(vendorTrace(file, trace, r.vendors))
  if result.isSome: return
  let rec = if file.kind == skSegd: int(file.index.entries[trace].record) else: -1
  if rec notin r.perRecord:
    r.perRecord[rec] = vendorSerial(vendorBlocks(file, rec, r.vendors))
  result = r.perRecord[rec]
