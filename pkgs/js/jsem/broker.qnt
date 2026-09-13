// src/broker.cc: tick = Broker::Tick, finish = ~Broker, acquire/release = ghc.
// single (src/main.cc) is safe, current and bounded (a broker per ghc) over-admit:
//   quint verify broker.qnt --main single --invariant safe --inductive-invariant inv
//   quint run broker.qnt --main current --invariant safe
module broker {
  const B: int      // brokers (one per `jsem ghc` cabal has in flight)
  const C: int      // tokens cabal created the semaphore with
  const D: int      // jigd slots available to this build
  const FIXED: bool  // drain bounded by own contribution vs drain all (current)
  const SINGLE: bool // one broker per semaphore (wrapping cabal), the other indices are bare ghcs

  var sem: int              // the named semaphore's count
  var held: int -> int      // broker -> daemon slots it holds
  var running: int -> int   // broker's ghc -> extra capabilities it took from the semaphore
  var done: int -> bool     // broker's ghc exited, broker destructed

  val brokers = 0.to(B - 1)
  def sum(m: int -> int): int = brokers.fold(0, (a, b) => a + m.get(b))
  def min(a: int, b: int): int = if (a < b) a else b
  val freeSlots = D - sum(held)

  action init = all {
    sem' = C,
    held' = brokers.mapBy(_ => 0),
    running' = brokers.mapBy(_ => 0),
    done' = brokers.mapBy(_ => false),
  }

  // ghc sem_wait for one more capability
  action acquire(b) = all {
    not(done.get(b)), sem > 0,
    sem' = sem - 1, running' = running.set(b, running.get(b) + 1),
    held' = held, done' = done,
  }
  // ghc gives one back
  action release(b) = all {
    not(done.get(b)), running.get(b) > 0,
    sem' = sem + 1, running' = running.set(b, running.get(b) - 1),
    held' = held, done' = done,
  }

  // Broker::Tick; an order is granted at once when jigd has a free slot
  action tick(b) = {
    val h = held.get(b)
    val idle = if (FIXED) min(sem, h) else sem
    val inUse = h - min(h, idle)
    val h1 = min(h, inUse + 1)
    val spare = h1 == inUse + 1
    val granted = if (not(spare) and freeSlots - (h - h1) > 0) 1 else 0
    val h2 = h1 + granted
    val post = if (h2 > inUse) 1 else 0
    all {
      not(done.get(b)), not(SINGLE) or b == 0,
      sem' = sem - idle + post,
      held' = held.set(b, h2),
      running' = running, done' = done,
    }
  }

  // ~Broker
  action finish(b) = {
    val h = held.get(b)
    // SINGLE: the broker goes last, cabal's tokens die with the semaphore (modelled as restored)
    val last = brokers.forall(o => o == b or done.get(o))
    val take = min(sem, h)
    all {
      not(done.get(b)), running.get(b) == 0, not(SINGLE) or b != 0 or last,
      sem' = if (SINGLE and b == 0) C else sem - take,
      held' = held.set(b, 0),
      done' = done.set(b, true),
      running' = running,
    }
  }

  action step = {
    nondet b = brokers.oneOf()
    any { acquire(b), release(b), tick(b), finish(b) }
  }

  // every capability in use or on offer is backed by cabal's tokens or a held slot
  val noOverAdmission = sem + sum(running) <= C + sum(held)
  // cabal's tokens survive the brokers
  val conserved = brokers.forall(b => done.get(b)) implies sem == C
  val safe = noOverAdmission and conserved

  // inductive invariant for SINGLE; apalache wants every variable bound by .in() first
  val N = 0.to(2 * (C + D + B))
  val inv = and {
    sem.in(N),
    held.in(brokers.setOfMaps(N)),
    running.in(brokers.setOfMaps(N)),
    done.in(brokers.setOfMaps(Set(true, false))),
    sum(held) <= D,
    brokers.forall(b => b != 0 implies held.get(b) == 0),
    brokers.forall(b => done.get(b) implies running.get(b) == 0),
    done.get(0) implies brokers.forall(b => done.get(b)),
    safe,
  }
}

module current { import broker(B = 2, C = 2, D = 2, FIXED = false, SINGLE = false).* }
module bounded { import broker(B = 2, C = 2, D = 2, FIXED = true, SINGLE = false).* }
module single  { import broker(B = 3, C = 2, D = 2, FIXED = false, SINGLE = true).* }
