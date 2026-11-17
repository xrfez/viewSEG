## docs/coverage.md stays the complete and true list of the libraries' public
## API: every name parseSEG and processSEG export is named in a row, a row that
## says `built` or `internal` names only what the viewer's source calls, and the
## summary is the one the tables give. `tools/coverage.nim` does the work (its
## module doc says how); `nim coverage` rewrites the summary.
##
## The libraries are read at the commits atlas.lock pins (`git archive`, which
## changes nothing in them), and their next releases only when a working tree
## of each is linked at `deps/next/<library>`: CI, which has none, checks the
## locked releases. Nothing needs the network.
##
## Seen to fail, each broken once and then restored: `saveIndex` taken out of
## the page's "Index cache" row ("proc `saveIndex` (model/traceindex) is named
## in no row"); the "Sort by header fields" row's status set to `built`
## ("says built, but src/ never names sortTraces"); a count of the summary
## changed by hand ("the summary is not the tables'"); `opCalibrate` taken out of
## the next-release rows, with the next releases linked ("new enum value
## `opCalibrate` ... is named in no row"); the viewer's `recordSpread` named
## `spreadOf` again ("says built for `spreadOf`, but src/ declares a
## `spreadOf` of its own"); "The Messages window" of the Diagnostics row
## written "The Frobs window" ("names the Frobs window, which src/ has
## not"); the "Field records against the XPS" row's status set to `not
## applicable` ("`recordCompleteness` is named in src/, but its rows say not
## applicable").

import std/[assertions, os, sequtils, sets, strutils, tables]
import ../tools/coverage

const root = currentSourcePath().parentDir.parentDir

proc page(rows: varargs[string]): Page =
  ## A page of the parseSEG section holding `rows` (each a table row).
  parsePage("## parseSEG\n\n### Group\n\n| Capability | Library calls | Viewer feature | " &
    "Status |\n|---|---|---|---|\n" & rows.join("\n") & "\n")

func has(problems: seq[string], text: string): bool =
  for p in problems:
    if text in p: return true

