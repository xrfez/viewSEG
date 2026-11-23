## The Seismic strip's groups, the sort drop-down's label and rows, and the
## gain box's text, apart from drawing them (`view/strip`).
##
## - groups, left to right: record, zoom, display, gain, filters, sort, and
##   the Seismic / Aux toggles only when the record has auxiliary traces or
##   one of them is off; the component toggles are not drawn;
## - the fill toggles are drawn in the wiggle modes, not in density;
## - the sort label is "Sort: " and a preset's name, "file order", or
##   "custom"; a preset the file has none of the keys of is greyed, unless
##   it is the order in use; clicking the preset already in use does nothing;
## - the gain box shows "+0.0 dB", and a bare number still parses.
##
## Seen to fail: with `stripGroups` putting the sort before the gain, the
## order assert found sort at 3; with `presetUsable` ignoring `inUse`, the
## preset in use was greyed; with `sortPick` sending a preset's keys when
## it was already in use, the pick acted; with `gainDbText` omitting the
## sign, "+0.0 dB" was "0.0 dB"; with `parseGainDb` refusing a "dB" suffix,
## "+0.0 dB" did not parse.

import std/[math, strutils]
import viewSEG/core/panels
import viewSEG/view/strip

proc main*() =

  block groups:
    let plain = stripGroups(false)
    doAssert plain == @[sgRecord, sgZoom, sgDisplay, sgGain, sgFilters, sgSort], $plain
    doAssert sgComponents notin plain and sgTraces notin plain
    let withTraces = stripGroups(true)
    doAssert withTraces[^1] == sgTraces and withTraces[0 .. ^2] == plain, $withTraces
    doAssert sgComponents notin withTraces
    # a group added after the trace toggles does not move the ones before it
    doAssert withTraces[0 ..< sgTraces.ord] == plain
    let withComponents = stripGroups(true, true)
    doAssert withComponents[^1] == sgComponents and withComponents[0 .. ^2] == withTraces,
      $withComponents
    doAssert showComponentToggles(2) and showComponentToggles(4)
    doAssert not showComponentToggles(0) and not showComponentToggles(1)

  block auxGroups:
    # the Aux window's strip: zoom, display (the fills) and gain only, whatever the record has
    let aux = stripGroups(true, true, capsOf(prAux))
    doAssert aux == @[sgZoom, sgDisplay, sgGain], $aux
    doAssert stripGroups(false, false, capsOf(prAux)) == aux
    doAssert stripGroups(true, true, capsOf(prSeismic)) == stripGroups(true, true)

  block whichGroups:
    doAssert showTraceToggles(true, true, false)
    doAssert showTraceToggles(false, false, false) # seismic off, so the toggle stays
    doAssert showTraceToggles(false, true, true) # aux on
    doAssert not showTraceToggles(false, true, false)
    doAssert not showFills(dmDensity)
    doAssert showFills(dmWiggle) and showFills(dmWiggleDensity)

  block sortLabel:
    doAssert sortLabel(@[], SortPresets) == "Sort: file order"
    doAssert sortLabel(SortPresets[0].keys, SortPresets) == "Sort: Line/Station"
    doAssert sortLabel(SortPresets[2].keys, SortPresets) == "Sort: By Component"
    let own = @[SortKey(field: hfChannel, descending: true)]
    doAssert sortLabel(own, SortPresets) == "Sort: custom"
    doAssert sortTip(@[]) == "Now: the file's order."
    doAssert sortTip(SortPresets[0].keys) == "Now: line, then point."

  block sortRows:
    let known = {hfRcvLine, hfRcvPoint, hfComponent}
    let rows = sortRows(SortPresets[1].keys, SortPresets, known)
    doAssert rows[0].kind == srFileOrder and rows[0].label == "File order" and not rows[0].inUse
    doAssert rows[1].kind == srPreset and rows[1].label == "Line/Station" and not rows[1].greyed
    doAssert rows[2].label == "By Flag" and rows[2].inUse and not rows[2].greyed
    doAssert rows[3].label == "By Component"
    doAssert rows[4].kind == srSeparator
    doAssert rows[^1].kind == srCustom and rows[^1].label == "Custom..." and not rows[^1].inUse
    let none = sortRows(@[], SortPresets, {hfChannel})
    doAssert none[0].inUse
    for row in none:
      if row.kind == srPreset:
        doAssert row.greyed, row.label & " is not greyed"
        doAssert "(these traces have none of them)" in row.tip, row.tip
    # the order in use stays selectable even when the file has none of its keys
    let held = sortRows(SortPresets[0].keys, SortPresets, {hfChannel})
    doAssert held[1].label == "Line/Station" and held[1].inUse and not held[1].greyed, $held[1]
    doAssert held[2].greyed and held[3].greyed
    let custom = sortRows(@[SortKey(field: hfOffset)], SortPresets, known)
    doAssert custom[^1].inUse and "Now: offset." in custom[^1].tip

  block sortPickDoesNothing:
    let rows = sortRows(SortPresets[0].keys, SortPresets, {hfRcvLine, hfRcvPoint})
    let again = sortPick(rows[1], SortPresets) # Line/Station, already in use
    doAssert not again.acts and not again.opensCustom
    let fileOrder = sortPick(rows[0], SortPresets)
    doAssert fileOrder.acts and fileOrder.order.len == 0
    let other = sortPick(rows[2], SortPresets)
    doAssert other.acts and other.order == SortPresets[1].keys
    let greyed = sortRows(@[], SortPresets, {hfChannel})
    doAssert not sortPick(greyed[1], SortPresets).acts
    doAssert not sortPick(rows[4], SortPresets).acts # the separator
    doAssert sortPick(rows[^1], SortPresets).opensCustom
    let already = sortPick(sortRows(@[], SortPresets, {})[0], SortPresets)
    doAssert not already.acts # File order, already in use

  block gainBox:
    doAssert gainDbText(0) == "+0.0 dB"
    doAssert gainDbText(12) == "+12.0 dB"
    doAssert gainDbText(-3) == "-3.0 dB"
    doAssert parseGainDb("12") == 12
    doAssert parseGainDb("+0.0 dB") == 0
    doAssert parseGainDb("-3 dB") == -3
    doAssert parseGainDb("  1.5db") == 1.5
    doAssert parseGainDb("no").isNaN
    doAssert parseGainDb("").isNaN

  echo "tstrip: ok"

when isMainModule:
  main()
