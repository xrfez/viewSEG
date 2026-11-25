## The sensors a project's traces were recorded with, typed by the user, and the
## amplitude readout in physical units built on them.
##
## A sensor's sensitivity comes from a data sheet, so it is typed in: one row per
## component (the value `componentOf` gives), holding only what the conversion uses:
## the sensitivity exactly as typed, and the unit it was typed in. The figure is never
## converted for storage or shown back in another unit: a V/(in/s) row stays V/(in/s)
## whatever the Units setting says; the SI value is only for the arithmetic. Natural
## frequency, damping and coil resistance are not kept: nothing here uses them.
##
## The figure is the sensitivity as wired. A data sheet's is usually the open-circuit
## one, and a damping shunt lowers it; the user types the figure for their shunt. Only
## the flat band is converted: below the sensor's natural frequency the true motion is
## larger than the converted value shows.
##
## The maths is processSEG's (`core/calibrate`): a row's factor is
## `descale / (10^(gain/20) · sensitivity)`. The descale comes from the file's own
## headers (`FileScale`), never from a guess: a trace whose file gives none reads
## "volts unknown for this file", one whose component has no row "no sensor for
## component Z", never a number. This module only decides what the readout says; it
## reads no file.

import std/[math, options]
import parseSEG
import processSEG/core/[calibrate, types]
import processSEG/core/units as physical
import components, nif

export CalibrationTarget, SensitivityUnit, AmplitudeUnit, FileScale, initFileScale, CalibrationPlan,
  initCalibrationPlan

type
  AmplitudeIn* = enum
    ## What the amplitude readout of the raw sample is given in.
    aiCounts = "counts"
    aiVolts = "volts"
    aiPhysical = "physical units"

  SensorRow* = object
    ## One component's sensor, as typed.
    component*: uint8
    value*: float64      ## the sensitivity, in `unit`
    unit*: SensitivityUnit
    later*: seq[NifNode] ## children of the row this version does not know, written back

  SensorTable* = object
    ## The sensors of a project, one per component, sorted by component.
    list: seq[SensorRow]

  ScaledKind* = enum
    ## What the readout of one sample says.
    skCounts     ## the sample as the file has it: nothing converts it
    skValue      ## a number in `unit`
    skNoVolts    ## the file gives no counts-to-volts factor for this trace
    skNoSensor   ## no sensor is entered for the trace's component
    skNotFitting ## the sensor's unit measures another quantity than the trace's sensor
    skKept       ## a dead or auxiliary trace the file gives no descale for: as recorded

  SensorSource* = enum
    ## Whose sensitivity a converted sample used.
    ssTyped ## the row typed in Project > Sensors (or none was needed: volts)
    ssFile  ## the file's own headers: nothing is typed for the component

  Scaled* = object
    ## One sample in the unit asked for, or why it cannot be given.
    kind*: ScaledKind
    value*: float64       ## in SI (V, m/s, m/s², Pa) when `skValue`
    unit*: AmplitudeUnit
    component*: uint8
    source*: SensorSource ## whose sensitivity was used
    conflict*: bool       ## the file also gave a figure, or says its samples are physical, and
                          ## a row is typed: the two differ

const
  MaxSensors* = 64        ## rows a table holds
  MinSensitivity* = 1e-12 ## the SI sensitivity a row may hold, V per unit
  MaxSensitivity* = 1e12
  OfferedUnits* = [suVPerMPerS, suVPerInPerS, suVPerMPerS2, suVPerG, suVPerBar, suVPerPa,
    suMicroVPerPa]
    ## The units a row may be typed in.
  UnitWords*: array[SensitivityUnit, string] = ["vPerMPerS", "vPerInPerS", "vPerMPerS2",
    "vPerG", "vPerBar", "vPerPa", "microVPerPa", "", "", "", ""]
    ## A unit's word in the project document (not `$unit`: renaming must not change a
    ## project); "" for a unit the table does not offer.
  Inch = 0.0254

func offered*(unit: SensitivityUnit): bool =
  ## Whether a row may be typed in `unit`.
  unit in OfferedUnits

