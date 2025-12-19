package websocket

import (
	"log"
	"net/http"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	// TODO: add origin checks / auth gates if required by policy
	CheckOrigin: func(r *http.Request) bool { return true },
}

func ListenAndServe(addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", wsHandler)
	s := &http.Server{
		Addr:    addr,
		Handler: mux,
	}
	log.Printf("Edge WebSocket server on %s", addr)
	if err := s.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Printf("WS server error: %v", err)
	}
}

func wsHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("WebSocket upgrade error:", err)
		return
	}
	defer conn.Close()
	for {
		msgType, msg, err := conn.ReadMessage()
		if err != nil {
			break
		}
		// Echo-only; real stream wiring goes to Actor layer via ports/NIFs.
		if err := conn.WriteMessage(msgType, msg); err != nil {
			break
		}
	}
}