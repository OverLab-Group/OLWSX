package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	edgehttp "olwsx/edge/http"
	edgequic "olwsx/edge/quic"
	edgetls "olwsx/edge/tls"
	edgews "olwsx/edge/websocket"
	"olwsx/edge/wire"

	admin "olwsx/edge/admin"
)

// newIDs creates 128-bit trace/span IDs deterministically random.
func newIDs() (uint64, uint64) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		now := time.Now().UnixNano()
		binary.LittleEndian.PutUint64(buf[:8], uint64(now))
		binary.LittleEndian.PutUint64(buf[8:], uint64(now>>11))
	}
	return binary.LittleEndian.Uint64(buf[:8]), binary.LittleEndian.Uint64(buf[8:])
}

// coreCall bridges edge to Actor Manager via Unix domain socket.
// Edge forms a stable envelope and expects a binary response using wire.Response layout.
func coreCall(method, path, headers string, body []byte, traceID, spanID uint64, hints uint32) (edgehttp.CoreResp, int) {
	// Ensure socket exists
	sock := ActorManagerSocket
	if sock == "" {
		return edgehttp.CoreResp{}, 1
	}
	conn, err := net.Dial("unix", sock)
	if err != nil {
		log.Printf("actor dial error: %v", err)
		return edgehttp.CoreResp{}, 2
	}
	defer conn.Close()

	// Write envelope
	env := wire.WriteEnvelope(method, path, headers, body, traceID, spanID, hints)
	if _, err := conn.Write(env); err != nil {
		log.Printf("actor write error: %v", err)
		return edgehttp.CoreResp{}, 3
	}

	// Read response (length-prefixed frame)
	// For simplicity we read until EOF; in production, frame length should be prefixed.
	buf := make([]byte, 1<<20) // 1MB temp buffer; actor should respect edge limits
	n, err := conn.Read(buf)
	if err != nil && n == 0 {
		log.Printf("actor read error: %v", err)
		return edgehttp.CoreResp{}, 4
	}
	resp, err := wire.ReadResponse(buf[:n])
	if err != nil {
		log.Printf("actor parse error: %v", err)
		return edgehttp.CoreResp{}, 5
	}
	return edgehttp.CoreResp{
		Status:      int(resp.Status),
		HeadersFlat: resp.HeadersFlat,
		Body:        resp.Body,
		MetaFlags:   resp.MetaFlags,
	}, 0
}

func main() {
	// Ensure socket directory exists (edge doesn't create actor socket, only path directory)
	if dir := filepath.Dir(ActorManagerSocket); dir != "" {
		_ = os.MkdirAll(dir, 0755)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
		<-ch
		cancel()
	}()

	// TLS config
	cert, err := edgetls.LoadOrSelfSign("server.crt", "server.key")
	if err != nil {
		log.Fatalf("TLS cert load failed: %v", err)
	}
	tlsCfg := edgetls.ServerConfig(cert, TLSMinVersion13)

	// Handler wiring
	handler := edgehttp.Handler(
		MaxHeaderBytes,
		MaxBodyBytes,
		Limited,
		func(path, ua string) bool { return Blocked(path, ua) },
		func(remote string) bool { return Challenge(remote) },
		coreCall,
		newIDs,
		AccessLog,
		MetricReject,
		MetricError,
	)

	// HTTP/1.1 + HTTP/2
	srv := edgehttp.NewH2H1Server(handler, MaxHeaderBytes, edgehttp.Timeouts{
		Read:       ReadTimeout,
		Write:      WriteTimeout,
		Idle:       IdleTimeout,
		ReadHeader: ReadHeaderTO,
	})

	ln, err := edgetls.ListenTLS("tcp", TLSListenAddr, tlsCfg)
	if err != nil {
		log.Fatalf("TLS listen failed: %v", err)
	}
	defer ln.Close()

	go func() {
		MetricTransport("h2_h1_tls")
		log.Printf("Edge serving TLS (ALPN: h2,http/1.1) at https://0.0.0.0%s", TLSListenAddr)
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Fatalf("HTTP server error: %v", err)
		}
	}()

	// HTTP/3 QUIC
	if EnableHTTP3 {
		go edgequic.ListenAndServe(TLSListenAddr, tlsCfg, handler)
	}

	// WebSocket/SSE
	go edgews.ListenAndServe(WSListenAddr)

	// Admin health + metrics
	go admin.ListenAndServe(AdminListenAddr, admin.HealthHandler, admin.MetricsHandler)

	<-ctx.Done()
	log.Println("Shutting down edge...")
	shutdownCtx, cancelSD := context.WithTimeout(context.Background(), ShutdownTimeout)
	defer cancelSD()
	_ = srv.Shutdown(shutdownCtx)
	log.Println("Edge shutdown complete.")
	fmt.Println("") // flush newline
}