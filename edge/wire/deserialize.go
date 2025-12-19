package wire

import (
	"bytes"
	"encoding/binary"
	"errors"
)

type Response struct {
	Status      int32
	HeadersFlat string
	Body        []byte
	MetaFlags   uint32
}

func ReadResponse(p []byte) (Response, error) {
	var out Response
	r := bytes.NewReader(p)
	var status int32
	if err := binary.Read(r, binary.LittleEndian, &status); err != nil {
		return out, err
	}
	hdr, err := readStr(r)
	if err != nil {
		return out, err
	}
	body, err := readBytes(r)
	if err != nil {
		return out, err
	}
	var meta uint32
	if err := binary.Read(r, binary.LittleEndian, &meta); err != nil {
		return out, err
	}
	out.Status = status
	out.HeadersFlat = hdr
	out.Body = body
	out.MetaFlags = meta
	return out, nil
}

func readStr(r *bytes.Reader) (string, error) {
	var l uint32
	if err := binary.Read(r, binary.LittleEndian, &l); err != nil {
		return "", err
	}
	if l == 0 {
		return "", nil
	}
	buf := make([]byte, l)
	n, err := r.Read(buf)
	if err != nil || uint32(n) != l {
		return "", errors.New("short read")
	}
	return string(buf), nil
}

func readBytes(r *bytes.Reader) ([]byte, error) {
	var l uint32
	if err := binary.Read(r, binary.LittleEndian, &l); err != nil {
		return nil, err
	}
	if l == 0 {
		return nil, nil
	}
	buf := make([]byte, l)
	n, err := r.Read(buf)
	if err != nil || uint32(n) != l {
		return nil, errors.New("short read")
	}
	return buf, nil
}