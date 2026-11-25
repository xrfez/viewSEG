## The sensor table and the amplitude readout in physical units (`core/sensors`), without a
## window:
##
## - the table as typed: 80 V/(m/s) converts 1000 counts of a 0.298 µV/count descale to
##   3.725e-6 m/s; V/(in/s) converts by 0.0254 and the same ground motion reads the same
##   whichever unit the sensitivity was typed in; µV/Pa and V/bar for a hydrophone; the
##   readout's unit follows the Units setting, never the unit the sensitivity was typed in;
## - never a guessed number: no descale in the file reads "volts unknown for this file", no
##   sensor for the component reads its own words, a velocity figure on a hydrophone says so;
## - the file's own descale: a SEG-D channel set's (a descale multiplier of 1 is 1 mV per
##   count), a SEG-Y trace's weighting factor, read by `fileScalesInto`;
## - the project document: a row typed in V/(in/s) comes back with its value and unit
##   unchanged, a document from before the change opens unchanged, a later version's
##   children are written back, a hostile row (NaN, 0, 1e300, a duplicate, an unknown unit)
##   is said and left out;
## - the command: kept in the project, or for this run when none is open, and said so.
##
## Seen to fail: with `calibrationOf` giving a rule no sensitivity, "80 V/(m/s) ..." read
## "no sensor"; with the unit stored as the SI figure, the V/(in/s) row came back as
## 80 V/(m/s); with `readSensor` not checking `sensorOk`, the 1e300 row was kept; with the
## readout's unit taken from the sensitivity's, 2.032 V/(in/s) with Units metric read in/s.

import std/[math, options, os, sequtils, strutils]
import parseSEG
import processSEG/filescales
import viewSEG/core/[components, nif, project, projectnif, sensors, state]
import utils/[fixtures, waiting]

