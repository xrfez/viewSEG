## The settings and `settings.nif`: every field survives a round trip; a
## document's missing settings keep the base's (the defaults, or the site's),
## unknown ones are skipped and unusable values keep theirs, each with a
## line in plain words; a damaged, truncated or hostile file gives the
## defaults, a backup with its bytes and a message, and a file with problems
## gives the rest, a copy and a message; a file written with Windows paths and
## line endings reads the same as one with Linux ones. `AppState` saves the
## settings a moment after they change and at shutdown, never at once, and
## never over a file it could neither read nor move aside; exports, imports
## and resets them, each reset keeping its own backup; remembers the recent
## files; and gives a new plot what the user last chose, also in the next run.
##
## Seen to fail: with the `(fills ...)` writer dropped, `everyField` found the
## fills at their default; with `loadSettings` reading a damaged file as
## defaults without moving it, `damaged` found no backup; with `persist`
## saving at once, `debounce` found the file before the delay; with `show`
## making a new layer with the built-in display, `newPlotsFollow` drew the
## second file as wiggles; with `settingsFile` not minding that the file
## could neither be read nor moved aside (the layouts set the folder again),
## `unreadableIsLeftAlone` found it written over; with a reset's backup
## named without the names asked for before, `twoResetsKeepBoth` found one
## backup, the second reset's; with `(readout ...)` taken whatever it held,
## `noUsableFieldKeepsTheReadout` found the status bar's fields gone; with
## the import parsed on the UI thread (`readSettings(m.content, ...)` in
## `takeIn`), `importHoldsNoFrame` found a frame held 51 ms.
##
## Runs alone: it bounds the time taking in an import holds a frame (25 ms).

import std/[math, monotimes, os, random, strutils, times]
import viewSEG/core/[geometry, state]
import utils/[fixtures, owntime, waiting]

let tmp = getTempDir() / ("viewseg_tsettings_" & $getCurrentProcessId())
removeDir(tmp)
createDir(tmp)

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

proc everyFieldSet(): Settings =
  ## Settings with every field away from its default.
  result = Settings(theme: "everforest-light",
    window: WindowPlacement(x: -1200, y: 35, width: 1700, height: 950, maximized: true),
    recentFiles: @[r"C:\Data\shot (1).sgd", "/data/two.segy", "/données/trois.sgd"],
    recentFolders: @[r"\\server\share\line 7", "/data"],
    scale: ScaleUnits(length: luCm, speed: true),
    calibrations: @[Calibration(monitor: "DELL U2720Q 3840x2160", ppi: 163.25),
      Calibration(monitor: "eDP-1 1920x1080", ppi: 141)],
    readout: @[rfAmplitude, rfTime, rfMidpointXY, rfStatus, rfRawAmplitude],
    sortPresets: @[SortPreset(name: "Mine", keys: @[SortKey(field: hfOffset, descending: true)]),
      SortPreset(name: "Channels", keys: @[SortKey(field: hfChannel)])],
    customOrder: @[SortKey(field: hfSrcPoint), SortKey(field: hfTrace, descending: true)],
    messages: MessagesView(autoScroll: false, hidden: {sevInfo, sevWarning}), cursorLine: true,
    files: FilesView(followLatest: true, prepareNext: false),
    map: MapOptions(info: miStrip, lengths: dlUsFeet, hiddenGroups: {mgRecorded},
      templateBox: true, spreadTemplate: TemplateSpec(shape: tsBox, lines: 12, channels: 240,
      inlineHalf: 2500.5, crosslineHalf: 750), folderShots: false,
      filters: {mfNoisy, mfClipped, mfMissing, mfSpreadDiffers}),
    join: JoinOptions(trailingDigits: true, multiComponent: true, coordinates: hcReplace,
      recordMatch: rmFieldRecord, traceMatch: tmChannel, lineNames: @[LineName(name: "CLT4960",
      line: 4960), LineName(name: "A line", line: 12.5)]),
    headers: HeadersView(tab: htTrace, traceTab: ttData, followPointer: false,
      asDisplayed: true, columns: {hcName, hcOffset}), hideKilled: true,
    spectrum: SpectrumOptions(window: SpectrumDisplay(scale: ssLinear, logFrequency: true,
      time: stVisible, raw: false, processed: false, phase: true), live: SpectrumDisplay(
      scale: ssLinear, logFrequency: true, time: stWhole, raw: false, processed: false,
      phase: true)),
    displayPresets: @[DisplayPreset(name: "Section", display: DisplaySettings(mode: dmDensity,
      colourMap: cmViridis, gain: dgFixed, fixedClip: 0.5, clipPercentile: 97)),
      DisplayPreset(name: "Wiggles", display: DisplaySettings(fills: {}, overlap: 3,
      fixedClip: 2))])
  result.plot = PlotDefaults(
    display: DisplaySettings(orientation: orTimeAcross, mode: dmWiggleDensity,
      fills: {wfNegative}, colours: pcCustom,
      custom: CustomColours(background: Rgba(r: 1, g: 2, b: 3, a: 255),
        line: Rgba(r: 250, g: 128, b: 0, a: 255), positive: Rgba(r: 9, g: 8, b: 7, a: 128),
        negative: Rgba(r: 200, a: 255), hover: Rgba(g: 200, a: 255),
        selected: Rgba(b: 200, a: 255)), colourMap: cmRedWhiteBlue,
      gain: dgExponential, gainDb: -7.5, agcWindowMs: 250, fixedClip: 0.125,
      normScope: perPanel, normStat: normRms, timeGain: tgPower, dbPerS: 12, power: 1.5,
      untilMs: 3500, clipPercentile: 98.5, overlap: 2.5),
    order: @[SortKey(field: hfComponent), SortKey(field: hfOffset, descending: true)],
    header: HeaderChoice(auto: false, fields: @[hfSrcLine, hfCrossline]))

