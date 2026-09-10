package main

import (
	"testing"
	"time"
)

// with the pool exhausted, the build holding fewer tokens is woken first, whatever the arrival order
func TestSlotsFewestHeldFirst(t *testing.T) {
	s := NewSlots(2)
	s.Acquire("big")
	s.Acquire("big")
	order := make(chan string, 2)
	go func() { s.Acquire("big"); order <- "big" }()
	time.Sleep(10 * time.Millisecond) // big queues first
	go func() { s.Acquire("small"); order <- "small" }()
	time.Sleep(10 * time.Millisecond)
	if out, waiting := s.Stats(); out != 2 || waiting != 2 {
		t.Fatalf("out=%d waiting=%d", out, waiting)
	}
	s.Release("big")
	if first := <-order; first != "small" {
		t.Fatalf("woken first: %s", first)
	}
	s.Release("big")
	if <-order != "big" {
		t.Fatal()
	}
}
