## The serial number of the unit that recorded a trace, read in the viewer from the header
## fields it already decodes (the Headers window's): the serial of the first SEG-D Rev 3
## Sensor Info block in the trace's header extensions, then the field a vendor map names
## `sensorSerial` (vendormaps/README.md), in the trace's own vendor blocks; nothing else.
## Nothing here decodes samples; a file with no vendor map loaded and no Sensor Info block
## costs one header listing per trace.

import std/options
import parseSEG
import vendormaps

const SensorSerialField* = "sensorSerial"
  ## the name by which a vendor map marks the field that holds the unit serial

func printable*(text: string): Option[string] =
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

proc unitSerialOf*(file: SeismicFile; trace: int; vendors: VendorRegistry): Option[string] =
  ## The serial of the unit that recorded trace `trace` of `file`, as text; none when no
  ## source has one (a blank value, an "absent" sentinel, or no such field). Raises
  ## `ValueError` on the SEG-D path for a trace out of range (or a closed file), as
  ## `traceHeaders` does; an error from reading a truncated file can pass through.
  result = none(string)
  if file.kind == skSegd:
    result = sensorInfoSerial(file, trace)
  if result.isNone and vendors.maps.len > 0:
    result = vendorSerial(vendorTrace(file, trace, vendors))
