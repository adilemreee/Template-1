package httpapi

import (
	"bytes"
	"compress/gzip"
	"io"
	"sync"
	"time"
)

func gunzip(b []byte) []byte {
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil
	}
	out, _ := io.ReadAll(zr)
	return out
}

// ipLimiter is a fixed-window request counter per client IP.
type ipLimiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	start  time.Time
	counts map[string]int
}

func newIPLimiter(limit int, window time.Duration) *ipLimiter {
	return &ipLimiter{limit: limit, window: window, start: time.Now(), counts: map[string]int{}}
}

func (l *ipLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if time.Since(l.start) > l.window {
		l.start = time.Now()
		clear(l.counts)
	}
	l.counts[ip]++
	return l.counts[ip] <= l.limit
}
