## The units a plot shows a physical value in: Metric (SI, the default) or
## Imperial. Stored values, project files, the command protocol and everything
## passed to processSEG stay in SI. This module is the only place a conversion
## factor is written.
##
## 1 lb = 0.45359237 kg, 1 ft = 0.3048 m, 1 lbf = 4.4482216152605 N. A
## pound-force per square inch is that force over the international inch
## (0.0254 m), so pascals become psi with no second factor of their own.

import std/[math, strutils]

type
  UnitSystem* = enum
    ## How a physical value is shown. `$` is the name `settings.nif` writes.
    usMetric = "metric"
    usImperial = "imperial"

const
  KgPerLb* = 0.45359237
    ## kilograms in one avoirdupois pound
  MPerFt* = 0.3048
    ## metres in one international foot
  NPerLbf* = 4.4482216152605
    ## newtons in one pound-force
  InchM = 0.0254
    ## metres in one international inch, the defined value
  PaPerPsi* = NPerLbf / (InchM * InchM)
    ## pascals in one pound-force per square inch
  UnitNames*: array[UnitSystem, string] = [$usMetric, $usImperial]
    ## the names `settings.nif` writes, one per system
  MassKgMax* = 1e9
    ## the largest mass stored, kilograms (the vibrator boxes' limit)

func systemName*(u: UnitSystem): string =
  ## What the Settings window calls `u`.
  if u == usMetric: "Metric" else: "Imperial"

func massName*(u: UnitSystem): string =
  ## The mass unit the user sees.
  if u == usMetric: "kg" else: "lb"

func velocityName*(u: UnitSystem): string =
  ## The velocity unit the user sees.
  if u == usMetric: "m/s" else: "ft/s"

func forceName*(u: UnitSystem): string =
  ## The force unit the user sees.
  if u == usMetric: "N" else: "lbf"

func accelName*(u: UnitSystem): string =
  ## The acceleration unit the user sees.
  if u == usMetric: "m/s²" else: "ft/s²"

func pressureName*(u: UnitSystem): string =
  ## The pressure unit the user sees.
  if u == usMetric: "Pa" else: "psi"

func showMass*(kg: float64; u: UnitSystem): float64 =
  ## `kg` as the user sees it in `u`. NaN stays NaN (a mass not entered).
  if u == usMetric or kg.isNaN: kg else: kg / KgPerLb

func massBoxValue*(kg: float64; u: UnitSystem): float64 =
  ## The number a mass box shows for `kg` in `u`: kilograms as they are, pounds to a tenth
  ## (3600 kg is 7936.6 lb), so a box never holds the noise of a conversion. Only a
  ## number typed into the box is stored (`storeMass`), never this one, so switching
  ## the unit back and forth does not move the stored kilograms.
  let shown = showMass(kg, u)
  if u == usMetric or shown.isNaN or abs(shown) == Inf: shown else: round(shown * 10) / 10

func storeMass*(shown: float64; u: UnitSystem): float64 =
  ## A mass typed in `u`, in kilograms. NaN stays NaN.
  if u == usMetric or shown.isNaN: shown else: shown * KgPerLb

func showVelocity*(mps: float64; u: UnitSystem): float64 =
  ## `mps` (metres per second) as the user sees it in `u`.
  if u == usMetric or mps.isNaN: mps else: mps / MPerFt

func storeVelocity*(shown: float64; u: UnitSystem): float64 =
  ## A velocity typed in `u`, in metres per second.
  if u == usMetric or shown.isNaN: shown else: shown * MPerFt

func showForce*(newtons: float64; u: UnitSystem): float64 =
  ## `newtons` as the user sees it in `u`.
  if u == usMetric or newtons.isNaN: newtons else: newtons / NPerLbf

func storeForce*(shown: float64; u: UnitSystem): float64 =
  ## A force typed in `u`, in newtons.
  if u == usMetric or shown.isNaN: shown else: shown * NPerLbf

func showAccel*(ms2: float64; u: UnitSystem): float64 =
  ## `ms2` (metres per second squared) as the user sees it in `u`.
  if u == usMetric or ms2.isNaN: ms2 else: ms2 / MPerFt

func showPressure*(pa: float64; u: UnitSystem): float64 =
  ## `pa` as the user sees it in `u`.
  if u == usMetric or pa.isNaN: pa else: pa / PaPerPsi

