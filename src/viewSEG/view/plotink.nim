## The plot's colours, from the theme's roles, for each of the plot's
## colour schemes (`PlotColours`): the background, the wiggle line and its
## fills, and the colours of a hovered and of a selected trace.
##
## - **Paper** (the Seismic window's default): white, black line and positive
##   fill, the theme's red for the negative fill, whatever the theme.
## - **Follow the theme:** the theme's plot background, its trace and fill
##   roles.
## - **Custom:** the colours the user chose (`CustomColours`); one not
##   chosen yet is paper's.
## - **Red on paper** (the Aux window's default): paper, with the wiggle line
##   and the positive fill in that same red, and the negative fill black.
##
## A hovered trace takes the theme's highlight colour (orange, the colour
## of the linked selection) and a selected one its `selected` role (its
## accent, the colour of a selected button, unless that is too close to the
## traces), each made dark or light enough to read on the background
## (`readableOn`), so a highlight stands out on paper and on a dark plot
## alike; the theme keeps the two apart from the traces and from each other
## (`deriveRoles`).

import std/math
import ../core/[geometry, panels, wiggle]
import theme

const
  PaperBackground* = White
  PaperInk* = Black
  MinContrast* = InkContrast
    ## the contrast a highlight keeps against the background (WCAG's ratio
    ## for graphics)
  DensityTint* = 0.55'f32
    ## how far a hovered or selected trace's column is tinted under density

type
  PlotInk* = object
    ## The colours a plot is drawn in.
    background*: Rgba
    wiggle*: WiggleInk
    breakModel*, breakPick*: Rgba
      ## the first-break overlay's bars: where the model expects the break and
      ## where it was picked, each readable on `background`

func readableOn*(c, background: Rgba; ratio = MinContrast): Rgba {.inline.} =
  ## `c`, darkened on a light background or lightened on a dark one, just
  ## enough to stand out from `background` by `ratio` (as far as black or
  ## white allows).
  readable(c, background, ratio)

func opaque(c: Rgba): Rgba {.inline.} = Rgba(r: c.r, g: c.g, b: c.b, a: 255)

const
  DeepContrast = 9.0  ## the model's bar against the plot: the strong one, deep or pale
  VividContrast = 3.3 ## the pick's: a mid tone, so the two differ in lightness as in hue

func toHsl(c: Rgba): (float64, float64, float64) =
  let (r, g, b) = (c.r.float64 / 255, c.g.float64 / 255, c.b.float64 / 255)
  let (hi, lo) = (max(r, max(g, b)), min(r, min(g, b)))
  let l = (hi + lo) / 2
  if hi == lo: return (0.0, 0.0, l)
  let d = hi - lo
  let s = if l > 0.5: d / (2 - hi - lo) else: d / (hi + lo)
  var h = if hi == r: (g - b) / d + (if g < b: 6.0 else: 0.0)
          elif hi == g: (b - r) / d + 2
          else: (r - g) / d + 4
  (h / 6, s, l)

func fromHsl(h, s, l: float64): Rgba =
  func channel(p, q, t0: float64): float64 =
    var t = t0
    if t < 0: t += 1
    if t > 1: t -= 1
    if t < 1 / 6: p + (q - p) * 6 * t
    elif t < 1 / 2: q
    elif t < 2 / 3: p + (q - p) * (2 / 3 - t) * 6
    else: p
  let q = if l < 0.5: l * (1 + s) else: l + s - l * s
  let p = 2 * l - q
  func byte(x: float64): uint8 = uint8(round(clamp(x, 0, 1) * 255))
  Rgba(r: byte(channel(p, q, h + 1 / 3)), g: byte(channel(p, q, h)),
    b: byte(channel(p, q, h - 1 / 3)), a: 255)