proc roundTrip(s: Settings; base = Settings()): (Settings, seq[string]) =
  var problems: seq[string]
  result = (readSettings(settingsDocument(s), "settings.nif", base, problems), problems)

block savedByAnOlderBuild:
  # The settings a 0.1.0 build wrote read with no problem; what that build
  # did not have (the cursor time line) takes its default.
  const saved = currentSourcePath().parentDir / "data" / "saved-0.1.0" / "settings.nif"
  var problems: seq[string]
  let s = readSettings(readFile(saved), "settings.nif", Settings(), problems)
  doAssert problems.len == 0, $problems
  doAssert not s.cursorLine and s.recentFiles.len == 1 and s.plot.display.mode == dmWiggle
  doAssert not s.files.followLatest, "a new setting takes its default"
  doAssert s.files.prepareNext, "preparing the next file is on by default"
  doAssert s.map.info == miPopup and s.map.lengths == dlSurvey and s.map.hiddenGroups == {} and
    not s.map.templateBox and s.map.spreadTemplate == TemplateSpec() and s.map.folderShots and
    s.map.filters == {},
    "the map's settings take their defaults"
  doAssert s.join == JoinOptions(), "the join's options take their defaults"
  doAssert s.headers == HeadersView(), "the Headers window's settings take their defaults"
  doAssert s.headers.followPointer and s.headers.columns == {hcDescription, hcBytes}
  doAssert s.plot.display.untilMs == 2000, "the Exponential gain's cutoff takes its default"
  doAssert not s.hideKilled and s.spectrum == SpectrumOptions(),
    "the spectrum windows' settings take their defaults"
  doAssert s.plot.display.colourMap == cmGrey and s.displayPresets.len == 0,
    "density's colour map and the display presets take their defaults"
  doAssert cleaned(s)[1] == 0

block joinOptions:
  # The join's line names: those that cannot be used are said and passed by.
  var problems: seq[string]
  let s = readSettings("(settings (version 1) (join (trailingDigits true) (coordinates odd) " &
    "(lineNames (line \"L1\" 1) (line 2 3) (line \"\" 4))))", "settings.nif", Settings(),
    problems)
  doAssert s.join.trailingDigits and s.join.coordinates == hcFill
  doAssert s.join.lineNames == @[LineName(name: "L1", line: 1)], $s.join.lineNames
  doAssert problems.len == 3, $problems

