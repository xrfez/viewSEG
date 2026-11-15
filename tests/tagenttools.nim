## Agent control without a window and without a socket:
##
## - the protocol's framing and parsing, bounded: lines cut and limited,
##   JSON nested too deep refused before it is parsed, garbage, batches,
##   wrong ids and versions answered with JSON-RPC errors;
## - the handshake, `ping`, `tools/list`, unknown methods and tools;
## - the `command` tool's schema, made from `Command`: every kind offered is
##   there and described (from `core/state`'s doc comments) with the fields
##   it takes, and no refused kind is;
## - the tools answered from an `AppState`: bad commands are refused and
##   change nothing; a command changes the state (a file shown, a view, a
##   sort, a display given in part, a selection, a kill of the selected
##   trace); `state` and `headers` answer with what the state holds; `busy`
##   (what `wait` waits for) empties once the picture is complete; the other
##   tools refuse bad arguments.
##
## Seen to fail: with `prefill` not taking the panel's display, the check
## that a display given in part keeps the gain amount; with `kindOf` letting
## the kinds that write a file through, "export messages was not refused";
## with `nestingDepth` returning 0, the depth checks; with the docs read from
## the wrong block of `core/state`, "no description of \"paths\"".

import std/[json, os, sets, strutils, tables]
import viewSEG/core/state
import viewSEG/remote/[protocol, schema, tools]
import utils/[fixtures, waiting]

proc body(answer: string): JsonNode =
  ## The JSON a tool's text holds.
  parseJson(parseJson(answer)["content"][0]["text"].getStr)

proc isError(answer: string): bool = parseJson(answer)["isError"].getBool

block lines:
  var b = initLineBuffer(10)
  var l: string
  b.feed("ab\ncd")
  doAssert b.next(l) == lsLine and l == "ab"
  doAssert b.next(l) == lsWaiting
  b.feed("e\r\n\n")
  doAssert b.next(l) == lsLine and l == "cde"
  doAssert b.next(l) == lsLine and l == ""
  b.feed("0123456789X")
  doAssert b.next(l) == lsTooLong, "11 bytes without a line end"
  var c = initLineBuffer(10)
  c.feed("0123456789AB\n")
  doAssert c.next(l) == lsTooLong, "a 12-byte line"

block parse:
  var r: Request
  doAssert parseRequest("""{"jsonrpc":"2.0","id":7,"method":"ping"}""", r) == (0, "")
  doAssert r.id == "7" and r.meth == "ping" and r.params == nil
  doAssert parseRequest("""{"jsonrpc":"2.0","id":"a\"b","method":"x","params":{}}""",
    r).code == 0 and r.id == "\"a\\\"b\""
  doAssert parseRequest("""{"jsonrpc":"2.0","method":"notifications/initialized"}""",
    r).code == 0 and r.id == ""
  doAssert parseRequest("""{"jsonrpc":"2.0","id":1,"result":{}}""", r).code == 0 and
    r.meth == "", "a response is no request"
  for (text, code) in [("not json", ParseError), ("", ParseError), ("[1, 2]", InvalidRequest),
      ("3", InvalidRequest), ("""{"id":1,"method":"x"}""", InvalidRequest),
      ("""{"jsonrpc":"1.0","id":1,"method":"x"}""", InvalidRequest),
      ("""{"jsonrpc":"2.0","id":{},"method":"x"}""", InvalidRequest),
      ("""{"jsonrpc":"2.0","id":1.5,"method":"x"}""", InvalidRequest),
      ("""{"jsonrpc":"2.0","id":1,"method":7}""", InvalidRequest),
      ("""{"jsonrpc":"2.0","id":1,"method":"x","params":3}""", InvalidRequest),
      ("""{"jsonrpc":"2.0","id":1}""", InvalidRequest)]:
    doAssert parseRequest(text, r).code == code, text & ": " & $parseRequest(text, r)
  # nested too deep: refused before the parser (which recurses) sees it
  let deep = repeat('[', 200_000) & repeat(']', 200_000)
  doAssert deep.nestingDepth == 200_000
  doAssert parseRequest(deep, r).code == InvalidRequest
  doAssert parseRequest("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{\"a\":" &
    repeat("[", 70) & repeat("]", 70) & "}}", r).code == InvalidRequest
  doAssert nestingDepth("""{"a": "[[[[[[", "b": "\"[["}""") == 1, "brackets in strings"
  # odd but harmless: a huge number, bytes that are not UTF-8, a NUL
  for text in ["{\"jsonrpc\":\"2.0\",\"id\":123456789012345678901234567890,\"method\":\"x\"}",
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\xff\xfe\"}",
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\x00b\"}", "\x00\x01\x02"]:
    discard parseRequest(text, r) # answers something, never raises

