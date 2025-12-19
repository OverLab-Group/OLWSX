package main

import (
	"crypto/sha256"
	"encoding/binary"
	"time"
)

// Proof-of-work lite: deterministic hash requirement based on current time window to avoid replay.
func Challenge(remote string) bool {
	if !EnableChallenge {
		return false
	}
	// Windowed nonce: second bucket
	sec := uint64(time.Now().Unix())
	var nonce [16]byte
	binary.LittleEndian.PutUint64(nonce[:8], sec)
	binary.LittleEndian.PutUint64(nonce[8:], uint64(len(remote)))
	h := sha256.Sum256(nonce[:])
	// Require low difficulty (first byte == 0). Can be adjusted if needed.
	return h[0] == 0
}