block spreadTemplate:
  # The map's template: values out of range keep the base's, with a line
  # each; one given in code out of range is brought into it.
  var problems: seq[string]
  let s = readSettings("(settings (version 1) (map (templateBox true) (template (shape box) " &
    "(lines 0) (channels 50) (inline -1))))", "settings.nif", Settings(), problems)
  doAssert s.map.templateBox and s.map.spreadTemplate.shape == tsBox
  doAssert s.map.spreadTemplate.channels == 50 and s.map.spreadTemplate.lines == 8 and
    s.map.spreadTemplate.inlineHalf == 1500, $s.map.spreadTemplate
  doAssert problems.len == 2, $problems
  let c = cleaned(Settings(map: MapOptions(spreadTemplate: TemplateSpec(lines: -3,
    inlineHalf: NaN))))[0]
  doAssert c.map.spreadTemplate == TemplateSpec(lines: 1), $c.map.spreadTemplate

block gainAmountTo300:
  # The gain amount reads from -300 to +300 dB (60 before: a file of an
  # earlier build holds less and reads as it is); past that it keeps the
  # base's, with a line. Seen to fail with the reader's bound at 60:
  # "(gainDb) needs a number from -60.0 to 60.0, not the number 250.0".
  for (text, want) in [("250.0", 250.0), ("-300", -300.0), ("12.5", 12.5)]:
    var problems: seq[string]
    let s = readSettings("(settings (version 1) (plot (gainDb " & text & ")))", "settings.nif",
      Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert s.plot.display.gainDb == want, "(gainDb " & text & ") read as " &
      $s.plot.display.gainDb
  var problems: seq[string]
  let s = readSettings("(settings (version 1) (plot (gainDb 300.5)))", "settings.nif",
    Settings(), problems)
  doAssert s.plot.display.gainDb == 0 and problems.len == 1 and
    "(gainDb) needs a number from -300.0 to 300.0" in problems[0], $problems
  var top = Settings()
  top.plot.display.gainDb = 300
  doAssert roundTrip(top)[0].plot.display.gainDb == 300

block everyField:
  let s = everyFieldSet()
  # Every field is away from its default, so a field the writer forgets
  # reads back as the default and the comparison below fails.
  let d = Settings()
  for name, a, b in fieldPairs(s, d):
    doAssert a != b, "field " & name & " is at its default"
  for name, a, b in fieldPairs(s.plot.display, d.plot.display):
    when name != "visible": # not kept: `remembered`
      doAssert a != b, "display field " & name & " is at its default"
  for name, a, b in fieldPairs(s.window, d.window):
    doAssert a != b, "window field " & name & " is at its default"
  for name, a, b in fieldPairs(s.headers, d.headers):
    doAssert a != b, "headers field " & name & " is at its default"
  for name, a, b in fieldPairs(s.spectrum.window, d.spectrum.window):
    doAssert a != b, "spectrum window field " & name & " is at its default"
  for name, a, b in fieldPairs(s.spectrum.live, d.spectrum.live):
    doAssert a != b, "spectrum live field " & name & " is at its default"
  let (back, problems) = roundTrip(s)
  doAssert problems.len == 0, $problems
  doAssert back == s, $back
  doAssert settingsDocument(back) == settingsDocument(s)

block defaultsRoundTrip:
  let (back, problems) = roundTrip(Settings())
  doAssert problems.len == 0, $problems
  doAssert settingsDocument(back) == settingsDocument(Settings())
  doAssert back.sortPresets == @SortPresets and back.readout == @DefaultReadout
  doAssert back.plot.display.fixedClip.isNaN, "no Fixed amplitude yet stays none"
  doAssert back.window.width == 0

block names:
  for table in persistedNames():
    for i, n in table:
      doAssert isNifIdent(n), n
      doAssert n notin table[0 ..< i], "twice: " & n

block missingKeepTheBase:
  let base = everyFieldSet()
  var problems: seq[string]
  let s = readSettings("(settings (version 1) (theme \"x\"))", "settings.nif", base, problems)
  doAssert problems.len == 0, $problems
  doAssert s.theme == "x"
  var want = base
  want.theme = "x"
  doAssert s == want

block unknownAndUnusable:
  var problems: seq[string]
  let text = """(.nif27)
(settings
 (version 1)
 (colourScheme dark)
 (window (x 10) (y "far") (width 800) (height 600) (depth 3))
 (plot (mode sideways) (overlap 50) (gainDb 6.0) (fills positive up) (zoom 3))
 (readout time nonsense amplitude)
 (scale (length mile) (speed true))
 (calibrations (monitor "A" -5) (monitor "B" 120))
 (sortPresets (preset "" (key line)) (preset "Ok" (key offset) (key sideways)))
 (recentFiles "/a" 5 "/b" "/a"))
(extra)"""
  let s = readSettings(text, "settings.nif", Settings(), problems)
  let all = problems.join("\n")
  for part in ["line 4: (colourScheme) in (settings) is not a setting",
      "line 5: (y) needs a whole number", "line 5: (depth) in (window)",
      "line 6: (mode) needs one of density, wiggle, wiggleDensity",
      "(overlap) needs a number from 0.1 to 10", "(fills) needs one of positive, negative",
      "line 6: (zoom) in (plot)", "line 7: (readout) needs one of",
      "line 8: (length) needs one of inch, cm", "(monitor) needs pixels per inch",
      "line 10: (sortPresets) needs", "(key) needs one of rcvLine", "(recentFiles) needs strings",
      "line 12: (extra) in (the document)"]:
    doAssert part in all, part & " not in:\n" & all
  doAssert s.window == WindowPlacement(x: 10, y: 0, width: 800, height: 600)
  doAssert s.plot.display.mode == dmWiggle and s.plot.display.overlap == 1.0
  doAssert s.plot.display.gainDb == 6.0 and s.plot.display.fills == {wfPositive}
  doAssert s.readout == @[rfTime, rfAmplitude]
  doAssert s.scale == ScaleUnits(length: luInch, speed: true)
  doAssert s.calibrations == @[Calibration(monitor: "B", ppi: 120)]
  doAssert s.sortPresets == @[SortPreset(name: "Ok", keys: @[SortKey(field: hfOffset)])]
  doAssert s.recentFiles == @["/a", "/b"]

block noUsableFieldKeepsTheReadout:
  # A typing mistake in the only field named keeps the status bar's fields;
  # an empty list is a choice of no fields.
  var problems: seq[string]
  let base = Settings(readout: @[rfAmplitude, rfTime])
  let s = readSettings("(settings (version 1) (readout tme))", "settings.nif", base, problems)
  doAssert s.readout == base.readout, $s.readout
  doAssert problems.len == 1 and "(readout) needs one of" in problems[0], $problems
  problems.setLen 0
  doAssert readSettings("(settings (version 1) (readout))", "settings.nif", base,
    problems).readout.len == 0

block versions:
  var problems: seq[string]
  discard readSettings("(settings (theme \"a\"))", "settings.nif", Settings(), problems)
  doAssert problems.len == 1 and "gives no (version)" in problems[0], $problems
  problems.setLen 0
  let s = readSettings("(settings (version 7) (theme \"a\") (hologram on))", "settings.nif",
    Settings(), problems)
  doAssert s.theme == "a"
  doAssert problems.len == 2 and "written by a newer viewSEG (settings version 7" in
    problems[1], $problems
  for notSettings in ["", "(layout)", "(.nif27)", "5"]:
    try:
      discard readSettings(notSettings, "settings.nif", Settings(), problems)
      doAssert false, "read " & notSettings
    except NifError as e:
      doAssert "holds no (settings ...)" in e.msg, e.msg

block windowsAndLinux:
  # Written on Windows (CR LF, backslashes) or on Linux (LF), it reads the
  # same anywhere: the reader does not depend on the system.
  let s = everyFieldSet()
  let lf = settingsDocument(s)
  doAssert "\r" notin lf
  for text in [lf, lf.replace("\n", "\r\n"), lf.replace("\n", "\r\n").replace("\r\n", "\n")]:
    var problems: seq[string]
    let back = readSettings(text, "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert back == s
    doAssert back.recentFiles[0] == r"C:\Data\shot (1).sgd"
    doAssert back.recentFolders[0] == r"\\server\share\line 7"
  # A hand-written Windows file, with its own line breaks and an editor's BOM.
  let hand = "\xEF\xBB\xBF(.nif27)\r\n(settings\r\n (version 1)\r\n" &
    " (recentFiles \"C:\\5CData\\5Cx.sgy\" \"D:/y.segy\")\r\n)\r\n"
  var problems: seq[string]
  doAssert readSettings(hand, "settings.nif", Settings(), problems).recentFiles ==
    @[r"C:\Data\x.sgy", "D:/y.segy"]
  doAssert problems.len == 0

# ------------------------------------------------------------------ files --

proc backups(dir: string): seq[string] =
  for kind, f in walkDir(dir):
    if f.endsWith(BackupSuffix): result.add f

block noFile:
  let dir = tmp / "none"
  let got = loadSettings(dir / SettingsFileName)
  doAssert got.notes.len == 0 and got.saveable and not got.rewrite
  doAssert settingsDocument(got.settings) == settingsDocument(Settings())

block damaged:
  let good = settingsDocument(everyFieldSet())
  var rng = initRand(11)
  var cases = @[good[0 ..< good.len div 2], good[0 ..< 30], "\x00\x01\x02 not NIF at all",
    "(settings (theme \"x\\G1\"))", repeat("(a ", 1000) & repeat(")", 1000),
    "(settings (version 1) (window (x 1)", ""]
  var noise = newString(3000)
  for c in noise.mitems: c = char(rng.rand(255))
  cases.add noise
  for i, text in cases:
    let dir = tmp / ("damaged" & $i)
    createDir(dir)
    let file = dir / SettingsFileName
    writeFile(file, text)
    let got = loadSettings(file)
    doAssert settingsDocument(got.settings) == settingsDocument(Settings()), "case " & $i
    doAssert got.saveable and got.rewrite
    doAssert not fileExists(file), "the damaged file is moved aside"
    let b = backups(dir)
    doAssert b.len == 1 and readFile(b[0]) == text, "case " & $i & ": " & $b
    doAssert got.notes.len == 1 and got.notes[0].severity == sevWarning
    doAssert "could not be read" in got.notes[0].text and b[0] in got.notes[0].text,
      got.notes[0].text

block tooLarge:
  let dir = tmp / "large"
  createDir(dir)
  let file = dir / SettingsFileName
  writeFile(file, "(settings (theme \"" & repeat("x", MaxNifBytes) & "\"))")
  let got = loadSettings(file)
  doAssert "larger than 4 MB" in got.notes[0].text, got.notes[0].text
  doAssert backups(dir).len == 1

block someProblems:
  let dir = tmp / "some"
  createDir(dir)
  let file = dir / SettingsFileName
  let text = "(settings (version 1) (theme \"everforest-light\") (gadget 1))"
  writeFile(file, text)
  let got = loadSettings(file)
  doAssert got.settings.theme == "everforest-light"
  doAssert got.rewrite and fileExists(file)
  let b = backups(dir)
  doAssert b.len == 1 and readFile(b[0]) == text
  doAssert got.notes.len == 2 and b[0] in got.notes[0].text and "(gadget)" in got.notes[1].text

block backupsArePruned:
  let dir = tmp / "pruned"
  createDir(dir)
  let file = dir / SettingsFileName
  for i in 0 ..< KeptBackups + 3:
    writeFile(file & ".2020010" & $i & "-000000" & BackupSuffix, "old")
  writeFile(file, "(")
  discard loadSettings(file)
  let b = backups(dir)
  doAssert b.len == KeptBackups, $b
  var newest = false
  for f in b:
    if readFile(f) == "(": newest = true
  doAssert newest, "the new backup is kept"

block siteDefaults:
  let dir = tmp / "site"
  createDir(dir)
  let site = dir / "site.nif"
  writeFile(site, "(settings (version 1) (theme \"site-theme\") (readout time ffid))")
  let user = dir / SettingsFileName
  writeFile(user, "(settings (version 1) (readout amplitude))")
  let got = loadSettings(user, site)
  doAssert got.notes.len == 0, $got.notes
  doAssert got.settings.theme == "site-theme", "the site's value where the user's has none"
  doAssert got.settings.readout == @[rfAmplitude]
  doAssert got.defaults.theme == "site-theme" and got.defaults.readout == @[rfTime, rfRecord]
  writeFile(site, "(settings")
  let broken = loadSettings(user, site)
  doAssert broken.settings.theme == "" and broken.settings.readout == @[rfAmplitude]
  doAssert "site's default settings could not be read" in broken.notes[0].text
  doAssert fileExists(site), "a site file is never moved"

# --------------------------------------------------------------- AppState --

proc appIn(dir: string): AppState =
  result = initAppState()
  result.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))