block meta:
  let list = toolList()
  var answer, tool, arguments: string
  template ask(text: string): MetaAnswer =
    var r: Request
    doAssert parseRequest(text, r).code == 0, text
    answerMeta(r, list, "9.9", ToolNames, answer, tool, arguments)
  doAssert ask("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":
    "2024-11-05","clientInfo":{"name":"probe","version":"2"}}}""") == maInitialize
  let init = parseJson(answer)["result"]
  doAssert init["protocolVersion"].getStr == "2024-11-05", "an older revision is spoken"
  doAssert init["serverInfo"]["name"].getStr == "viewSEG" and
    init["serverInfo"]["version"].getStr == "9.9"
  doAssert init["capabilities"].hasKey("tools") and init["instructions"].getStr.len > 100
  discard ask("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":
    "1999-01-01"}}""")
  doAssert parseJson(answer)["result"]["protocolVersion"].getStr == ProtocolVersions[0]
  doAssert ask("""{"jsonrpc":"2.0","id":"p","method":"ping"}""") == maAnswered and
    parseJson(answer)["id"].getStr == "p" and parseJson(answer)["result"].len == 0
  doAssert ask("""{"jsonrpc":"2.0","method":"notifications/initialized"}""") == maAnswered and
    answer.len == 0, "a notification is not answered"
  doAssert ask("""{"jsonrpc":"2.0","id":2,"method":"resources/list"}""") == maAnswered and
    parseJson(answer)["error"]["code"].getInt == MethodNotFound
  doAssert ask("""{"jsonrpc":"2.0","id":3,"method":"tools/list"}""") == maAnswered
  let tools = parseJson(answer)["result"]["tools"]
  var names: seq[string]
  for t in tools:
    names.add t["name"].getStr
    doAssert t["inputSchema"]["type"].getStr == "object" and t["description"].getStr.len > 50
  doAssert names == @ToolNames, $names
  doAssert ask("""{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"state",
    "arguments":{"parts":["jobs"]}}}""") == maToolCall
  doAssert tool == "state" and parseJson(arguments) == %*{"parts": ["jobs"]}
  doAssert ask("""{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"state"}}""") ==
    maToolCall and arguments == "{}"
  for bad in ["""{"name":"format disk"}""", """{"arguments":{}}""",
      """{"name":"state","arguments":[1]}""", """{"name":3}"""]:
    doAssert ask("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":" & bad &
      "}") == maAnswered and parseJson(answer)["error"]["code"].getInt == InvalidParams, bad

block schemaFromCommand:
  let s = commandSchema()
  doAssert s["type"].getStr == "object" and s["required"] == %*["kind"]
  doAssert s["additionalProperties"].getBool == false
  var kinds: HashSet[string]
  for k in s["properties"]["kind"]["enum"]: kinds.incl k.getStr
  for k in CommandKind:
    doAssert (k in Offered) == ($k in kinds), $k
  doAssert "export messages" notin kinds and "settings" notin kinds and "sort" in kinds
  for k in Offered:
    doAssert Docs.kinds.getOrDefault($k).len > 0, "no description of the command \"" & $k & "\""
  for f in commandFields():
    doAssert Docs.fields.getOrDefault(f.name).len > 0, "no description of \"" & f.name & "\""
    doAssert s["properties"].hasKey(f.name), f.name
    doAssert "Used by" in s["properties"][f.name]["description"].getStr
  # each kind names only the fields it uses (one branch is shared by thirteen)
  doAssert takes(ckSort) == @["panel", "order"], $takes(ckSort)
  doAssert takes(ckShowFile) == @["panel", "path", "listFolder"], $takes(ckShowFile)
  doAssert takes(ckClearSelection).len == 0
  doAssert s["properties"]["display"]["properties"]["mode"]["enum"] ==
    %*["density", "wiggle", "wiggle over density"]
  # decoded as given, refused where it is wrong
  var problems: seq[string]
  var c = newCommand(ckSort)
  decodeFields(parseJson("""{"kind":"sort","panel":2,"order":[{"field":"channel",
    "descending":true},{"field":"FFID"}]}"""), c, problems)
  doAssert problems.len == 0 and int(c.panel) == 2 and c.order == @[SortKey(field: hfChannel,
    descending: true), SortKey(field: hfRecord)], $problems
  for (text, want) in [("""{"panel":"one"}""", "panel: an integer, not a string"),
      ("""{"order":[{"field":"nope"}]}""", "order[0].field: \"nope\" is not one of"),
      ("""{"order":[{"feld":"FFID"}]}""", "order[0]: no field \"feld\""),
      ("""{"gather":1}""", "\"sort\" takes no field \"gather\""),
      ("""{"order":{}}""", "order: an array, not an object")]:
    problems.setLen 0
    var d = newCommand(ckSort)
    decodeFields(parseJson(text), d, problems)
    doAssert problems.len == 1 and want in problems[0], text & ": " & $problems
  var k: CommandKind
  doAssert kindOf(parseJson("""{"kind":"Show File"}"""), k) == "" and k == ckShowFile
  doAssert "writes a file" in kindOf(parseJson("""{"kind":"export messages"}"""), k),
    "export messages was not refused"
  doAssert "preferences" in kindOf(parseJson("""{"kind":"settings"}"""), k)
  doAssert "no command" in kindOf(parseJson("""{"kind":"rm -rf"}"""), k)
  doAssert kindOf(parseJson("[]"), k).len > 0 and kindOf(parseJson("{}"), k).len > 0
  # NaN is null both ways
  doAssert $toJson(DisplaySettings().fixedClip) == "null"
  var d = DisplaySettings(fixedClip: 3)
  problems.setLen 0
  decode(parseJson("""{"fixedClip":null,"gainDb":-6}"""), d, "display", problems)
  doAssert problems.len == 0 and d.fixedClip != d.fixedClip and d.gainDb == -6

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