proc keysOf(component: uint8; sensor = 2'u8): TraceKeys =
  result = initTraceKeys()
  result.status = tsLive
  result.component = component
  result.sensorType = sensor

proc fileScale(descale: float64): FileScale =
  result = initFileScale()
  result.descale = descale

proc read(table: SensorTable; component: uint8; scale: FileScale; counts: float64;
    want = aiPhysical; sensor = 2'u8): Scaled =
  let plan = initCalibrationPlan(table.calibrationOf(if want == aiVolts: ctVolts else: ctPhysical))
  scaleSample(plan, keysOf(component, sensor), scale, counts, want)

func near(a, b: float64; rel = 1e-9): bool =
  abs(a - b) <= rel * max(abs(a), abs(b))

proc said(st: AppState; words: string): bool =
  st.log.anyIt(words in it.text)

proc sensorCmd(component: int; value: float64; unit: string): Command =
  Command(kind: ckSensor, sensorComponent: component, sensorValue: value, sensorUnit: unit)

proc main*() =
  block asTyped:
    var t = SensorTable()
    doAssert t.put(SensorRow(component: 2, value: 80, unit: suVPerMPerS))
    let r = t.read(2, fileScale(0.298e-6), 1000)
    doAssert r.kind == skValue and r.unit == auVelocity, $r
    doAssert near(r.value, 1000 * 0.298e-6 / 80), $r.value
    doAssert near(r.value, 3.725e-6, 1e-3)
    let (num, unit) = r.scaledParts(imperial = false)
    doAssert near(num, 3.725, 1e-3) and unit == "µm/s", $(num, unit)
    # the same ground motion, the sensitivity typed in V/(in/s): 80 V/(m/s) is 2.032 V/(in/s)
    var u = SensorTable()
    doAssert u.put(SensorRow(component: 2, value: 2.032, unit: suVPerInPerS))
    let ri = u.read(2, fileScale(0.298e-6), 1000)
    doAssert near(ri.value, r.value, 1e-12), $(ri.value, r.value)
    doAssert u[0].value == 2.032 and u[0].unit == suVPerInPerS, "the figure is kept as typed"
    # the readout's unit follows the Units setting, not the unit typed in
    let (inch, inchUnit) = ri.scaledParts(imperial = true)
    doAssert inchUnit == "µin/s" and near(inch, 3.725 / 0.0254, 1e-3), $(inch, inchUnit)
    doAssert ri.scaledParts(imperial = false).unit == "µm/s"
    doAssert r.scaledParts(imperial = true).unit == "µin/s"
    # volts need no sensor
    let v = SensorTable().read(2, fileScale(0.298e-6), 1000, aiVolts)
    doAssert v.kind == skValue and v.unit == auVolt and near(v.value, 0.298e-3), $v
    doAssert v.scaledParts(false).unit == "µV"
    # counts are counts
    doAssert t.read(2, fileScale(0.298e-6), 1000, aiCounts).kind == skCounts

  block hydrophone:
    var t = SensorTable()
    doAssert t.put(SensorRow(component: 1, value: 200, unit: suMicroVPerPa))
    let r = t.read(1, fileScale(1e-6), 2000, sensor = 1)
    doAssert r.kind == skValue and r.unit == auPressure and near(r.value, 2000e-6 / 2e-4), $r
    var bar = SensorTable()
    doAssert bar.put(SensorRow(component: 1, value: 20, unit: suVPerBar))
    doAssert near(bar.read(1, fileScale(1e-6), 2000, sensor = 1).value, r.value, 1e-9)
    # a velocity figure on a hydrophone is not given as a number
    var wrong = SensorTable()
    doAssert wrong.put(SensorRow(component: 1, value: 80, unit: suVPerMPerS))
    doAssert wrong.read(1, fileScale(1e-6), 1000, sensor = 1).kind == skNotFitting

  block neverGuessed:
    var t = SensorTable()
    doAssert t.put(SensorRow(component: 2, value: 80, unit: suVPerMPerS))
    let noVolts = t.read(2, initFileScale(), 1000)
    doAssert noVolts.kind == skNoVolts and noVolts.problemText == "volts unknown for this file",
      $noVolts
    let noSensor = t.read(4, fileScale(1e-6), 1000)
    doAssert noSensor.kind == skNoSensor and noSensor.problemText ==
      "no sensor for component Y: Project > Project... > Sensors", noSensor.problemText
    doAssert SensorTable().read(2, fileScale(1e-6), 1000).kind == skNoSensor
    doAssert SensorTable().read(2, initFileScale(), 1000).kind == skNoVolts

  block tableRules:
    var t = SensorTable()
    doAssert t.put(SensorRow(component: 3, value: 28, unit: suVPerMPerS))
    doAssert t.put(SensorRow(component: 1, value: 20, unit: suVPerBar))
    doAssert t.put(SensorRow(component: 3, value: 29, unit: suVPerMPerS)) # replaces
    doAssert t.len == 2 and t[0].component == 1 and t[1].value == 29
    for bad in [SensorRow(component: 0, value: 1, unit: suVPerMPerS),
        SensorRow(component: 2, value: NaN, unit: suVPerMPerS),
        SensorRow(component: 2, value: Inf, unit: suVPerMPerS),
        SensorRow(component: 2, value: 0, unit: suVPerMPerS),
        SensorRow(component: 2, value: -3, unit: suVPerMPerS),
        SensorRow(component: 2, value: 1e300, unit: suVPerMPerS),
        SensorRow(component: 2, value: 1e-300, unit: suVPerMPerS),
        SensorRow(component: 2, value: -190, unit: suDbReVPerMicroPa)]:
      doAssert not t.put(bad), $bad
    doAssert t.len == 2
    doAssert t.remove(1) and not t.remove(1) and t.len == 1
    doAssert unitsFor(ComponentKind.ckVertical, true)[0] == suVPerInPerS and
      unitsFor(ComponentKind.ckVertical, false)[0] == suVPerMPerS
    doAssert unitsFor(ComponentKind.ckHydrophone, true) == @[suVPerBar, suVPerPa, suMicroVPerPa]
    doAssert suVPerG in unitsFor(ComponentKind.ckOther, false)

  block projectDocumentRoundTrip:
    var doc = ProjectDoc(name: "Sensors")
    doAssert doc.sensors.put(SensorRow(component: 2, value: 2.032, unit: suVPerInPerS))
    doAssert doc.sensors.put(SensorRow(component: 1, value: 200, unit: suMicroVPerPa))
    let text = projectDocument(doc)
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.sensors.len == 2 and back.sensors[1].component == 2 and
      back.sensors[1].value == 2.032 and back.sensors[1].unit == suVPerInPerS and
      back.sensors[0].unit == suMicroVPerPa, "a row is not what was typed"
    # a document from before the change opens unchanged, and writes no sensors
    let plain = projectDocument(ProjectDoc(name: "Plain"))
    doAssert "sensors" notin plain
    doAssert readProject(plain, "project.nif", problems).sensors.len == 0
    # children this version does not know are written back, in a row and in the list
    let later = text.replace("(unit vPerInPerS)", "(unit vPerInPerS) (shunt 1800)").replace(
      "(sensors", "(sensors (future 7)")
    let kept = readProject(later, "project.nif", problems)
    doAssert kept.sensorsLater.len == 1 and kept.sensors[1].later.len == 1
    let again = projectDocument(kept)
    doAssert "(future 7)" in again and "(shunt 1800)" in again, again

  block hostileRows:
    let head = "(project (version 1) (name \"x\") (sensors "
    let rows = [
      "(sensor (component 2) (value 80.0) (unit vPerMPerS))",
      "(sensor (component 2) (value 90.0) (unit vPerMPerS))",           # a duplicate
      "(sensor (component 3) (value nan) (unit vPerMPerS))",
      "(sensor (component 3) (value 0.0) (unit vPerMPerS))",
      "(sensor (component 3) (value -2.0) (unit vPerMPerS))",
      "(sensor (component 3) (value 1e300) (unit vPerMPerS))",
      "(sensor (component 3) (value 5.0) (unit furlongsPerFortnight))",
      "(sensor (component 3) (value 5.0) (unit dbReVPerMicroPa))",
      "(sensor (component 0) (value 5.0) (unit vPerG))",
      "(sensor (component 999) (value 5.0) (unit vPerG))",
      "(sensor (value 5.0) (unit vPerG))",
      "(sensor (component 4) (unit vPerG))",
      "(sensor (component 4) (value 5.0))",
      "(sensor (component 5) (value 5.0) (unit vPerG))"]
    var problems: seq[string]
    let d = readProject(head & rows.join(" ") & "))", "project.nif", problems)
    doAssert d.sensors.len == 2 and d.sensors[0].component == 2 and d.sensors[0].value == 80 and
      d.sensors[1].component == 5, $d.sensors.len
    doAssert problems.len >= rows.len - 2, "each hostile row is said: " & $problems.len
    # nodes that are not sensors, and a count past the cap
    var many = head
    for c in 1 .. 255: many.add "(sensor (component " & $c & ") (value 1.0) (unit vPerG))"
    many.add "))"
    problems = @[]
    let big = readProject(many, "project.nif", problems)
    doAssert big.sensors.len == MaxSensors and problems.len > 0

  block fileDescale:
    withFixtures fx:
      # SEG-D: a channel set's descale multiplier of 1 is 1 mV per count; the fixture's
      # vertical geophones are sensor type 2
      let path = fx.twoSetSegd()
      var f = openSeismic(path, keys = true)
      var scales = newSeq[FileScale](f.len)
      f.fileScalesInto(0 ..< f.len, scales)
      var seismic = -1
      for i in 0 ..< f.len:
        if f.index.keys[i].status == tsLive and seismic < 0: seismic = i
      doAssert seismic >= 0 and near(scales[seismic].descale, 1e-3), $scales[seismic]
      var t = SensorTable()
      doAssert t.put(SensorRow(component: 2, value: 80, unit: suVPerMPerS))
      let k = f.index.keys[seismic]
      let r = scaleSample(initCalibrationPlan(t.calibrationOf), k, scales[seismic], 1000,
        aiPhysical)
      doAssert componentOf(k) == 2 and r.kind == skValue and near(r.value, 1000 * 1e-3 / 80),
        $(componentOf(k), r)
      let v = scaleSample(initCalibrationPlan(t.calibrationOf(ctVolts)), k, scales[seismic],
        1000, aiVolts)
      doAssert v.kind == skValue and near(v.value, 1.0), $v
      f.close()
      # SEG-Y: the trace weighting factor is the descale (2^-N volts per count)
      let sgy = fx.dir / "weighted.sgy"
      var w = openSeismicWriter(sgy, SegyOutputOptions())
      var tk = initTraceKeys()
      tk.intervalUs = 2000
      tk.t0Ms = 0
      tk.status = tsLive
      w.writeTrace(tk, newSeq[float32](100), [headerOverride("trace.traceWeightingFactor", 10)])
      w.writeTrace(tk, newSeq[float32](100), [])
      doAssert w.close().len == 0
      var g = openSeismic(sgy, keys = true)
      var gs = newSeq[FileScale](g.len)
      g.fileScalesInto(0 ..< g.len, gs)
      doAssert near(gs[0].descale, pow(2.0, -10)), $gs[0]
      doAssert gs[1].descale.isNaN, "a trace whose headers say nothing has no descale"
      doAssert scaleSample(initCalibrationPlan(SensorTable().calibrationOf(ctVolts)),
        g.index.keys[1], gs[1], 5, aiVolts).kind == skNoVolts
      g.close()

  block commandWithNoProject:
    withFixtures fx:
      var st = initAppState()
      st.apply sensorCmd(2, 2.032, "V/(in/s)")
      doAssert st.project.doc.sensors.len == 1 and st.project.doc.sensors[0].value == 2.032 and
        st.project.doc.sensors[0].unit == suVPerInPerS
      doAssert st.said("for this run only (no project is open)") and st.said("as wired"),
        $st.log.mapIt(it.text)
      st.apply sensorCmd(2, 80, "V/(m/s)")
      doAssert st.project.doc.sensors.len == 1 and st.project.doc.sensors[0].unit == suVPerMPerS
      for bad in [sensorCmd(2, NaN, "V/(m/s)"), sensorCmd(2, 0, "V/(m/s)"),
          sensorCmd(2, 1e300, "V/(m/s)"), sensorCmd(2, 80, "furlongs"),
          sensorCmd(0, 80, "V/(m/s)"), sensorCmd(300, 80, "V/(m/s)")]:
        st.apply bad
      doAssert st.project.doc.sensors.len == 1 and st.project.doc.sensors[0].value == 80
      var forget = sensorCmd(2, 0, "")
      forget.sensorForget = true
      st.apply forget
      doAssert st.project.doc.sensors.len == 0 and st.said("is removed")
      st.apply forget
      doAssert st.said("no sensor of Z (vertical) is kept")
      st.shutdown()

  block commandInAProject:
    withFixtures fx:
      var st = initAppState()
      st.rememberFilesIn(fx.dir / "config")
      let field = fx.dir / "field"
      let job = fx.dir / "job"
      createDir(field)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0 and
        not st.project.readOnly), "the project was not made"
      let rev = st.project.revision
      st.apply sensorCmd(2, 2.032, "V/(in/s)")
      doAssert st.project.revision > rev and st.said("in the project")
      st.flushFiles()
      doAssert "vPerInPerS" in readFile(documentOf(job)), "the sensor was not saved"
      var other = initAppState()
      other.rememberFilesIn(fx.dir / "config")
      other.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert other.settle(other.inProject and other.project.readOnly)
      doAssert other.project.doc.sensors.len == 1 and
        other.project.doc.sensors[0].unit == suVPerInPerS
      let before = readFile(documentOf(job))
      other.apply sensorCmd(1, 20, "V/bar")
      doAssert other.said("for this run only (the project is read-only)"),
        $other.log.mapIt(it.text)
      other.flushFiles()
      doAssert readFile(documentOf(job)) == before, "a read-only project's file changed"
      other.shutdown()
      st.shutdown()

when isMainModule:
  main()
