## Named display presets (`core/displaypresets`, the `display preset`
## command):
##
## - saved under a name (a name given again, in any case, replaces that
##   preset in its place), renamed (never onto another's name), deleted;
##   names without spaces round them, not empty, at most 64 characters; at most
##   32 kept;
## - applied to a plot: everything a preset holds is drawn (mode, fills,
##   colours, colour map, gain and its settings, amount, clip), the plot's
##   orientation kept; the preset shown is found again (`shownPreset`),
##   a number that is not a number equal to itself;
## - kept in `settings.nif` (a round trip; damaged entries dropped with a
##   problem, the rest kept) and by `AppState`: a window's preset is saved
##   and read at the next start; what could not be done is said in the log.
##
## Names are compared without case in Unicode ("ä" is "Ä"), counted in
## characters (40 Cyrillic letters are a name), and presets past the 32nd in
## the settings file are said when it is read.
##
## Seen to fail: with `find` comparing in ASCII (`cmpIgnoreCase`), "ä and Ä
## are two presets: 2"; with `nameProblem` counting bytes, "a 40-letter
## Cyrillic name: a display preset's name is at most 64 characters long";
## with the presets past the 32nd dropped silently, "@[]" (no problem).
## With `withPreset` taking the preset's orientation, "the plot
## was turned"; with `find` comparing case, "Mine and mine are two presets";
## with the presets left out of `settingsDocument`, "the presets did not
## come back".

import std/[math, os, strutils]
import viewSEG/core/[displaypresets, settingsnif, state]
import utils/[fixtures, waiting]

const Look = DisplaySettings(mode: dmDensity, colourMap: cmViridis, gain: dgNone,
  gainDb: 6, clipPercentile: 97.5, colours: pcTheme, overlap: 2, fills: {wfNegative})

block pureLists:
  var why = ""
  var l = saved(newSeq[DisplayPreset](), "  Mine ", Look, why)
  doAssert why == "" and l.len == 1 and l[0].name == "Mine"
  doAssert l[0].display.orientation == orTimeDown and l[0].display.colourMap == cmViridis
  var other = Look
  other.mode = dmWiggle
  l = saved(l, "mine", other, why) # the same name, in another case: replaced
  doAssert why == "" and l.len == 1, "Mine and mine are two presets"
  doAssert l[0].name == "Mine" and l[0].display.mode == dmWiggle
  l = saved(l, "Second", Look, why)
  doAssert l.len == 2 and l.find("SECOND") == 1 and l.find("third") < 0
  for bad in ["", "   ", repeat('x', MaxPresetName + 1), "tab\there"]:
    doAssert samePresets(saved(l, bad, Look, why), l) and why.len > 0, bad
  doAssert samePresets(renamed(l, "second", "Mine", why), l) and "already" in why
  doAssert samePresets(renamed(l, "nothing", "New", why), l) and "no display preset" in why
  l = renamed(l, "second", " Density ", why)
  doAssert why == "" and l[1].name == "Density"
  l = renamed(l, "density", "DENSITY", why) # its own name in another case
  doAssert why == "" and l[1].name == "DENSITY"
  doAssert samePresets(deleted(l, "nothing", why), l) and why.len > 0
  l = deleted(l, "mine", why)
  doAssert why == "" and l.len == 1 and l[0].name == "DENSITY"
  var full: seq[DisplayPreset]
  for i in 0 ..< MaxDisplayPresets: full = saved(full, "p" & $i, Look, why)
  doAssert full.len == MaxDisplayPresets
  doAssert saved(full, "one more", Look, why).len == MaxDisplayPresets and why.len > 0
  doAssert saved(full, "p3", other, why)[3].display.mode == dmWiggle and why == ""
  # cleaned: unusable names and doubles dropped, the first kept
  let c = cleaned(@[DisplayPreset(name: "a", display: Look), DisplayPreset(name: ""),
    DisplayPreset(name: "A", display: other), DisplayPreset(name: " b ", display: other)])
  doAssert c.len == 2 and c[0].display.mode == dmDensity and c[1].name == "b"

block unicodeNames:
  # case compared in Unicode; the limit counted in characters, as said
  var why = ""
  var l = saved(newSeq[DisplayPreset](), "ä", Look, why)
  l = saved(l, "Ä", Look, why)
  doAssert why == "" and l.len == 1, "ä and Ä are two presets: " & $l.len
  doAssert l.find("Ä") == 0 and l.find("ÄÖ") < 0
  let cyrillic = repeat("ж", 40) # 80 bytes
  l = saved(l, cyrillic, Look, why)
  doAssert why == "" and l.len == 2, "a 40-letter Cyrillic name: " & why
  doAssert saved(l, repeat("ж", MaxPresetName + 1), Look, why).len == 2 and
    "characters" in why, why
  doAssert saved(l, "bad \xff byte", Look, why).len == 2 and why.len > 0