withFixtures fx:
  let path = fx.surveySegy()
  let before = (readFile(path), getLastModificationTime(path))
  var st = initAppState()
  let fe = Frontend()
  var applied = false

  proc run(st: var AppState; command: JsonNode): string =
    applied = false
    result = st.runCommand(fe, $command, applied)

  block refusedChangeNothing:
    for bad in ["", "[]", "{", "{\"kind\":3}", "{\"kind\":\"nope\"}",
        "{\"kind\":\"export messages\",\"docPath\":\"" & fx.dir / "x.txt" & "\"}",
        "{\"kind\":\"save layout\",\"layoutName\":\"x\"}", "{\"kind\":\"reset settings\"}",
        "{\"kind\":\"settings\"}", "{\"kind\":\"show file\",\"gather\":2}",
        "{\"kind\":\"display\",\"display\":{\"mode\":\"x\"}}",
        "{\"kind\":\"select\",\"traces\":\"all\"}", "{\"kind\":\"open\",\"paths\":[1]}"]:
      applied = false
      let answer = st.runCommand(fe, bad, applied)
      doAssert answer.isError and not applied, bad & ": " & answer
      doAssert parseJson(answer)["content"][0]["text"].getStr.startsWith("refused: "), answer
    doAssert st.sessions.len == 0 and st.panel(MainPanel).layers.len == 0
    doAssert not fileExists(fx.dir / "x.txt")

  block aCommandChangesTheState:
    let shown = st.run(%*{"kind": "show file", "path": path})
    doAssert applied and not shown.isError, shown
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    doAssert st.run(%*{"kind": "view", "view": {"traces": {"lo": -0.5, "hi": 23.5},
      "timeMs": {"lo": 0, "hi": 998}, "columns": 640, "rows": 1000}}).body["command"].getStr ==
      "view"
    doAssert st.panel(MainPanel).view.columns == 640, "the view was not taken"
    doAssert st.settle(busy(st, fe).len == 0), $busy(st, fe)

  block stateAnswers:
    let s = st.stateReport(fe, "{}").body
    for part in StateParts: doAssert s.hasKey(part), part
    let p = s["panels"][0]
    doAssert p["id"].getInt == 1 and p["title"].getStr == "Seismic" and
      p["picture"].getStr == "complete", $p["picture"]
    doAssert p["file"]["path"].getStr == path and p["positionCount"].getInt == Channels
    doAssert p["positions"][0].getInt == 0 and p["positions"][Channels - 1].getInt == Channels - 1
    doAssert p["view"]["columns"].getInt == 640 and p["layout"]["samples"].getInt == Samples
    doAssert s["files"][0]["traces"].getInt == SurveyTraces and s["files"][0]["gathers"].getInt == Shots
    doAssert s["jobs"].len >= 1 and s["jobs"][0]["state"].getStr == "done"
    let few = st.stateReport(fe, """{"parts":["panels"],"limit":3}""").body
    doAssert few.len == 1 and few["panels"][0]["positions"].len == 3
    let messages = st.stateReport(fe, """{"parts":["messages"],"messages":2}""").body
    doAssert st.log.len >= 1 and messages["messages"].len == min(2, st.log.len), $messages
    let none = st.stateReport(fe, """{"parts":["messages"],"messages":0}""").body
    doAssert none["messages"].len == 0
    let later = st.stateReport(fe, "{\"parts\":[\"messages\"],\"since\":" &
      $st.log.nextSerial & "}").body
    doAssert later["messages"].len == 0
    for bad in ["""{"parts":["secrets"]}""", """{"parts":"jobs"}""", """{"limit":0}""",
        """{"messages":-1}""", """{"what":1}""", "[]"]:
      doAssert st.stateReport(fe, bad).isError, bad

  block sortAndPartialDisplay:
    doAssert not st.run(%*{"kind": "sort", "order": [{"field": "channel",
      "descending": true}]}).isError
    doAssert st.settle(busy(st, fe).len == 0), $busy(st, fe)
    let p = st.stateReport(fe, """{"parts":["panels"]}""").body["panels"][0]
    doAssert p["positions"][0].getInt == Channels - 1, $p["positions"]
    doAssert p["order"] == %*[{"field": "channel", "descending": true}]
    doAssert not st.run(%*{"kind": "display", "display": {"gain": "none", "gainDb": 6}}).isError
    let gain = st.panel(MainPanel).layers[0].display.gain
    doAssert gain == dgNone and st.panel(MainPanel).layers[0].display.gainDb == 6
    doAssert not st.run(%*{"kind": "display", "display": {"mode": "density"}}).isError
    doAssert st.panel(MainPanel).layers[0].display.mode == dmDensity and
      st.panel(MainPanel).layers[0].display.gainDb == 6
    doAssert st.panel(MainPanel).layers[0].display.gain == gain,
      "a display given in part kept the gain: " & $st.panel(MainPanel).layers[0].display.gain

  block headersAnswer:
    let h = st.traceHeaderReport("""{"panel":1,"position":0}""").body
    doAssert h["index"].getInt == Channels - 1 and h["keys"]["channel"].getFloat == Channels,
      $h["keys"]
    doAssert h["gather"].getInt == 0 and h["headers"].len > 50
    var fields: seq[string]
    for row in h["headers"]: fields.add row["field"].getStr
    doAssert "fieldRecord" in fields or "FFID" in fields or fields.len > 50, $fields
    let byId = st.traceHeaderReport("""{"trace":5}""").body
    doAssert byId["index"].getInt == 5 and byId["keys"]["channel"].getFloat == 6
    doAssert st.traceHeaderReport("""{"file":1,"index":30}""").body["gather"].getInt == 1
    for bad in ["{}", """{"trace":999999}""", """{"panel":9,"position":0}""",
        """{"panel":1,"position":24}""", """{"file":5,"index":0}""", """{"file":1,"index":72}""",
        """{"trace":-1}""", """{"trace":"5"}""", """{"color":1}"""]:
      doAssert st.traceHeaderReport(bad).isError, bad

  block selectAndKill:
    let id = st.sessions[0].base + 4
    doAssert not st.run(%*{"kind": "select", "traces": [id], "mode": "replace"}).isError
    doAssert st.selection.selected.len == 1
    let killed = st.run(%*{"kind": "edit traces", "edit": "killed"}) # the selected traces, on
    doAssert not killed.isError, killed
    doAssert st.traceEdits(id) == {teKilled}, $st.traceEdits(id)
    doAssert st.settle(busy(st, fe).len == 0), $busy(st, fe)
    let p = st.stateReport(fe, """{"parts":["panels"]}""").body["panels"][0]
    doAssert p["killed"] == %*[4] and p["canUndoEdit"].getBool
    # a command that does not fit the state is carried out as the windows' are: ignored, said
    let ignored = st.run(%*{"kind": "go to gather", "gather": 99})
    doAssert ignored.isError and ignored.body["ignored"].getBool and
      "Ignored" in ignored.body["messages"][0]["text"].getStr, ignored

  block otherToolsRefuse:
    doAssert screenshot(fe, "{}").isError, "no window: no picture"
    for bad in ["""{"window":"desktop"}""", """{"maxSize":10}""", """{"x":1}""", "3"]:
      doAssert screenshot(fe, bad).isError, bad
    var seconds = 0.0
    doAssert waitArgs("""{"timeout":2.5}""", seconds) == "" and seconds == 2.5
    doAssert waitArgs("{}", seconds) == "" and seconds == DefaultWaitSeconds
    for bad in ["""{"timeout":-1}""", """{"timeout":1e9}""", """{"timeout":"1"}""",
        """{"until":1}""", "[]"]:
      doAssert waitArgs(bad, seconds).len > 0, bad

  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
  echo "tagenttools: ok"
