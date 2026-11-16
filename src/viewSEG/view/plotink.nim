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
## of the linked selection) and a selected one its `selected` role (its
## accent, the colour of a selected button, unless that is too close to the
## traces), each made dark or light enough to read on the background
## (`readableOn`), so a highlight stands out on paper and on a dark plot
## alike; the theme keeps the two apart from the traces and from each other
## (`deriveRoles`).

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

func readableOn*(c, background: Rgba; ratio = MinContrast): Rgba {.inline.} =
  ## `c`, darkened on a light background or lightened on a dark one, just
  ## enough to stand out from `background` by `ratio` (as far as black or
  ## white allows).
  readable(c, background, ratio)

func opaque(c: Rgba): Rgba {.inline.} = Rgba(r: c.r, g: c.g, b: c.b, a: 255)

func plotInk*(t: Theme; d: DisplaySettings): PlotInk =
  ## The colours of a layer drawn with `d` in theme `t`.
  let paper = PlotInk(background: PaperBackground, wiggle: WiggleInk(line: PaperInk,
    positive: PaperInk, negative: readableOn(t.roles[rlFillNegative], PaperBackground),
    hover: readableOn(t.roles[rlHighlight], PaperBackground),
    selected: readableOn(t.roles[rlSelected], PaperBackground)))
  case d.colours
  of pcPaper: paper
  of pcTheme:
    let bg = opaque(t.roles[rlPlotBackground])
    PlotInk(background: bg, wiggle: WiggleInk(line: opaque(t.roles[rlTrace]),
      positive: opaque(t.roles[rlFillPositive]), negative: opaque(t.roles[rlFillNegative]),
      hover: readableOn(opaque(t.roles[rlHighlight]), bg),
      selected: readableOn(opaque(t.roles[rlSelected]), bg)))
  of pcCustom:
    func pick(c, fallback: Rgba): Rgba = (if c.a == 0: fallback else: opaque(c))
    let c = d.custom
    PlotInk(background: pick(c.background, paper.background), wiggle: WiggleInk(
      line: pick(c.line, paper.wiggle.line), positive: pick(c.positive, paper.wiggle.positive),
      negative: pick(c.negative, paper.wiggle.negative),
      hover: pick(c.hover, paper.wiggle.hover), selected: pick(c.selected, paper.wiggle.selected)))

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
