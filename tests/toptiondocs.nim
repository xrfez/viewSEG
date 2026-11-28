## The map's options described for the window and for the agent: every filter
## and every layer listed has a doc with an id, a label and an explanation; ids
## are unique; a filter's value says on or off as the settings do; a layer's
## `change` names an offered command and its value follows the layer's toggle;
## the window's own names (`mapLayers`) are the docs' labels.
##
## Seen to fail: with `filterDocs` reading the filter's value from `hits`
## rather than the settings, "a filter is on when the settings say so" failed;
## with the highlight left out of `layerDocs`, "the highlight has a doc" failed.

import std/[sets, strutils]
import viewSEG/core/[optiondocs, state]
import viewSEG/remote/schema
import viewSEG/view/[maplayers, theme]
import utils/[fixtures, waiting]

proc offeredKind(change: string): bool =
  for k in Offered:
    if change.startsWith("command \"" & $k & "\""): return true

proc main*() =

  block everyFilterHasADoc:
    var st = initAppState()
    let docs = st.filterDocs
    doAssert docs.len == ord(high(MapFilter)) + 1, "a filter is missing from the docs"
    var ids: HashSet[string]
    for d in docs:
      doAssert d.id.startsWith("map.filter.") and d.label.len > 0 and d.explain.len > 0, $d
      doAssert d.id == d.id.toLowerAscii and not ids.containsOrIncl(d.id), "id: " & d.id
      doAssert d.value == "off" and d.available and d.change.len == 0 and d.refused.len > 0, $d

  block filterIsOnWhenSettingsSay:
    var st = initAppState()
    var set = st.settings
    set.map.filters.incl mfDead
    st.apply Command(kind: ckSettings, settings: set)
    for d in st.filterDocs:
      doAssert (d.value == "on") == (d.id == "map.filter." & ($mfDead).toLowerAscii.replace(
        ' ', '-')), $d

  block layersHaveDocs:
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      st.apply Command(kind: ckLoadSurvey, paths: @[sps.s])
      doAssert st.settle(st.survey.layers.len == 1)
      let docs = st.layerDocs
      let views = st.mapLayers(MapInk())
      doAssert docs.len == views.len and docs.len >= 2, "docs against layers"
      var ids: HashSet[string]
      for i, d in docs:
        doAssert d.label.len > 0 and d.explain.len > 0 and d.id.len > 0, $d
        doAssert d.id == d.id.toLowerAscii and not ids.containsOrIncl(d.id), "id: " & d.id
        doAssert d.change.offeredKind, "not an offered command: " & d.change
        doAssert d.label == layerLabel(views[i].name, views[i].points), $d
        doAssert d.value == (if views[i].shown: "on" else: "off"), $d
        doAssert d.explain == layerTip(views[i].key.kind, views[i].role), $d
      doAssert docs[^1].id == "map.layer.highlight", "the highlight has a doc"
      st.apply Command(kind: ckMapLayer, mapLayer: views[0].key, shown: false)
      doAssert st.layerDocs[0].value == "off", "hidden layer reads off"

  echo "toptiondocs: ok"

when isMainModule:
  main()