func tuned(c, background: Rgba; want: float64): Rgba =
  ## `c`'s hue, as saturated as a bar needs to read, at the lightness where its
  ## contrast with `background` is `want` (deeper on a light background, paler
  ## on a dark one), found by bisection.
  let (h, s0, _) = toHsl(opaque(c))
  let s = max(s0, 0.65)
  let lightBg = luminance(background) > 0.18
  var (lo, hi) = if lightBg: (0.0, 0.75) else: (0.3, 1.0)
  for _ in 0 ..< 24:
    let mid = (lo + hi) / 2
    let enough = contrast(fromHsl(h, s, mid), background) > want
    if enough == lightBg: lo = mid else: hi = mid
  fromHsl(h, s, (lo + hi) / 2)

func breakInk(t: Theme; background: Rgba): (Rgba, Rgba) =
  ## The overlay's two bars on `background`: the model's strong (deep on
  ## light, pale on dark), the pick's a mid tone, each in its role's hue.
  (tuned(t.roles[rlBreakModel], background, DeepContrast),
   tuned(t.roles[rlBreakPick], background, VividContrast))

func inkOf(t: Theme; d: DisplaySettings): PlotInk =
  let paper = PlotInk(background: PaperBackground, wiggle: WiggleInk(line: PaperInk,
    positive: PaperInk, negative: readableOn(t.roles[rlFillNegative], PaperBackground),
    hover: readableOn(t.roles[rlHighlight], PaperBackground),
    selected: readableOn(t.roles[rlSelected], PaperBackground)))
  case d.colours
  of pcPaper:
    result = paper
    (result.breakModel, result.breakPick) = breakInk(t, paper.background)
  of pcTheme:
    let bg = opaque(t.roles[rlPlotBackground])
    result = PlotInk(background: bg, wiggle: WiggleInk(line: opaque(t.roles[rlTrace]),
      positive: opaque(t.roles[rlFillPositive]), negative: opaque(t.roles[rlFillNegative]),
      hover: readableOn(opaque(t.roles[rlHighlight]), bg),
      selected: readableOn(opaque(t.roles[rlSelected]), bg)))
    (result.breakModel, result.breakPick) = breakInk(t, bg)
  of pcCustom:
    func pick(c, fallback: Rgba): Rgba = (if c.a == 0: fallback else: opaque(c))
    let c = d.custom
    result = PlotInk(background: pick(c.background, paper.background), wiggle: WiggleInk(
      line: pick(c.line, paper.wiggle.line), positive: pick(c.positive, paper.wiggle.positive),
      negative: pick(c.negative, paper.wiggle.negative),
      hover: pick(c.hover, paper.wiggle.hover), selected: pick(c.selected, paper.wiggle.selected)))
    (result.breakModel, result.breakPick) = breakInk(t, result.background)
  of pcRedPaper:
    result = paper
    result.wiggle.line = paper.wiggle.negative
    result.wiggle.positive = paper.wiggle.negative
    result.wiggle.negative = paper.wiggle.line
    (result.breakModel, result.breakPick) = breakInk(t, paper.background)

func plotInk*(t: Theme; d: DisplaySettings): PlotInk =
  ## The colours of a layer drawn with `d` in theme `t`; the overlay's bars in the
  ## colours the user chose, as chosen, else in the theme's, tuned to read.
  result = inkOf(t, d)
  if d.breakModelColour.a != 0: result.breakModel = opaque(d.breakModelColour)
  if d.breakPickColour.a != 0: result.breakPick = opaque(d.breakPickColour)

func drawnComponentColours*(stored: array[4, Rgba]; background: Rgba): array[4, Rgba] =
  ## `stored` (hydrophone, vertical, inline, crossline) darkened or lightened
  ## just enough to read on `background`. A shade that already does is unchanged.
  for i, c in stored:
    result[i] = readableOn(opaque(c), background)

func customOf*(ink: PlotInk): CustomColours =
  ## `ink` as custom colours: where the user starts from when choosing
  ## their own.
  CustomColours(background: ink.background, line: ink.wiggle.line,
    positive: ink.wiggle.positive, negative: ink.wiggle.negative, hover: ink.wiggle.hover,
    selected: ink.wiggle.selected)