func unitsFor*(kind: ComponentKind; imperial: bool): seq[SensitivityUnit] =
  ## The units offered for a component of `kind`, the one of the Units setting first:
  ## velocity for a geophone, acceleration, pressure for a hydrophone; all of them for
  ## another component.
  let velocity = if imperial: @[suVPerInPerS, suVPerMPerS] else: @[suVPerMPerS, suVPerInPerS]
  case kind
  of ckVertical, ckInline, ckCrossline: result = velocity
  of ckHydrophone: result = @[suVPerBar, suVPerPa, suMicroVPerPa]
  of ckOther:
    result = velocity & @[suVPerMPerS2, suVPerG, suVPerBar, suVPerPa, suMicroVPerPa]

func siSensitivity*(value: float64; unit: SensitivityUnit): Option[float64] =
  ## The sensitivity in SI, volts per m/s, m/s² or Pa, when `value` in `unit` is one a
  ## row may hold: a unit offered and a finite figure whose SI value is between
  ## `MinSensitivity` and `MaxSensitivity`.
  if not unit.offered: return none(float64)
  try:
    let si = sensitivity(value, unit).voltsPerUnit
    if si >= MinSensitivity and si <= MaxSensitivity: result = some(si)
  except ValueError:
    discard

func sensorOk*(row: SensorRow): bool =
  ## Whether `row` is one the table may hold.
  row.component > 0 and siSensitivity(row.value, row.unit).isSome

func len*(t: SensorTable): int {.inline.} = t.list.len

func `[]`*(t: SensorTable; i: int): lent SensorRow {.inline.} = t.list[i]

iterator items*(t: SensorTable): lent SensorRow =
  for i in 0 ..< t.list.len: yield t.list[i]

func find*(t: SensorTable; component: uint8): int =
  ## The index of the row of `component`; -1 for none.
  result = -1
  for i, r in t.list:
    if r.component == component: return i

func get*(t: SensorTable; component: uint8): Option[SensorRow] =
  let i = t.find(component)
  if i >= 0: result = some(t.list[i])

proc put*(t: var SensorTable; row: SensorRow): bool =
  ## Puts `row` in, in component order; a row of the same component is replaced. False,
  ## and nothing changes, for a row `sensorOk` refuses or a full table.
  if not row.sensorOk: return false
  let i = t.find(row.component)
  if i >= 0: t.list[i] = row
  elif t.list.len >= MaxSensors: return false
  else:
    var at = t.list.len
    for j, r in t.list:
      if r.component > row.component:
        at = j
        break
    t.list.insert(row, at)
  true

proc remove*(t: var SensorTable; component: uint8): bool =
  ## Takes out the row of `component`; false when there was none.
  let i = t.find(component)
  if i >= 0:
    t.list.delete i
    result = true

func componentName*(code: uint8): string =
  ## A component as the app names it: "Z (vertical)", "H (hydrophone)", "component 5".
  if kindOf(code) == ckOther: nameOf(code) else: letterOf(code) & " (" & nameOf(code) & ")"

func calibrationOf*(t: SensorTable; target = ctPhysical): Calibration =
  ## The rules of `t`: one per row, matched by component, giving the sensitivity as typed
  ## (as wired) and no descale: that comes from the file (`ffFallback`).
  result = initCalibration(target = target)
  for r in t:
    result.rules.add CalibrationRule(match: RuleMatch(component: int(r.component)),
      sensitivity: sensitivity(r.value, r.unit))

