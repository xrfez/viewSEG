## The jobs of a reference archive. Each runs off the UI thread: a reference
## is a file, and the trace it is stored from is read from a seismic file.
## What they find is posted as `mkReferences`.

import std/[os, strutils]
import parseSEG
import filesystem, inbox, jobs, references, threads

proc post(to: Poster; job: JobId; news: ReferenceNews) =
  clearCycleRoots()
  to.post Msg(job: job, kind: mkReferences, refNews: news)

proc failed(to: Poster; job: JobId; home, msg: string; main = false) =
  var news = ReferenceNews(home: home, main: main, act: raFailed, failure: msg)
  try:
    news.index = loadIndex(home)
  except CatchableError:
    discard
  post(to, job, news)

proc listWork*(folder: string; main: bool; to: Poster): JobWork =
  ## Reads the archive in `folder`.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the reference archive"
    var news = ReferenceNews(home: folder, main: main, act: raListed)
    try:
      news.index = loadIndex(folder)
      if news.index.problems.len > 0:
        news.failure = news.index.problems.join("; ")
    except CatchableError as e:
      news.act = raFailed
      news.failure = e.msg
    post(to, ctx.id, news)

proc storeWork*(file: ptr SeismicFile; path: string; size: int64; trace: int;
    fromMs, toMs, intervalUs, record: float64; fileName, name, folder: string;
    traceShown: int; to: Poster): JobWork =
  ## Reads trace `trace` of the open file raw (no filter, gain or polarity),
  ## cuts it to `fromMs` .. `toMs` (`toMs` below 0: the trace's end) and
  ## stores it in the archive `folder`.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the trace"
    try:
      if size >= 0 and fs.getFileInfo(path).size < size:
        raise newException(IOError, "the file is shorter than when it was opened")
      var samples: seq[float32] = @[]
      var us = intervalUs
      {.cast(gcsafe).}:
        samples = readRawTrace(file, path, trace)
        if not (us > 0 and us < Inf):
          let k = file[].traceKeys(trace)
          us = if k.intervalUs > 0 and k.intervalUs < Inf: k.intervalUs
               else: file[].sampleIntervalUs(trace)
      if samples.len == 0:
        raise newException(IOError, "the trace could not be read")
      if not (us > 0 and us < Inf):
        raise newException(ValueError, "the trace has no sample interval")
      let cut = cutSamples(samples, us, fromMs, toMs)
      if cut.len == 0:
        raise newException(ValueError, "the window holds no sample")
      let dt = us / 1000
      let usedFrom = max(fromMs, 0.0)
      let usedTo = if toMs < 0: float64(samples.len - 1) * dt
                   else: min(toMs, float64(samples.len - 1) * dt)
      let origin = ReferenceOrigin(generated: false, fileName: fileName, record: record,
        trace: traceShown, fromMs: usedFrom, toMs: usedTo)
      ctx.setPhase "storing the reference"
      let id = storeSamples(folder, name, us, cut, origin)
      var news = ReferenceNews(home: folder, act: raStored, id: id, name: name.strip,
        index: loadIndex(folder))
      post(to, ctx.id, news)
    except CatchableError as e:
      failed(to, ctx.id, folder, e.msg)

proc generateWork*(g: GeneratedReference; folder: string; to: Poster): JobWork =
  ## Makes the sweep `g` names and stores it. A sweep too long for
  ## processSEG is refused before any sample is made.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "generating the reference"
    try:
      let tooLong = sweepTooLong(g)
      if tooLong.len > 0:
        raise newException(ValueError, tooLong)
      let samples = generateSamples(g)
      let name = if g.name.strip.len > 0: g.name.strip else: defaultGenerateName(g)
      let origin = ReferenceOrigin(generated: true, law: g.law, f1Hz: g.f1Hz, f2Hz: g.f2Hz,
        durationMs: g.durationMs, dtMs: g.dtMs, taperStartMs: max(g.taperStartMs, 0.0),
        taperEndMs: max(g.taperEndMs, 0.0), taperShape: g.taperShape,
        taperParam: g.taperParam, phaseDeg: g.phaseDeg,
        amplitude: (if g.amplitude > 0: g.amplitude else: 1.0), boostDb: g.boostDb)
      let id = storeSamples(folder, name, g.dtMs * 1000, samples, origin)
      var news = ReferenceNews(home: folder, act: raGenerated, id: id, name: name,
        index: loadIndex(folder))
      post(to, ctx.id, news)
    except CatchableError as e:
      failed(to, ctx.id, folder, e.msg)

proc renameWork*(folder, id, name: string; to: Poster): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "renaming the reference"
    try:
      renameIn(folder, id, name)
      var news = ReferenceNews(home: folder, act: raRenamed, id: id, name: name.strip,
        index: loadIndex(folder))
      post(to, ctx.id, news)
    except CatchableError as e:
      failed(to, ctx.id, folder, e.msg)

