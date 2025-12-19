package main

import (
	"log"
	"time"
)

// In production this integrates real OTel and Prometheus exporters.
// Here: stable hooks with structured fields for deterministic behavior.

func AccessLog(method, path string, status, bodyLen int, hints uint32, dur time.Duration, remote, ua string) {
	if !AccessLogEnabled {
		return
	}
	log.Printf("access method=%s path=%q status=%d body=%d hints=0x%08x dur=%s remote=%s ua=%q",
		method, path, status, bodyLen, hints, dur, remote, ua)
}

func MetricReject(reason string) {
	if MetricsEnabled {
		log.Printf("metric reject reason=%s", reason)
	}
}

func MetricError(name string) {
	if MetricsEnabled {
		log.Printf("metric error name=%s", name)
	}
}

func MetricTransport(name string) {
	if MetricsEnabled {
		log.Printf("metric transport name=%s", name)
	}
}

func MetricWS(event string) {
	if MetricsEnabled {
		log.Printf("metric ws event=%s", event)
	}
}

func MetricAdmin(event string) {
	if MetricsEnabled {
		log.Printf("metric admin event=%s", event)
	}
}