proc scaleSample*(plan: CalibrationPlan; keys: TraceKeys; scale: FileScale; counts: float64;
    want: AmplitudeIn): Scaled =
  ## `counts`, a sample as the file has it, of the trace with `keys` and file scale
  ## `scale`, in the unit `want` asks for; `plan` is built from `calibrationOf(table,
  ## target)` (`ctVolts` for `aiVolts`). Touches no file. A number is only given when the
  ## factor is known: else what is missing.
  var k = keys
  k.component = componentOf(keys) # the component as the app names it
  result = Scaled(kind: skCounts, value: counts, unit: auRecorded, component: k.component)
  if want == aiCounts or counts.isNaN: return
  var unit = [scale]
  var metaKeys = [k]
  let cols = [1]
  try:
    let meta = initChunkMeta(rowsOf(metaKeys, cols), dtMs = 1.0, scales = unit)
    var row: array[1, RowCalibration]
    discard plan.resolveInto(meta, row)
    case row[0].status
    of csConverted:
      if row[0].mismatch: result.kind = skNotFitting
      else: result = Scaled(kind: skValue, value: counts * row[0].factor, unit: row[0].unit,
        component: k.component,
        source: if row[0].sensitivityFrom == fsFile: ssFile else: ssTyped,
        conflict: row[0].conflict)
    of csUnresolved:
      result.kind = if row[0].descaleFrom == fsNone: skNoVolts else: skNoSensor
    of csKept: result.kind = skKept
  except ValueError:
    result.kind = skNoVolts

type Prefixed = tuple[value: float64; unit: string]

func prefixed(v: float64; base: string; steps: openArray[(float64, string)]): Prefixed =
  ## `v` scaled to the largest step of `steps` (descending) it reaches.
  result = (v, base)
  if v == 0 or v.isNaN: return
  for (size, unit) in steps:
    if abs(v) >= size:
      return (v / size, unit)
  let last = steps[steps.high]
  result = (v / last[0], last[1])

func scaledParts*(s: Scaled; imperial: bool): Prefixed =
  ## The number and the unit to print, with a readable prefix (V, mV, µV; m/s, mm/s, µm/s
  ## or in/s, µin/s when `imperial`; Pa, bar).
  case s.unit
  of auVolt: prefixed(s.value, "V", [(1.0, "V"), (1e-3, "mV"), (1e-6, "µV"), (1e-9, "nV")])
  of auVelocity:
    if imperial:
      # in/s down to 1e-3, then µin/s: no prefix reads as minutes
      let v = s.value / Inch
      if v == 0 or v.isNaN or abs(v) >= 1e-3: (v, "in/s")
      else: prefixed(v, "in/s", [(1e-6, "µin/s"), (1e-9, "nin/s")])
    else:
      prefixed(s.value, "m/s", [(1.0, "m/s"), (1e-3, "mm/s"), (1e-6, "µm/s"), (1e-9, "nm/s")])
  of auAcceleration:
    if imperial:
      prefixed(s.value / Inch, "in/s²", [(1.0, "in/s²"), (1e-6, "µin/s²")])
    else:
      prefixed(s.value, "m/s²", [(1.0, "m/s²"), (1e-3, "mm/s²"), (1e-6, "µm/s²")])
  of auPressure:
    prefixed(s.value, "Pa", [(1e5, "bar"), (1.0, "Pa"), (1e-3, "mPa"), (1e-6, "µPa"),
      (1e-9, "nPa")])
  of auForce: prefixed(s.value, "N", [(1.0, "N")])
  of auRecorded: (s.value, "")

func unknownVoltsText*(): string = "volts unknown for this file"

func noSensorText*(component: uint8): string =
  ## What the readout says for a component with no sensor row.
  "no sensor for component " & (if kindOf(component) == ckOther: $component
    else: letterOf(component)) & ": Project > Project... > Sensors"

func problemText*(s: Scaled): string =
  ## The words that stand for a number that cannot be given; "" for a number.
  case s.kind
  of skCounts, skValue, skKept: ""
  of skNoVolts: unknownVoltsText()
  of skNoSensor: noSensorText(s.component)
  of skNotFitting: "the sensor's unit does not fit this trace's sensor"

func problemTip*(s: Scaled; field: string): string =
  ## The tooltip of such a text; "" for a number.
  case s.kind
  of skCounts, skValue, skKept: ""
  of skNoVolts:
    "The file does not give this trace's counts-to-volts factor (" & field & "), and none " &
      "is guessed."
  of skNoSensor:
    "No sensor is entered for this component, so there is nothing to convert volts with."
  of skNotFitting:
    "The sensitivity entered for this component measures another quantity than the " &
      "trace's sensor type (a velocity figure on a hydrophone, say)."