block fixedFromTheRecord:
  # a preset of gain Fixed with no amplitude stays the one shown once the
  # amplitude is taken from the record (seen to fail with the amplitude
  # compared: "-1")
  var fixed = Look
  fixed.gain = dgFixed
  let l = @[DisplayPreset(name: "a", display: asPreset(DisplaySettings())),
    DisplayPreset(name: "fixed", display: asPreset(fixed))]
  var d = withPreset(DisplaySettings(), fixed)
  doAssert d.fixedClip.isNaN and l.shownPreset(d) == 1
  d.fixedClip = 0.31 # taken from the record shown
  doAssert l.shownPreset(d) == 1, $l.shownPreset(d)
  fixed.fixedClip = 0.25 # a preset with its own amplitude is that amplitude
  doAssert @[DisplayPreset(name: "f", display: asPreset(fixed))].shownPreset(d) == -1

block tooManyInTheFile:
  # presets past the 32nd are said when the settings are read, not dropped
  # without a word
  var s = Settings()
  for i in 0 .. MaxDisplayPresets:
    s.displayPresets.add DisplayPreset(name: "p" & $i, display: asPreset(Look))
  var problems: seq[string]
  let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
  doAssert back.displayPresets.len == MaxDisplayPresets
  doAssert problems.len == 1 and "at most 32 display presets" in problems[0], $problems

block appliedKeepsTheTurn:
  var shown = DisplaySettings(orientation: orTimeAcross, mode: dmWiggle)
  let d = withPreset(shown, Look)
  doAssert d.orientation == orTimeAcross, "the plot was turned"
  doAssert d.mode == dmDensity and d.colourMap == cmViridis and d.gainDb == 6 and
    d.clipPercentile == 97.5 and d.colours == pcTheme and d.fills == {wfNegative}
  let l = @[DisplayPreset(name: "a", display: asPreset(DisplaySettings())),
    DisplayPreset(name: "b", display: asPreset(Look))]
  doAssert l.shownPreset(d) == 1 and l.shownPreset(shown) == 0
  shown.gainDb = 1
  doAssert l.shownPreset(shown) == -1
  doAssert DisplaySettings().fixedClip.isNaN and sameLook(DisplaySettings(), DisplaySettings())
  doAssert samePresets(l, l) and not samePresets(l, l[0 .. 0])

block inTheSettingsFile:
  var s = Settings()
  var fixed = Look
  fixed.gain = dgFixed
  fixed.fixedClip = 0.25
  s.displayPresets = @[DisplayPreset(name: "Section", display: asPreset(Look)),
    DisplayPreset(name: "Fixed \"quoted\"", display: asPreset(fixed))]
  var problems: seq[string]
  let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
  doAssert problems.len == 0, $problems
  doAssert samePresets(back.displayPresets, s.displayPresets), "the presets did not come back: " &
    $back.displayPresets
  doAssert "(displayPresets" in settingsDocument(s)
  # a damaged entry is dropped and said; the others are kept
  let text = settingsDocument(s).replace("(preset \"Section\"", "(preset 12")
  problems.setLen 0
  let partly = readSettings(text, "settings.nif", Settings(), problems)
  doAssert partly.displayPresets.len == 1 and partly.displayPresets[0].name == "Fixed \"quoted\""
  doAssert problems.len == 1 and "displayPresets" in problems[0], $problems

withFixtures fx:
  let dir = fx.dir / "config"
  block throughTheCommand:
    var st = initAppState()
    st.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.panel(MainPanel).layout.traces > 0)
    var d = st.panel(MainPanel).layers[0].display
    d.orientation = orTimeAcross
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    let turned = st.panel(MainPanel).layers[0].display
    # save what is shown, change it, apply the preset: back as it was
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paSave,
      presetName: "Turned")
    doAssert st.settings.displayPresets.len == 1 and st.keptSettings.displayPresets.len == 1
    d = withPreset(turned, Look)
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    doAssert st.panel(MainPanel).layers[0].display.colourMap == cmViridis
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paSave,
      presetName: "Viridis")
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paApply,
      presetName: "turned")
    doAssert sameLook(st.panel(MainPanel).layers[0].display, turned)
    doAssert st.panel(MainPanel).layers[0].display.orientation == orTimeAcross
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paApply,
      presetName: "Viridis")
    doAssert st.panel(MainPanel).layers[0].display.mode == dmDensity
    doAssert st.panel(MainPanel).layers[0].display.colourMap == cmViridis
    doAssert st.panel(MainPanel).layers[0].display.orientation == orTimeAcross
    # what cannot be done is said, and changes nothing
    let before = st.settings.displayPresets
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paApply,
      presetName: "nothing")
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paRename,
      presetName: "Viridis", presetNewName: "turned")
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paSave,
      presetName: " ")
    doAssert samePresets(st.settings.displayPresets, before)
    var said = 0
    for e in st.log:
      if e.severity == sevWarning and "display preset" in e.text: inc said
    doAssert said == 3, "said " & $said & " of 3"
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paRename,
      presetName: "viridis", presetNewName: "Section")
    st.apply Command(kind: ckDisplayPreset, panel: MainPanel, presetAction: paDelete,
      presetName: "Turned")
    doAssert st.settings.displayPresets.len == 1 and st.settings.displayPresets[0].name == "Section"
    st.shutdown()
  block keptForTheNextRun:
    var st = initAppState()
    st.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))
    doAssert st.settings.displayPresets.len == 1 and
      st.settings.displayPresets[0].display.colourMap == cmViridis,
      "the presets did not come back: " & $st.settings.displayPresets
    st.shutdown()

echo "tdisplaypresets: ok"