block debounce:
  let dir = tmp / "app2"
  var st = appIn(dir)
  var s = st.settings
  s.theme = "a"
  st.apply Command(kind: ckSettings, settings: s)
  let at = getMonoTime()
  st.persist(at)
  st.persist(at + SaveDelay div 2)
  sleep 200 # time for a write handed over too early
  doAssert not fileExists(dir / SettingsFileName), "saved before the delay"
  st.persist(at + SaveDelay * 2)
  doAssert waitUntil(fileExists(dir / SettingsFileName))
  doAssert "(theme \"a\")" in readFile(dir / SettingsFileName)
  s.theme = "b"
  st.apply Command(kind: ckSettings, settings: s)
  st.shutdown() # saves what is left
  doAssert "(theme \"b\")" in readFile(dir / SettingsFileName)
  var problems: seq[string]
  doAssert readSettings(readFile(dir / SettingsFileName), "x", Settings(), problems).theme == "b"

block noChangeNoSave:
  let dir = tmp / "app3"
  var st = appIn(dir)
  st.apply Command(kind: ckSettings, settings: st.settings) # the same: no change
  st.shutdown()
  doAssert not fileExists(dir / SettingsFileName)

block rewrittenWhenItHadProblems:
  let dir = tmp / "app4"
  createDir(dir)
  writeFile(dir / SettingsFileName, "(settings (version 1) (theme \"t\") (gadget 1))")
  var st = appIn(dir)
  doAssert st.log.has("(gadget)", sevWarning)
  st.flushFiles()
  let text = readFile(dir / SettingsFileName)
  doAssert "gadget" notin text and "(theme \"t\")" in text
  st.shutdown()

