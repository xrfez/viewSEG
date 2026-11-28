## NIF text for the program's own documents: the settings and the layouts.
##
## A small reader and writer for the part of NIF (nim-lang/nifspec) these
## documents use: directives (`(.nif27)`), nodes with a tag (`(name ...)`),
## identifiers, integers, decimal floats and string literals. What is written
## is plain NIF that other NIF readers accept: strings escape NIF's special
## characters (but `#` and `:`, which NIF allows there) and control bytes as
## `\HH`, and keep valid UTF-8 and line feeds as they are, so a path or a
## long text (a layout) stays readable.
##
## The documents can be edited by hand, copied between machines and damaged,
## so `parseNif` treats them as untrusted input: it bounds the document's
## size, the nesting, the number of nodes, strings, tags and numbers, and
## reports every problem as `NifError` with the document's name and the
## line, never anything else. It also takes `;` comments (to the end of the
## line), which a person may add, and either line ending.
##
## A document is read whole into a tree of `NifNode`s, so a caller can take
## what it understands from each node and skip the rest without losing its
## place.

import std/[strutils, unicode]

const
  MaxNifBytes* = 4 shl 20 ## the largest document `parseNif` reads, in bytes
  MaxNifDepth* = 32       ## the deepest nesting it follows
  MaxNifNodes* = 100_000  ## the most nodes (atoms and compound nodes) it builds
  MaxNifWord* = 256       ## the longest tag or identifier
  MaxNifNumber* = 64      ## the longest number, in characters
  WordedProblems* = 100
    ## problems a reader of these documents words (`readSettings`,
    ## `readLayout`); it counts the rest as empty lines, since a hostile
    ## document can hold tens of thousands
  NifIdentStart = {'A'..'Z', 'a'..'z', '_'}
  NifIdentChars = NifIdentStart + {'0'..'9'}
  NifSpecial = {'(', ')', '[', ']', '{', '}', '~', '\'', '"', '\\', '@'}
    ## written escaped inside a string (NIF takes `#` and `:` there as they are)

type
  NifError* = object of ValueError
    ## A document that is not NIF, or not within the reader's bounds.
    line*: int ## 1-based; 0 when the problem is the document as a whole

  NifKind* = enum
    nkTree = "node" ## `(tag ...)`
    nkIdent = "identifier"
    nkInt = "integer"
    nkFloat = "number"
    nkString = "string"

  NifNode* = object
    ## One node of a document.
    line*: int      ## where it starts, from 1
    case kind*: NifKind
    of nkTree:
      tag*: string  ## "" for none; a directive's starts with "."
      kids*: seq[NifNode]
    of nkIdent, nkString:
      text*: string ## the identifier, or the decoded string
    of nkInt: intVal*: int64
    of nkFloat: floatVal*: float64

  NifWriter* = object
    ## Builds a document: `open`, the atoms, `close`. Nodes up to
    ## `breakDepth` deep start on a line of their own, indented.
    text*: string
    depth: int
    breakDepth: int

  Parser = object
    s: string
    pos, line, nodes: int
    name: string

# ----------------------------------------------------------------- writing --

func isNifIdent*(s: string): bool =
  ## Whether `s` can be written as a NIF identifier or tag: a letter or `_`,
  ## then letters, digits or `_`, at most `MaxNifWord` long.
  s.len in 1..MaxNifWord and s[0] in NifIdentStart and s.allCharsInSet(NifIdentChars)

func nifString*(s: string): string =
  ## `s` as a NIF string literal. A line feed and valid UTF-8 stay as they
  ## are; NIF's special characters, other control bytes and bytes that are
  ## not UTF-8 are written as `\HH`.
  let utf8 = validateUtf8(s) < 0
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for c in s:
    if c in NifSpecial or (ord(c) < 0x20 and c != '\n') or ord(c) == 0x7F or
        (ord(c) >= 0x80 and not utf8):
      result.add '\\'
      result.add toHex(ord(c), 2)
    else:
      result.add c
  result.add '"'

func nifFloat*(x: float64): string =
  ## `x` as a NIF float literal: always with a fraction or an exponent, so it
  ## reads back as a float. NIF has no NaN or infinity: a non-finite `x` is written
  ## as 0.0.
  result = if x == x and x != Inf and x != -Inf: $x else: "0.0"
  if not result.contains({'.', 'e', 'E'}): result.add ".0"

func initNifWriter*(breakDepth = 2): NifWriter =
  ## A writer of a new document, with the NIF version directive and
  ## `(.vendor "viewSEG")` written.
  result = NifWriter(breakDepth: breakDepth)
  result.text.add "(.nif27)\n(.vendor \"viewSEG\")"

