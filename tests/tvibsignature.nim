## The vibrator signature plot's analysis (`core/vibanalysis`, the code the
## plot uses) on samples/vib/vib_signature.sgd: six sweeps of R, GF, M and B
## in one record, R GF M B sweep after sweep. The four adjacent traces of a
## sweep are put in the roles Ref, GF, M, B by their place in the window, as
## a user would choose them.
##
## - every sweep gives four roles, a table row per signal, no problem;
## - sweep 5 is worse than sweep 1 in mean phase and mean THD, and near what
##   the sample's table says (12 degrees, 25 %);
## - the phase and the THD grow from sweep 1 to sweep 5;
## - sweep 6's mean force is below the others' (its drop-out);
## - the force generated from M and B follows the recorded ground force.
##
## Seen to fail: with the file as it was before (four records of six sweeps, so
## traces s * 4 .. s * 4 + 3 are not one sweep's), the check "phases 0.0 and 12.1"
## failed; with every sweep read as sweep 5, the check "sweep 5 mean
## phase against sweep 1" failed (12.0 against 12.0); with the GF and B roles
## swapped, it failed too (12.0 against 10.0, the baseplate's, not the force's).

import std/[math, os, strutils]
import parseSEG
import viewSEG/core/[analysis, vibanalysis]

const root = currentSourcePath().parentDir.parentDir

type Sweep = object
  phase, thd, force, generated: float64 ## mean |phase| degrees, mean THD %, mean forces

proc sweepOf(f: var SeismicFile; s: int): Sweep =
  ## The vibrator signature of sweep `s` (0..5): the four adjacent traces
  ## `s * 4 .. s * 4 + 3`, in the order R, GF, M, B.
  var rows: seq[seq[float32]] = @[]
  var names: seq[string] = @[]
  for c in 0 ..< 4:
    let x = f.readTraces(s * 4 + c .. s * 4 + c)
    var r = newSeq[float32](x.shape[1])
    for j in 0 ..< r.len: r[j] = x[0, j]
    rows.add r
    names.add ["R", "GF", "M", "B"][c] & " " & $(s + 1)
  var p = AnalysisParams(reactionMassKg: 3600, baseplateMassKg: 1800)
  let a = vibratorOf(rows, names, [vsReference: 0, vsGroundForce: 1, vsMass: 2,
    vsBaseplate: 3], 4.0, p)
  doAssert a.problem.len == 0, "sweep " & $(s + 1) & ": " & a.problem
  doAssert a.used == 4, "roles found " & $a.used
  var seen: seq[string] = @[]
  for row in a.table[1 .. ^1]:
    seen.add row[0]
    if row[0] == "GF":
      result.phase = parseFloat(row[3])
      result.thd = parseFloat(row[5])
      result.force = parseFloat(row[7])
    elif row[0] == "GF (M, B)":
      result.generated = parseFloat(row[7])
  doAssert seen.len == 5, "signals " & $seen

proc main*() =
  let path = root / "samples" / "vib" / "vib_signature.sgd"
  doAssert fileExists(path), "missing " & path.relativePath(root)
  var f = openSeismic(path, keys = true)
  var all: seq[Sweep] = @[]
  for s in 0 ..< 6: all.add sweepOf(f, s)
  f.close()

  block four_roles_every_sweep:
    for s, w in all:
      doAssert w.force > 0, "sweep " & $(s + 1) & " force " & $w.force

  block sweep_five_is_worse_than_sweep_one:
    doAssert all[4].phase > all[0].phase + 5, "sweep 5 mean phase " & $all[4].phase &
      " against sweep 1 " & $all[0].phase
    doAssert all[4].thd > all[0].thd + 10, "sweep 5 mean THD " & $all[4].thd &
      " against sweep 1 " & $all[0].thd
    doAssert abs(all[0].phase - 2) < 2 and abs(all[4].phase - 12) < 3,
      "phases " & $all[0].phase & " and " & $all[4].phase

  block phase_and_distortion_grow:
    for s in 1 .. 4:
      doAssert all[s].phase > all[s - 1].phase, "phase of sweep " & $(s + 1)
      doAssert all[s].thd > all[s - 1].thd, "THD of sweep " & $(s + 1)

  block sweep_six_drops_out:
    doAssert all[5].force < 0.97 * all[4].force, "sweep 6 mean force " & $all[5].force &
      " against sweep 5 " & $all[4].force

  block generated_force_follows_the_recorded_one:
    for s, w in all:
      doAssert w.generated > 0
      # GF (M, B) is Mr * M + Mb * B: the recorded force, in kg x counts
      doAssert abs(w.generated - w.force) < 0.001 * w.force, "GF (M, B) mean " &
        $w.generated & " against GF " & $w.force & " in sweep " & $(s + 1)

when isMainModule:
  main()
