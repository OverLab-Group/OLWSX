package main

import (
	"net"
	"sync"
	"time"
)

type bucket struct {
	tokens int
	last   time.Time
}

var (
	mu      sync.Mutex
	buckets = map[string]*bucket{}
)

// Limited returns true if the IP is limited (true means limit applied).
func Limited(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	now := time.Now()
	mu.Lock()
	b, ok := buckets[host]
	if !ok {
		b = &bucket{tokens: BucketCapacity, last: now}
		buckets[host] = b
	} else {
		elapsed := int(now.Sub(b.last).Seconds())
		if elapsed > 0 {
			b.tokens += elapsed * RefillPerSecond
			if b.tokens > BucketCapacity {
				b.tokens = BucketCapacity
			}
			b.last = now
		}
	}
	if b.tokens > 0 {
		b.tokens--
		mu.Unlock()
		return false
	}
	mu.Unlock()
	return true
}