proc separate(w: var NifWriter) =
  if w.text.len > 0 and w.text[^1] notin {'(', '\n'}: w.text.add ' '

proc open*(w: var NifWriter; tag: string) =
  ## Starts a node `(tag`. `tag` must be an identifier (`isNifIdent`).
  assert isNifIdent(tag), "not a NIF tag: " & tag
  if w.depth <= w.breakDepth:
    w.text.add '\n'
    w.text.add repeat(' ', w.depth)
  else:
    w.separate()
  w.text.add '('
  w.text.add tag
  inc w.depth

proc close*(w: var NifWriter) =
  ## Ends the node opened last.
  assert w.depth > 0, "no node is open"
  w.text.add ')'
  dec w.depth

proc ident*(w: var NifWriter; s: string) =
  ## Writes the identifier `s` (`isNifIdent`).
  assert isNifIdent(s), "not a NIF identifier: " & s
  w.separate()
  w.text.add s

proc add*(w: var NifWriter; s: string) =
  ## Writes the string `s`.
  w.separate()
  w.text.add nifString(s)

proc add*(w: var NifWriter; i: int64) =
  ## Writes the integer `i`.
  w.separate()
  w.text.add $i

proc add*(w: var NifWriter; x: float64) =
  ## Writes the finite float `x`.
  w.separate()
  w.text.add nifFloat(x)

proc add*(w: var NifWriter; b: bool) =
  ## Writes `true` or `false`.
  w.ident(if b: "true" else: "false")

proc add*(w: var NifWriter; n: NifNode) =
  ## Writes `n`, a node as `parseNif` read it (a node of a later version a
  ## reader keeps to write back): it reads back as the same node.
  case n.kind
  of nkTree:
    if isNifIdent(n.tag): w.open n.tag
    else: # no tag, or a directive's: as it was read
      if w.depth <= w.breakDepth:
        w.text.add '\n'
        w.text.add repeat(' ', w.depth)
      else: w.separate()
      w.text.add '('
      w.text.add n.tag
      inc w.depth
    for k in n.kids: w.add k
    w.close
  of nkIdent:
    w.separate()
    w.text.add n.text
  of nkString: w.add n.text
  of nkInt: w.add n.intVal
  of nkFloat: w.add n.floatVal

func finish*(w: NifWriter): string =
  ## The document, with a final line break. Every node must be closed.
  assert w.depth == 0, $w.depth & " nodes are still open"
  w.text & "\n"

# ----------------------------------------------------------------- reading --

proc fail(p: Parser; msg: string) {.noinline, noreturn.} =
  var e = newException(NifError, p.name & " line " & $p.line & ": " & msg)
  e.line = p.line
  raise e

proc skipBlank(p: var Parser) =
  ## Skips white space and `;` comments.
  while p.pos < p.s.len:
    let c = p.s[p.pos]
    if c == '\n':
      inc p.line
      inc p.pos
    elif c in {' ', '\t', '\r', '\f', '\v'}:
      inc p.pos
    elif c == ';':
      while p.pos < p.s.len and p.s[p.pos] != '\n': inc p.pos
    else:
      break

proc counted(p: var Parser) =
  inc p.nodes
  if p.nodes > MaxNifNodes: p.fail("more than " & $MaxNifNodes & " nodes")

proc word(p: var Parser; what: string): string =
  ## An identifier or a tag's name at `pos` (possibly empty).
  let start = p.pos
  if p.pos < p.s.len and p.s[p.pos] notin NifIdentStart: return ""
  while p.pos < p.s.len and p.s[p.pos] in NifIdentChars:
    inc p.pos
    if p.pos - start > MaxNifWord: p.fail(what & " longer than " & $MaxNifWord & " characters")
  p.s.substr(start, p.pos - 1)

