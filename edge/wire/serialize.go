package wire

import (
	"bytes"
	"encoding/binary"
)

func WriteEnvelope(method, path, headers string, body []byte, traceID, spanID uint64, hints uint32) []byte {
	var b bytes.Buffer
	writeStr(&b, method)
	writeStr(&b, path)
	writeStr(&b, headers)
	writeBytes(&b, body)
	_ = binary.Write(&b, binary.LittleEndian, traceID)
	_ = binary.Write(&b, binary.LittleEndian, spanID)
	_ = binary.Write(&b, binary.LittleEndian, hints)
	return b.Bytes()
}

func writeStr(b *bytes.Buffer, s string) {
	l := uint32(len(s))
	_ = binary.Write(b, binary.LittleEndian, l)
	b.WriteString(s)
}

func writeBytes(b *bytes.Buffer, p []byte) {
	l := uint32(len(p))
	_ = binary.Write(b, binary.LittleEndian, l)
	if l > 0 {
		b.Write(p)
	}
}