block unreadableIsLeftAlone:
  # A settings file that could be neither read nor moved aside is never
  # written over, also once the layouts are kept in the same folder.
  let dir = tmp / "app7"
  createDir(dir)
  let file = dir / SettingsFileName
  writeFile(file, "the user's settings, which this run could not read")
  var st = initAppState()
  st.keepSettingsIn(dir, LoadedSettings(saveable: false,
    notes: @[(sevWarning, "could not be read nor moved aside")]))
  st.keepLayoutsIn(dir, [])
  var s = st.settings
  s.theme = "changed"
  st.apply Command(kind: ckSettings, settings: s)
  st.apply Command(kind: ckResetSettings)
  st.apply Command(kind: ckLayout, arrangement: "[Window][x]\n")
  st.flushFiles()
  doAssert readFile(file) == "the user's settings, which this run could not read"
  doAssert backups(dir).len == 0
  doAssert fileExists(dir / LayoutFileName), "the layout is still kept"
  st.shutdown()
  doAssert readFile(file) == "the user's settings, which this run could not read"
  doAssert st.settingsFile == ""

block twoResetsKeepBoth:
  # Two resets before the disk thread wrote the first one's backup: each
  # keeps its own, so the settings before the first are not lost.
  let dir = tmp / "app8"
  var st = appIn(dir)
  var s = everyFieldSet()
  st.apply Command(kind: ckSettings, settings: s)
  st.apply Command(kind: ckResetSettings)
  var t = st.settings
  t.theme = "between the resets"
  st.apply Command(kind: ckSettings, settings: t)
  st.apply Command(kind: ckResetSettings)
  st.flushFiles()
  var kept: seq[string]
  for b in backups(dir): kept.add readFile(b)
  doAssert kept.len == 2, $kept.len & " backups"
  doAssert settingsDocument(s) in kept, "the settings before the first reset are lost"
  st.shutdown()

