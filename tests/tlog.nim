## The message log: its bound, its order, serial numbers that survive drops,
## counts per severity, and parseSEG's diagnostics taken in with their
## locations.
##
## Seen to fail: with `add` no longer dropping the oldest entry, `bound`
## found 8 entries in a log of 5; with `since` counting from the first kept
## entry instead of by serial, `sinceSerial` got the wrong entries.

import parseSEG/common/diagnostics
import viewSEG/core/log

proc texts(log: MessageLog): seq[string] =
  for e in log: result.add e.text

block bound:
  var log = initMessageLog(capacity = 5)
  for i in 0 ..< 8:
    log.add(if i mod 2 == 0: sevInfo else: sevWarning, "test", "message " & $i)
  doAssert log.len == 5
  doAssert log.capacity == 5
  doAssert log.dropped == 3
  doAssert log.texts == @["message 3", "message 4", "message 5", "message 6", "message 7"]
  doAssert log[0].serial == 3 and log[4].serial == 7
  doAssert log.nextSerial == 8
  doAssert log.count(sevInfo) == 2 and log.count(sevWarning) == 3, "counts are of kept entries"
  doAssert log.count(sevError) == 0

block order:
  var log = initMessageLog()
  for i in 0 ..< 100:
    log.add(sevInfo, "test", $i)
  var serial = 0
  for e in log:
    doAssert e.serial == serial and e.text == $serial
    inc serial
  doAssert log.dropped == 0

block sinceSerial:
  var log = initMessageLog(capacity = 3)
  for i in 0 ..< 6:
    log.add(sevInfo, "test", $i) # keeps 3, 4, 5
  var seen: seq[string]
  for e in log.since(4): seen.add e.text
  doAssert seen == @["4", "5"]
  seen.setLen 0
  for e in log.since(0): seen.add e.text # older than kept: all that is kept
  doAssert seen == @["3", "4", "5"]
  seen.setLen 0
  for e in log.since(6): seen.add e.text # nothing new
  doAssert seen.len == 0

block diagnosticsKeepTheirPlace:
  var diags: DiagLog
  diags.report(sevWarning, dcBadValue, "format code 0 is not defined", 4340,
    Location(file: "63.sgd", record: 0, field: "GH1.formatCode"))
  diags.report(sevError, dcTruncated, "the trace ends early", -1,
    Location(file: "63.sgd", record: 0, trace: 3))
  var log = initMessageLog()
  log.add(sevInfo, "open", "Opening 63.sgd")
  log.add(diags, "63.sgd")
  doAssert log.len == 3
  doAssert log[1].severity == sevWarning and log[1].source == "63.sgd"
  doAssert log[1].text == "format code 0 is not defined"
  doAssert log[1].offset == 4340 and log[1].loc.field == "GH1.formatCode"
  doAssert log[2].severity == sevError and log[2].loc.trace == 3 and log[2].offset == -1
  doAssert log.count(sevError) == 1

block defaultConstructed:
  var log: MessageLog
  log.add(sevInfo, "test", "works")
  doAssert log.len == 1 and log.capacity == DefaultLogCapacity
