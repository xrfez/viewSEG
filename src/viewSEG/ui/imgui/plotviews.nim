## The plots opened on the Seismic window's selected traces: one table, so
## the toolbar, Window > New plot and the plot's right-click menu name them,
## icon them and describe them the same way.

import ../../core/analysis
import icons

export AnalysisView

type
  PlotEntry* = object
    ## One plot the toolbar and the menus offer.
    fft*: bool          ## the FFT window, not a New plot view
    view*: AnalysisView ## a New plot view; unused when `fft`
    icon*: string
    sentence*: string   ## one short sentence of what it shows
    shortcut*: string   ## as shown ("F"); "" for none

const
  SelectTracesFirst* = "Select traces in the Seismic window first (or right-click one there)."
    ## The toolbar's tooltip ends with this while no trace is selected, and
    ## Window > New plot says it then.
  PlotEntries* = [
    PlotEntry(fft: true, icon: IconFft, shortcut: "F",
      sentence: "The amplitude spectrum of the selected traces, raw and through the filters."),
    PlotEntry(view: avSpectrogram, icon: IconSpectrogram,
      sentence: "Amplitude against time and frequency, in dB."),
    PlotEntry(view: avEnvelope, icon: IconEnvelope,
      sentence: "The trace, its envelope, and its instantaneous phase."),
    PlotEntry(view: avPhase, icon: IconPhase,
      sentence: "Amplitude and phase against frequency."),
    PlotEntry(view: avCorrelation, icon: IconCorrelation,
      sentence: "Each selected trace against the chosen reference, by lag and by frequency."),
    PlotEntry(view: avVibrator, icon: IconVibrator,
      sentence: "A unit's reference, ground force, mass and baseplate through the sweep."),
    PlotEntry(view: avFk, icon: IconFk,
      sentence: "Amplitude against frequency and wavenumber.")]
    ## FFT, then Window > New plot's views, in that menu's order.

func name*(e: PlotEntry): string =
  ## What the menus and the toolbar call `e`.
  if e.fft: "FFT" else: e.view.viewName

func entry*(v: AnalysisView): PlotEntry =
  ## The table's row for New plot view `v`.
  for e in PlotEntries:
    if not e.fft and e.view == v: return e
  raiseAssert "no plot entry for " & $v

func fftEntry*(): PlotEntry =
  ## The table's FFT row.
  PlotEntries[0]

func tip*(e: PlotEntry; enabled: bool): string =
  ## The toolbar tooltip: the name, what it shows, the shortcut ("Shortcut: F"),
  ## and, when no trace is selected, what to do first. That last sentence
  ## always ends the text, so the shortcut comes before it.
  result = e.name & "\n" & e.sentence
  if e.shortcut.len > 0: result.add "\nShortcut: " & e.shortcut
  if not enabled: result.add "\n" & SelectTracesFirst
