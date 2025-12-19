package http

import (
	stdhttp "net/http"
	"strings"
)

// Normalize extracts deterministic method, path, headersFlat and headerBytesCount.
func Normalize(r *stdhttp.Request, maxHeaderBytes int) (method, path, headersFlat string, hdrSize int) {
	method = r.Method
	path = r.URL.RequestURI()
	headersFlat, hdrSize = FlattenHeaders(r.Header)
	return
}

// FlattenHeaders returns "K: V\r\n" repeated and the total bytes length.
func FlattenHeaders(h stdhttp.Header) (string, int) {
	var b strings.Builder
	size := 0
	for k, vals := range h {
		for _, v := range vals {
			line := k + ": " + v + "\r\n"
			b.WriteString(line)
			size += len(line)
		}
	}
	return b.String(), size
}

// ParseFlat splits "K:V\r\n" to entries for response emission.
func ParseFlat(s string) []string {
	if s == "" {
		return nil
	}
	lines := strings.Split(s, "\r\n")
	out := make([]string, 0, len(lines))
	for _, ln := range lines {
		if ln == "" {
			continue
		}
		out = append(out, ln)
	}
	return out
}