func sensible*(x: float64): string =
  ## `x` with enough digits to read a typed value back, and not the noise of
  ## a conversion (no "3968.320000001"). "" for NaN or an infinity.
  if x.isNaN or abs(x) == Inf: return ""
  if x == 0: return "0"
  let exp = int(floor(log10(abs(x))))
  let decimals = max(0, 8 - exp)
  let scale = pow(10.0, float64(decimals))
  let rounded = round(x * scale) / scale
  if decimals == 0: return $int64(rounded)
  var text = formatFloat(rounded, ffDecimal, decimals)
  while text.len > 1 and text[^1] == '0': text.setLen(text.len - 1)
  if text[^1] == '.': text.setLen(text.len - 1)
  if text == "-0" or text.len == 0: "0" else: text

func massCapShown(u: UnitSystem): float64 =
  ## The largest whole number of `u` that stores at most `MassKgMax` kg.
  ## Floor, not `sensible`'s round: rounding the imperial cap up stores a
  ## kilogram the vibrator boxes refuse.
  if u == usMetric: return MassKgMax
  result = floor(showMass(MassKgMax, u))
  while result > 0 and storeMass(result, u) > MassKgMax: result -= 1

func massLimitWords*(u: UnitSystem): string =
  ## The vibrator mass range, in the unit the user is typing.
  if u == usMetric: "above 0 and at most 1000000000 kg"
  else: "above 0 and at most " & sensible(massCapShown(usImperial)) & " lb"

func shownMassClause*(reactionKg, baseplateKg: float64; u: UnitSystem): string =
  ## "2450 kg·M + 1180 kg·B", in `u`.
  let n = massName(u)
  sensible(showMass(reactionKg, u)) & " " & n & "·M + " &
    sensible(showMass(baseplateKg, u)) & " " & n & "·B"

const
  MassHead = "; GF (M, B) = "
  MassTail = " kg·B"
  # The unit phrases vibratorOf writes, and only those: an archive name
  # prepended to the note can hold the same letters.
  NotePhrases = [
    ("in kg × m/s², on an axis of its own", "in lb × ft/s², on an axis of its own"),
    ("in kg × m/s, on an axis of its own", "in lb × ft/s, on an axis of its own"),
    ("in kg × as recorded, on an axis of its own", "in lb × as recorded, on an axis of its own"),
    ("in kg × Pa, on an axis of its own", "in lb × psi, on an axis of its own"),
    ("in kg × V, on an axis of its own", "in lb × V, on an axis of its own"),
    ("in N, on an axis of its own", "in lbf, on an axis of its own"),
    (" (the force limits are in m/s² and are not applied to it)",
      " (the force limits are in ft/s² and are not applied to it)"),
    (" (the force limits are in m/s and are not applied to it)",
      " (the force limits are in ft/s and are not applied to it)"),
    (" (the force limits are in Pa and are not applied to it)",
      " (the force limits are in psi and are not applied to it)"),
    (" (the force limits are in N and are not applied to it)",
      " (the force limits are in lbf and are not applied to it)"),
  ]

func shownNote*(note: string; reactionKg, baseplateKg: float64; u: UnitSystem): string =
  ## `note` as the user reads it. Metric is unchanged (what is stored, and
  ## what a command's answer carries). Imperial rewrites the generated mass
  ## clause (anchored on "; GF (M, B) = " … " kg·B") and the exact unit
  ## phrases that clause's generator emits. A name prepended to the note is
  ## left as it is. The numbers of a force in newtons are scaled where the
  ## axis is, not here.
  result = note
  if u == usMetric or note.len == 0: return
  let at = result.find(MassHead)
  if at >= 0:
    let tail = result.find(MassTail, at)
    if tail >= 0:
      result = result[0 ..< at] & MassHead &
        shownMassClause(reactionKg, baseplateKg, u) & result[tail + MassTail.len .. ^1]
  for (phrase, shown) in NotePhrases.items: result = result.replace(phrase, shown)

func axisDisplay*(label: string; u: UnitSystem): tuple[label: string; divisor: float64] =
  ## The axis label the user sees, and what a stored value on that axis is
  ## divided by. Metric: the label as stored, divisor 1 (nothing is scaled).
  if u == usMetric or label.len == 0: return (label, 1.0)
  if "kg × as recorded" in label:
    return (label.replace("kg × as recorded", "lb × as recorded"), KgPerLb)
  if "kg × m/s²" in label:
    return (label.replace("kg × m/s²", "lb × ft/s²"), KgPerLb * MPerFt)
  if "kg × m/s" in label:
    return (label.replace("kg × m/s", "lb × ft/s"), KgPerLb * MPerFt)
  if "kg × Pa" in label:
    return (label.replace("kg × Pa", "lb × psi"), KgPerLb * PaPerPsi)
  if "kg × N" in label:
    return (label.replace("kg × N", "lb × lbf"), KgPerLb * NPerLbf)
  if "(N)" in label: return (label.replace("(N)", "(lbf)"), NPerLbf)
  if "(m/s²)" in label: return (label.replace("(m/s²)", "(ft/s²)"), MPerFt)
  if "(m/s)" in label: return (label.replace("(m/s)", "(ft/s)"), MPerFt)
  if "(Pa)" in label: return (label.replace("(Pa)", "(psi)"), PaPerPsi)
  (label, 1.0)

