## A small cache of correlation plans, one per record, bounded by bytes.
##
## A pilot correlation takes each record's reference from that record, so each
## record has its own plan (the pilot's spectrum and the FFT). When the traces
## of several records are written in turn, a cache keeps the plans used last,
## and the least recently used goes first when the total passes the bound. A
## plan the cache no longer holds is built again, so the cache changes how often
## a plan is built, never what it holds.

import processSEG

type
  PlanEntry = object
    record: int
    plan: CorrelationPlan[float32]
    bytes: int
    used: int64

  PlanCache* = object
    ## Plans by record, least recently used evicted first.
    limit: int ## bytes
    total: int
    tick: int64
    entries: seq[PlanEntry]

func planBytes*(plan: CorrelationPlan[float32]): int =
  ## The memory a plan holds, estimated: the FFT's tables and the multiplier are
  ## each a few arrays of the transform length (record plus pilot plus padding).
  16 * (plan.recordSamples + plan.pilotSamples + 64)

func initPlanCache*(limitBytes: int): PlanCache =
  ## An empty cache that keeps its plans within `limitBytes` (one plan always
  ## stays, however large).
  PlanCache(limit: limitBytes)

func find*(cache: var PlanCache; record: int): int =
  ## The index of `record`'s plan, marked as just used, or -1.
  result = -1
  for i in 0 ..< cache.entries.len:
    if cache.entries[i].record == record:
      inc cache.tick
      cache.entries[i].used = cache.tick
      return i

func plan*(cache: PlanCache; at: int): lent CorrelationPlan[float32] =
  ## The plan at the index `find` or `put` returned, until the next `put`.
  cache.entries[at].plan

func put*(cache: var PlanCache; record: int; plan: sink CorrelationPlan[float32]): int =
  ## Keeps `plan` for `record` (which `find` did not find) as the most recently
  ## used, drops the least recently used until the total fits, and returns its index.
  let bytes = planBytes(plan)
  inc cache.tick
  cache.entries.add PlanEntry(record: record, plan: plan, bytes: bytes, used: cache.tick)
  cache.total += bytes
  while cache.total > cache.limit and cache.entries.len > 1:
    var oldest = 0
    for i in 1 ..< cache.entries.len:
      if cache.entries[i].used < cache.entries[oldest].used: oldest = i
    if cache.entries[oldest].used == cache.tick: break
    cache.total -= cache.entries[oldest].bytes
    cache.entries.delete oldest
  result = 0
  for i in 0 ..< cache.entries.len:
    if cache.entries[i].used == cache.tick: result = i

func len*(cache: PlanCache): int = cache.entries.len
  ## The plans held.

func bytes*(cache: PlanCache): int = cache.total
  ## The estimated memory of the plans held.