block exportImportReset:
  let dir = tmp / "app5"
  var st = appIn(dir)
  var s = everyFieldSet()
  st.apply Command(kind: ckSettings, settings: s)
  let exported = tmp / "exported" / "mine.nif"
  st.apply Command(kind: ckExportSettings, docPath: exported)
  st.flushFiles()
  doAssert st.settle(st.log.has("Settings exported to " & exported & "."))
  st.apply Command(kind: ckResetSettings)
  doAssert st.settings.theme == "" and st.settings.readout == @DefaultReadout
  doAssert st.settings.recentFiles == s.recentFiles and st.settings.window == s.window,
    "a reset keeps the recent files and the window's place"
  doAssert st.log.has("Settings reset to their defaults")
  st.flushFiles()
  doAssert backups(dir).len == 1 and readFile(backups(dir)[0]) == settingsDocument(s)
  st.apply Command(kind: ckImportSettings, docPath: exported)
  doAssert st.settle(st.log.has("Settings imported from " & exported & "."))
  doAssert st.settings == s
  writeFile(tmp / "broken.nif", "(settings (theme")
  st.apply Command(kind: ckImportSettings, docPath: tmp / "broken.nif")
  doAssert st.settle(st.log.has("Cannot import the settings", sevError))
  doAssert st.settings == s, "a broken import changes nothing"
  st.apply Command(kind: ckImportSettings, docPath: tmp / "missing.nif")
  doAssert st.settle(st.log.has("Cannot import the settings in " & tmp / "missing.nif",
    sevError))
  st.shutdown()

