// Host-wide admission for real compiler runs. jig sends `SLOT <build>` before it execs a
// compiler or linker (cache miss or uncacheable, never for a hit) and `DONE` after. A token also
// dies with the connection. With several nix builds on one host, each `make -j$(nproc)`, this
// keeps the number of running compilers at `limit` instead of max-jobs × nproc. Among waiters
// the build holding the fewest tokens is served first, so one build's -j16 burst cannot starve
// another's serial configure probes (experiments: plain FIFO gave 7× tail slowdown).
package main

import "sync"

type waiter struct {
	build string
	ready chan struct{}
}

type Slots struct {
	mu      sync.Mutex
	limit   int
	out     int
	held    map[string]int // tokens per build
	waiting []*waiter
}

func NewSlots(limit int) *Slots {
	return &Slots{limit: limit, held: make(map[string]int)}
}

// Acquire blocks until `build` may run one more compiler.
func (s *Slots) Acquire(build string) {
	s.mu.Lock()
	if s.out < s.limit && len(s.waiting) == 0 {
		s.out++
		s.held[build]++
		s.mu.Unlock()
		return
	}
	w := &waiter{build: build, ready: make(chan struct{})}
	s.waiting = append(s.waiting, w)
	s.mu.Unlock()
	<-w.ready
}

func (s *Slots) Release(build string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.out--
	if s.held[build]--; s.held[build] <= 0 {
		delete(s.held, build)
	}
	s.grant()
}

// with mu held: wake waiters while tokens are free, fewest-held build first (FIFO among equals)
func (s *Slots) grant() {
	for s.out < s.limit && len(s.waiting) > 0 {
		best := 0
		for i, w := range s.waiting {
			if s.held[w.build] < s.held[s.waiting[best].build] {
				best = i
			}
		}
		w := s.waiting[best]
		s.waiting = append(s.waiting[:best], s.waiting[best+1:]...)
		s.out++
		s.held[w.build]++
		close(w.ready)
	}
}

func (s *Slots) Stats() (out, waiting int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.out, len(s.waiting)
}