proc deleteWork*(folder, id: string; to: Poster): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "deleting the reference"
    try:
      let name = deleteIn(folder, id)
      var news = ReferenceNews(home: folder, act: raDeleted, id: id, name: name,
        index: loadIndex(folder))
      post(to, ctx.id, news)
    except CatchableError as e:
      failed(to, ctx.id, folder, e.msg)

proc viewWork*(folder, file, id, name: string; window: int; fromMs: float64;
    to: Poster): JobWork =
  ## Reads one reference and its amplitude spectrum, for its window.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the reference"
    try:
      if not singleFileName(file):
        raise newException(ValueError, "the reference names a file outside the archive")
      let (samples, us) = readReferenceFile(folder / file)
      if samples.len == 0:
        raise newException(ValueError, "the reference file has no sample")
      let dt = if us > 0: us / 1000 else: 0.0
      let spec = amplitudeOf(samples, dt)
      var ys = newSeq[float64](samples.len)
      for i, v in samples: ys[i] = float64(v)
      var news = ReferenceNews(home: folder, act: raViewed, id: id, name: name,
        window: window, fromMs: fromMs, dtMs: dt, ys: ys, hz: spec.hz, amps: spec.amp,
        index: loadIndex(folder))
      post(to, ctx.id, news)
    except CatchableError as e:
      var news = ReferenceNews(home: folder, act: raFailed, id: id, name: name,
        window: window, failure: e.msg)
      post(to, ctx.id, news)

proc copyWork*(fromFolder, toFolder, id: string; to: Poster): JobWork =
  ## Copies a reference of the main archive into the project's.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "copying the reference"
    try:
      let newId = copyInto(fromFolder, toFolder, id)
      let index = loadIndex(toFolder)
      let i = index.findId(newId)
      let name = if i >= 0: index.entries[i].name else: ""
      var news = ReferenceNews(home: toFolder, act: raCopied, id: newId, name: name,
        index: index)
      post(to, ctx.id, news)
    except CatchableError as e:
      failed(to, ctx.id, toFolder, e.msg)

proc pilotRuleWork*(rule: PilotRule; folder: string; to: Poster): JobWork =
  ## Stores the rule `rule` names (no sample is read).
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "storing the pilot reference"
    try:
      let name = if rule.name.strip.len > 0: rule.name.strip else: defaultPilotName(rule)
      let id = storePilotRule(folder, rule)
      var news = ReferenceNews(home: folder, act: raRuleStored, id: id, name: name,
        index: loadIndex(folder))
      post(to, ctx.id, news)
    except CatchableError as e:
      failed(to, ctx.id, folder, e.msg)

proc pilotWork*(file: ptr SeismicFile; path: string; size: int64; trace: int;
    rule: PilotRule; flip: bool; record: string; surveyTrace, window: int;
    key, name, folder: string; to: Poster): JobWork =
  ## Reads trace `trace` of the open file raw, turns it over when `flip` (its
  ## polarity as the plot shows it: the trace's own reversal or reverse-all),
  ## and cuts the window `rule` names. For a reference window (`window` above
  ## 0) it posts `raViewed`; else `raPilotShown` for the Generate dialog's
  ## preview, with the amplitude spectrum in dB in `amps`. A trace or window that
  ## is not there is said in `failure`.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the pilot"
    let preview = window <= 0
    var news = ReferenceNews(home: folder, act: (if preview: raPilotShown else: raViewed),
      key: key, name: name, window: window, record: record, pilotTrace: -1)
    try:
      if size >= 0 and fs.getFileInfo(path).size < size:
        raise newException(IOError, "the file is shorter than when it was opened")
      var samples: seq[float32] = @[]
      var us = 0.0
      {.cast(gcsafe).}:
        samples = readRawTrace(file, path, trace)
        let k = file[].traceKeys(trace)
        us = if k.intervalUs > 0 and k.intervalUs < Inf: k.intervalUs
             else: file[].sampleIntervalUs(trace)
      if samples.len == 0:
        raise newException(IOError, "the trace could not be read")
      if flip:
        for v in samples.mitems: v = -v
      let dt = if us > 0 and us < Inf: us / 1000 else: 0.0
      let (cut, problem) = cutPilot(samples, dt, rule, record)
      if problem.len > 0:
        news.failure = problem
      else:
        news.dtMs = dt
        news.fromMs = max(rule.startMs, 0.0)
        news.pilotTrace = surveyTrace
        news.pilotTraceMs = float64(samples.len - 1) * dt
        news.pilotFrom = news.fromMs
        news.pilotTo = news.fromMs + float64(cut.len - 1) * dt
        if preview:
          let spec = previewSpectrum(cut, dt)
          news.hz = spec.hz
          news.amps = spec.db
          news.ys = newSeq[float64](cut.len)
          for i, v in cut: news.ys[i] = float64(v)
        else:
          let spec = amplitudeOf(cut, dt)
          news.hz = spec.hz
          news.amps = spec.amp
          news.ys = newSeq[float64](cut.len)
          for i, v in cut: news.ys[i] = float64(v)
    except CatchableError as e:
      news.failure = e.msg
    post(to, ctx.id, news)