proc main*() =

  block each_check_fires:
    let lib = Library(name: "parseSEG", version: "1.0", exports: @[
      Export(name: "openThing", kind: "proc", module: "a"),
      Export(name: "readThing", kind: "proc", module: "a"),
      Export(name: "Mode", kind: "type", module: "a"),
      Export(name: "mFast", kind: "enum value", module: "a", owner: "Mode"),
      Export(name: "unnamed", kind: "proc", module: "b")])
    let src = toHashSet([normName("openThing"), normName("mFast")])
    let good = page("| Open | `openThing`, `Mode` | File → Open | built |",
      "| Read | `readThing` | to come | planned |",
      "| Other | `unnamed` | none | not applicable (no reason needed here) |")
    doAssert check(good, [lib], [], src).problems.len == 0,
      $check(good, [lib], [], src).problems

    # A name named in no row; an enum value is named by its type.
    let missing = check(page("| Open | `openThing`, `Mode` | File → Open | built |"), [lib], [],
      src).problems
    doAssert missing.has("`readThing` (a) is named in no row") and
      missing.has("`unnamed` (b) is named in no row") and not missing.has("mFast"), $missing

    # Built for a name the source never names; built in part with none named.
    let claims = check(page("| Open | `openThing`, `readThing`, `Mode`, `unnamed` | x | built |"),
      [lib], [], src).problems
    doAssert claims.has("says built, but src/ never names readThing, unnamed"), $claims
    doAssert not claims.has("names Mode"), "an enum type is used where its value is"
    let part = check(page("| Read | `readThing`, `unnamed`, `openThing`, `Mode` | x | " &
      "built (one); planned (the rest) |"), [lib], [], toHashSet(["x"])).problems
    doAssert part.has("says built in part, but src/ names none of"), $part
    let some = check(page("| Read | `readThing`, `unnamed`, `openThing`, `Mode` | x | " &
      "built (one); planned (the rest) |"), [lib], [], src)
    doAssert some.problems.len == 0, $some.problems
    doAssert some.nameStatus[0]["openThing"] == stBuilt and
      some.nameStatus[0]["readThing"] == stPlanned, "a name's status in a row built in part"

    # A row naming nothing of its library, and a status that cannot be read.
    let stray = check(page("| Open | `openThing`, `Mode`, `readThing`, `unnamed` | x | planned |",
      "| Gone | `renamedLongAgo` | x | planned |",
      "| Odd | `openThing` | x | done |"), [lib], [], src).problems
    doAssert stray.has("names no exported name of parseSEG") and stray.has("status \"done\""),
      $stray

    # A name the next release adds, and a new value of an old enum.
    var next = lib
    next.exports.add Export(name: "newThing", kind: "proc", module: "a")
    next.exports.add Export(name: "mSlow", kind: "enum value", module: "a", owner: "Mode")
    let all = "| All | `openThing`, `Mode`, `readThing`, `unnamed` | x | built (one); planned |"
    let ahead = check(page(all), [lib], [next], src).problems
    doAssert ahead.has("new proc `newThing`") and ahead.has("new enum value `mSlow`"), $ahead
    let named = parsePage("## parseSEG\n\n| Capability | Library calls | Viewer feature | Status |" &
      "\n|---|---|---|---|\n" & all & "\n\n## In the next library release\n\n### parseSEG\n\n" &
      "| Capability | Library calls | Viewer feature | Status |\n|---|---|---|---|\n" &
      "| New | `newThing`, `mSlow` | x | planned |\n")
    doAssert check(named, [lib], [next], src).problems.len == 0

    # The summary counts names by status and lists what is to plan, by priority.
    let todo = page("| Open | `openThing`, `Mode` | File → Open | built |",
      "| Read | `readThing` | reading | to plan (priority 2: soon) |",
      "| Other | `unnamed` | other | to plan (priority 1) |")
    let s = summary(todo, [lib], check(todo, [lib], [], src))
    doAssert "| `built` | 1 (0 in part) | 2 |" in s and "| `to plan` | 2 | 2 |" in s, s
    doAssert s.find("**Other**") < s.find("**Read**") and "): soon" in s and "): other" in s, s
    doAssert currentSummary("x\n" & s & "\ny") == s and
      currentSummary(withSummary("a " & SummaryStart & " old " & SummaryEnd & " b", s)) == s

  block lies_a_text_search_missed:
    let lib = Library(name: "parseSEG", version: "1.0", exports: @[
      Export(name: "openThing", kind: "proc", module: "a"),
      Export(name: "readThing", kind: "proc", module: "a"),
      Export(name: "record", kind: "proc", module: "a")])
    let src = toHashSet([normName("openThing"), normName("readThing"), normName("record")])
    # A built claim for a name the viewer declares too: the search cannot tell.
    let built = page("| Open | `openThing` | File → Open file... | built |",
      "| Rest | `readThing`, `record` | x | internal |")
    doAssert check(built, [lib], [], src).problems.len == 0
    let mine = check(built, [lib], [], src, declared = toHashSet([normName("openThing"),
      normName("record")])).problems
    doAssert mine.has("declares a `openThing` of its own") and not mine.has("`record`"), $mine
    # A built row naming a window or a menu item the viewer does not have.
    let ui = UiNames(windows: toHashSet(["Files", "Headers"]),
      labels: toHashSet(["File", "Open file", "Import", "Import survey", "Headers"]))
    let named = page("| Open | `openThing` | the Headers window; File → Open file...; " &
      "File → Import → Survey, then more | built |",
      "| Rest | `readThing`, `record` | the Frobs window, File → Frob | internal |",
      "| Later | `openThing` | x | built (one); planned (the Plans window) |")
    let wm = check(named, [lib], [], src, ui = ui).problems
    doAssert wm.has("names the Frobs window") and wm.has("has no \"Frob\"") and wm.len == 2, $wm
    # A distinctive name src/ names whose rows say it is not built.
    let stale = page("| Open | `openThing` | x | built |",
      "| Rest | `readThing`, `record` | x | not applicable (no reason) |")
    let st = check(stale, [lib], [], src).problems
    doAssert st.has("`readThing` is named in src/, but its rows say not applicable") and
      not st.has("`record`"), $st

  block names_in_cells_and_code:
    doAssert spanNames("`f.len`, `readTraces(f, traces)`, `$`, `[]=`, plain words") ==
      @["f", "len", "readTraces", "f", "traces", "$", "[]="]
    doAssert spanNames("``a `b` c``") == @["a", "b", "c"]
    doAssert declaredNames("proc used*(x: int) = discard\nfunc `$`*(a: A): string = \"\"\n" &
      "type\n  Shape* = object\n  Kind = enum\n    kOne\n  # Commented = object\n" &
      "iterator walked(): int = discard\n") == toHashSet(["used", "$", "Shape", "Kind",
      "walked"].mapIt(normName(it)))
    doAssert stringLiterals("echo \"a\", 'b', \"c\\\"d\" # \"no\"\nx = \"\"\"e\"\"\"") ==
      @["a", "c\\\"d", "e"]
    doAssert windowsNamed("the Headers window; Import survey window, the processing window") ==
      @["Headers", "Import survey"]
    doAssert menuPaths("File → Import → Survey: and File → Open file..., then") ==
      @[@["File", "Import", "Survey"], @["File", "Open file..."]]
    let code = codeNames("""
proc used() = discard # notUsed in a comment
  ## docOnly
let s = "inString" & 'q' & r"rawString"
#[ blockComment ]#
x.`[]=`(1)
""")
    doAssert normName("used") in code and normName("s") in code and "[]=" in code
    for n in ["notUsed", "docOnly", "inString", "rawString", "blockComment"]:
      doAssert normName(n) notin code, n

  block the_page_is_complete_and_true:
    let r = run(root)
    doAssert r.libs.len == 2, "both libraries read"
    for l in r.libs:
      echo "tcoverage: ", l.name, " ", l.version, " (", l.source, "): ", l.names.len,
        " exported names, ", l.enumValueOwners.len, " enum values"
    for l in r.next:
      echo "tcoverage: next ", l.name, " (", l.source, "): ", l.names.len, " exported names"
    if r.next.len == 0: echo "tcoverage: no next release linked at deps/next: not checked"
    doAssert r.coverage.problems.len == 0, $r.coverage.problems.len & " problems in " & PageFile &
      " (run `nim coverage` for the summary; tools/coverage.nim says what each check means):\n  " &
      r.coverage.problems.join("\n  ")

when isMainModule:
  main()