block importHoldsNoFrame:
  # The disk thread reads an import and makes its NIF tree, so the frame that
  # takes in a document at the reader's bound (4 MB) only reads the tree;
  # and of a document of tens of thousands of unknown settings only the
  # first problems are worded.
  let dir = tmp / "app5b"
  var st = appIn(dir)
  var text = "(.nif27)\n(settings (version 1) (theme \"everforest-dark\")\n"
  while text.len < MaxNifBytes - 70_000:
    text.add " (recentFiles \"" & "x".repeat(60_000) & "\")\n"
  text.add ")\n"
  writeFile(tmp / "large.nif", text)
  st.apply Command(kind: ckImportSettings, docPath: tmp / "large.nif")
  var longest = Duration()
  doAssert waitUntil((
    let t0 = ownTime()
    discard st.drainInbox()
    longest = max(longest, ownTime() - t0)
    st.log.has("Settings imported from " & tmp / "large.nif")))
  doAssert longest < initDuration(milliseconds = 25), "taking in the import held a frame " &
    $longest.inMilliseconds & " ms"
  doAssert st.settings.theme == "everforest-dark"
  var many = "(.nif27)\n(settings (version 1)\n"
  for i in 0 ..< 40_000: many.add "(gadget)\n"
  many.add "(cursorLine true))\n"
  var problems: seq[string]
  let s = readSettings(many, "many.nif", Settings(), problems)
  doAssert s.cursorLine and problems.len == 40_000
  for i, p in problems:
    doAssert (p.len > 0) == (i < WordedProblems), $i & ": " & p
  st.shutdown()

block newPlotsFollow:
  withFixtures(fx):
    let a = fx.surveySegy()
    let b = fx.longSpreadSegy()
    let dir = tmp / "app6"
    block firstRun:
      var st = appIn(dir)
      st.apply Command(kind: ckOpen, paths: @[a])
      doAssert st.settle(st.sessions.len == 1)
      doAssert st.settings.recentFiles == @[a] and st.settings.recentFolders == @[fx.dir]
      var d = st.panel(MainPanel).layers[0].display
      doAssert d.mode == dmWiggle
      d.mode = dmDensity
      d.gain = dgNone
      d.gainDb = 6
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
      doAssert st.panel(MainPanel).layers[0].reversed
      let order = @[SortKey(field: hfOffset, descending: true)]
      st.apply Command(kind: ckSort, panel: MainPanel, order: order)
      st.apply Command(kind: ckHeader, panel: MainPanel,
        header: HeaderChoice(auto: false, fields: @[hfChannel]))
      doAssert st.settings.customOrder == order, "the user's own keys are kept"
      st.apply Command(kind: ckClose, file: st.sessions[0].id)
      doAssert st.settle(st.log.has("Closed "))
      st.apply Command(kind: ckOpen, paths: @[b])
      doAssert st.settle(st.sessions.len == 1)
      let p = st.panel(MainPanel)
      doAssert p.layers[0].display.mode == dmDensity and p.layers[0].display.gainDb == 6
      doAssert not p.layers[0].reversed, "polarity is not kept for a new plot"
      doAssert "revers" notin settingsDocument(st.settings), "polarity is not a setting"
      doAssert p.layers[0].order == order and p.header.fields == @[hfChannel]
      doAssert st.settings.recentFiles == @[b, a]
      st.shutdown()
    block secondRun:
      var st = appIn(dir)
      doAssert st.settings.recentFiles == @[b, a]
      st.apply Command(kind: ckOpen, paths: @[a])
      doAssert st.settle(st.sessions.len == 1)
      let p = st.panel(MainPanel)
      doAssert p.layers[0].display.mode == dmDensity and p.layers[0].display.gain == dgNone
      doAssert p.layers[0].order == @[SortKey(field: hfOffset, descending: true)]
      doAssert st.settings.recentFiles == @[a, b]
      st.shutdown()

removeDir(tmp)
