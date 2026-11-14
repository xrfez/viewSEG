## The plot's colours, from the theme's roles, for each of the plot's
## colour schemes (`PlotColours`): the background, the wiggle line and its
## fills, and the colours of a hovered and of a selected trace.
##
## - **Paper** (the default): white, black line and positive fill, the
##   theme's red for the negative fill, whatever the theme.
## - **Follow the theme:** the theme's plot background, its trace and fill
##   roles.
## - **Custom:** the colours the user chose (`CustomColours`); one not
##   chosen yet is paper's.
##
## A hovered trace takes the theme's highlight colour (orange, the colour
## of the linked selection) and a selected one its accent (the colour of a
## selected button), each made dark or light enough to read on the
## background (`readableOn`), so a highlight stands out on paper and on a
## dark plot alike, and the two never look alike.

import ../core/[geometry, panels, wiggle]
import theme

const
  PaperBackground* = Rgba(r: 255, g: 255, b: 255, a: 255)
  PaperInk* = Rgba(r: 0, g: 0, b: 0, a: 255)
  MinContrast* = 3.0
    ## the contrast a highlight keeps against the background (WCAG's ratio
    ## for graphics)
  DensityTint* = 0.55'f32
    ## how far a hovered or selected trace's column is tinted under density

type
  PlotInk* = object
    ## The colours a plot is drawn in.
    background*: Rgba
    wiggle*: WiggleInk

func readableOn*(c, background: Rgba; ratio = MinContrast): Rgba =
  ## `c`, darkened on a light background or lightened on a dark one, just
  ## enough to stand out from `background` by `ratio` (as far as black or
  ## white allows).
  let target = if luminance(background) > 0.18: PaperInk else: PaperBackground
  result = c
  var t = 0'f32
  while contrast(result, background) < ratio and t < 1:
    t += 0.05
    result = mix(c, target, t)

func opaque(c: Rgba): Rgba {.inline.} = Rgba(r: c.r, g: c.g, b: c.b, a: 255)

func plotInk*(t: Theme; d: DisplaySettings): PlotInk =
  ## The colours of a layer drawn with `d` in theme `t`.
  let paper = PlotInk(background: PaperBackground, wiggle: WiggleInk(line: PaperInk,
    positive: PaperInk, negative: readableOn(t.roles[rlFillNegative], PaperBackground),
    hover: readableOn(t.roles[rlHighlight], PaperBackground),
    selected: readableOn(t.roles[rlAccent], PaperBackground)))
  case d.colours
  of pcPaper: paper
  of pcTheme:
    let bg = opaque(t.roles[rlPlotBackground])
    PlotInk(background: bg, wiggle: WiggleInk(line: opaque(t.roles[rlTrace]),
      positive: opaque(t.roles[rlFillPositive]), negative: opaque(t.roles[rlFillNegative]),
      hover: readableOn(opaque(t.roles[rlHighlight]), bg),
      selected: readableOn(opaque(t.roles[rlAccent]), bg)))
  of pcCustom:
    func pick(c, fallback: Rgba): Rgba = (if c.a == 0: fallback else: opaque(c))
    let c = d.custom
    PlotInk(background: pick(c.background, paper.background), wiggle: WiggleInk(
      line: pick(c.line, paper.wiggle.line), positive: pick(c.positive, paper.wiggle.positive),
      negative: pick(c.negative, paper.wiggle.negative),
      hover: pick(c.hover, paper.wiggle.hover), selected: pick(c.selected, paper.wiggle.selected)))

func customOf*(ink: PlotInk): CustomColours =
  ## `ink` as custom colours: where the user starts from when choosing
  ## their own.
  CustomColours(background: ink.background, line: ink.wiggle.line,
    positive: ink.wiggle.positive, negative: ink.wiggle.negative, hover: ink.wiggle.hover,
    selected: ink.wiggle.selected)
