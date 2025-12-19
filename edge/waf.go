package main

import (
	"regexp"
	"strings"
)

var (
	pathTraversal = regexp.MustCompile(`(\.\./)|(/\.{2})`)
	uaBlacklist   = []string{"sqlmap", "nmap", "nikto", "wpscan", "masscan", "curl/", "wget"}
)

// Blocked returns true if path or UA is suspicious.
func Blocked(path, ua string) bool {
	if !EnableWAF {
		return false
	}
	if pathTraversal.MatchString(path) {
		return true
	}
	ua = strings.ToLower(ua)
	for _, sig := range uaBlacklist {
		if strings.Contains(ua, sig) {
			return true
		}
	}
	return false
}