func unitOfLabel*(label: string): string =
  ## The unit an axis label names, its last parenthetical; "" when it names none.
  let openAt = label.rfind('(')
  let closeAt = label.rfind(')')
  if openAt >= 0 and closeAt > openAt: label[openAt + 1 ..< closeAt] else: ""

func forceLimitOf*(axisLabel: string; u: UnitSystem): tuple[unit: string; divisor: float64] =
  ## What a force-limit box shows for a force axis labelled `axisLabel` (the
  ## stored label): the unit written beside the box, and what a stored value
  ## is divided by to show it. Uncalibrated ("as recorded") is counts and is
  ## not converted. An empty label has no unit yet (the answer has not arrived).
  if axisLabel.len == 0: return ("", 1.0)
  let axis = axisDisplay(axisLabel, u)
  let named = unitOfLabel(axis.label)
  if named == "as recorded": return ("counts", 1.0)
  (named, axis.divisor)

func scaleOf*(storedUnit: string; u: UnitSystem): tuple[unit: string; divisor: float64] =
  ## `storedUnit` (a table cell's stored unit) as the matching axis shows it,
  ## and what a stored number is divided by. "as recorded" is not converted.
  if storedUnit.len == 0: return ("", 1.0)
  let axis = axisDisplay("x (" & storedUnit & ")", u)
  let named = unitOfLabel(axis.label)
  if named.len == 0: (storedUnit, axis.divisor) else: (named, axis.divisor)

func scaledCell(text: string; divisor: float64): string =
  if text == "–" or text.len == 0 or divisor == 1.0: return text
  try: formatFloat(parseFloat(text) / divisor, ffDecimal, 3)
  except ValueError: text

const ForceHeads = ["Mean force", "Min force", "Max peak"]

func shownTable*(table: seq[seq[string]]; rowUnit: openArray[string];
    u: UnitSystem): seq[seq[string]] =
  ## The vibrator table as the window shows it. Mean force, Min force and Max
  ## peak are in each row's unit, the one its axis shows, and that unit is
  ## named in the column header when every row shares it. When they differ,
  ## each cell names its own, so a number is never beside a unit it is not in.
  ## The stored table is unchanged. A table with no row units is as it is.
  if table.len == 0: return
  result = table
  if rowUnit.len == 0: return
  var cols: seq[int] = @[]
  for i, name in table[0]:
    if name in ForceHeads: cols.add i
  if cols.len == 0: return
  var shared = ""
  var mixed = rowUnit.len < table.len - 1
  for r in 0 ..< min(rowUnit.len, table.len - 1):
    let unit = scaleOf(rowUnit[r], u).unit
    if unit.len == 0 or (shared.len > 0 and unit != shared): mixed = true
    elif shared.len == 0: shared = unit
  if not mixed and shared.len > 0:
    for c in cols: result[0][c] = table[0][c] & " (" & shared & ")"
  for r in 0 ..< min(rowUnit.len, table.len - 1):
    let scaled = scaleOf(rowUnit[r], u)
    for c in cols:
      if c >= result[r + 1].len: continue
      var cell = scaledCell(table[r + 1][c], scaled.divisor)
      if mixed and scaled.unit.len > 0 and cell != "–" and cell.len > 0:
        cell.add " " & scaled.unit
      result[r + 1][c] = cell

func showScaled*(stored, divisor: float64): float64 =
  ## `stored` as the box shows it. NaN stays NaN (a limit not entered).
  if stored.isNaN or divisor == 1.0: stored else: stored / divisor

func storeScaled*(shown, divisor: float64): float64 =
  ## A number typed in the box, back in the stored unit. NaN stays NaN.
  if shown.isNaN or divisor == 1.0: shown else: shown * divisor

func fkVelocityTip*(velocityUnit: string; setting: UnitSystem): string =
  ## What the f-k readout's tooltip says of its velocity. A file that names a
  ## length (m/s, ft/s) keeps that unit, whichever Units is. traces/s is a
  ## file that names no length: the setting does not apply, and there is no
  ## length to convert. `setting` is unused then; the two systems say the same.
  if velocityUnit == "m/s":
    "Apparent velocity follows the file's metres (m/s), not the Units setting."
  elif velocityUnit == "ft/s":
    "Apparent velocity follows the file's feet (ft/s), not the Units setting."
  elif velocityUnit == "traces/s":
    "The file names no length, so the velocity is in traces/s. The Units setting " &
      "does not apply: there is no length to convert."
  else: ""