func hexValue(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'A'..'F': ord(c) - ord('A') + 10
  of 'a'..'f': ord(c) - ord('a') + 10
  else: -1

proc stringLit(p: var Parser): string =
  ## After the opening `"`: the decoded string, up to its closing `"`.
  result = ""
  while true:
    if p.pos >= p.s.len: p.fail("the document ends inside a string")
    let c = p.s[p.pos]
    inc p.pos
    case c
    of '"': break
    of '\\':
      if p.pos >= p.s.len: p.fail("the document ends inside a string")
      let e = p.s[p.pos]
      inc p.pos
      case e
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of '|': result.add '\\' # the spelling of newer NIF writers
      of '^': result.add '"'
      else:
        let hi = hexValue(e)
        let lo = if p.pos < p.s.len: hexValue(p.s[p.pos]) else: -1
        if hi < 0 or lo < 0: p.fail("bad escape in a string: \\" & e)
        inc p.pos
        result.add char(hi * 16 + lo)
    of '\n':
      inc p.line
      result.add c
    else:
      if ord(c) < 0x20 and c notin {'\t', '\r'}:
        p.fail("a control character (" & toHex(ord(c), 2) & ") in a string")
      result.add c

proc number(p: var Parser): NifNode =
  let line = p.line
  let start = p.pos
  if p.s[p.pos] in {'+', '-'}: inc p.pos
  while p.pos < p.s.len and p.s[p.pos] in {'0'..'9', '.', 'e', 'E', '+', '-', '_'}:
    inc p.pos
    if p.pos - start > MaxNifNumber: p.fail("a number longer than " & $MaxNifNumber &
      " characters")
  let t = p.s.substr(start, p.pos - 1).replace("_", "")
  if t.contains({'.', 'e', 'E'}):
    var x = 0.0
    try:
      x = parseFloat(t)
    except ValueError:
      p.fail("bad number " & t)
    if x != x or x == Inf or x == -Inf: p.fail("number out of range: " & t)
    result = NifNode(kind: nkFloat, line: line, floatVal: x)
  else:
    var i = 0'i64
    try:
      i = parseBiggestInt(t)
    except ValueError:
      p.fail("bad or out-of-range integer " & t)
    result = NifNode(kind: nkInt, line: line, intVal: i)

proc node(p: var Parser; depth: int): NifNode {.gcsafe.}
  # Recursive: Nim does not infer GC safety through the forward declaration,
  # and the disk thread parses documents.

proc tree(p: var Parser; depth: int): NifNode =
  ## After `(`: the node's tag and children, up to its `)`.
  if depth > MaxNifDepth: p.fail("nesting deeper than " & $MaxNifDepth)
  result = NifNode(kind: nkTree, line: p.line)
  if p.pos < p.s.len and p.s[p.pos] == '.':
    inc p.pos
    result.tag = "." & p.word("a tag")
  else:
    result.tag = p.word("a tag")
  while true:
    p.skipBlank()
    if p.pos >= p.s.len: p.fail("the document ends before (" & result.tag &
      ", opened on line " & $result.line & ", is closed")
    if p.s[p.pos] == ')':
      inc p.pos
      break
    result.kids.add p.node(depth)

proc node(p: var Parser; depth: int): NifNode {.gcsafe.} =
  ## The node at `pos`, which is not blank.
  p.counted()
  let c = p.s[p.pos]
  case c
  of '(':
    inc p.pos
    result = p.tree(depth + 1)
  of ')':
    p.fail("')' closes nothing")
  of '"':
    let line = p.line
    inc p.pos
    result = NifNode(kind: nkString, line: line, text: p.stringLit())
  of '0'..'9', '+', '-':
    result = p.number()
  elif c in NifIdentStart:
    result = NifNode(kind: nkIdent, line: p.line, text: p.word("an identifier"))
  else:
    p.fail("unexpected character " & escape($c))
  if p.pos < p.s.len and p.s[p.pos] in {'@', '#', ':', '~', '[', ']', '{', '}', '\''}:
    p.fail("unexpected character " & escape($p.s[p.pos]) &
      " (line information and other NIF suffixes are not read here)")

proc parseNif*(text: string; name: string; most = MaxNifBytes): seq[NifNode] =
  ## The top-level nodes of the document `text`, directives first as
  ## written; error messages call it `name`. Raises `NifError` for anything
  ## that is not NIF within the bounds above (a document of at most `most`
  ## bytes), whatever `text` holds.
  if text.len > most:
    var e = newException(NifError, name & " is larger than " & $(most shr 20) &
      " MB, so it is not read")
    raise e
  var p = Parser(s: text, line: 1, name: name)
  # A UTF-8 byte order mark, which some editors add.
  if p.s.startsWith("\xEF\xBB\xBF"): p.pos = 3
  while true:
    p.skipBlank()
    if p.pos >= p.s.len: break
    result.add p.node(0)

# --------------------------------------------------------------- the tree --

func isTree*(n: NifNode; tag: string): bool {.inline.} =
  ## Whether `n` is a node `(tag ...)`.
  n.kind == nkTree and n.tag == tag

func describe*(n: NifNode): string =
  ## What `n` is, for a message: "(window ...)", "the identifier wiggle".
  case n.kind
  of nkTree: "(" & n.tag & " ...)"
  of nkIdent: "the identifier " & n.text
  of nkInt: "the integer " & $n.intVal
  of nkFloat: "the number " & $n.floatVal
  of nkString: "the string " & nifString(if n.text.len > 40: n.text[0 ..< 40] & "..."
                                         else: n.text)
