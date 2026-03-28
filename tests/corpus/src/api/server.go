package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"
)

// Server is the main HTTP server for the application.
// TODO: add graceful shutdown support
type Server struct {
	router  *http.ServeMux
	port    int
	timeout time.Duration
}

// NewServer creates a new server with sensible defaults.
func NewServer(port int) *Server {
	return &Server{
		router:  http.NewServeMux(),
		port:    port,
		timeout: 30 * time.Second,
	}
}

// Start begins listening for HTTP requests.
// FIXME: this doesn't handle TLS yet
func (s *Server) Start() error {
	addr := fmt.Sprintf(":%d", s.port)
	log.Printf("Starting server on %s", addr)

	srv := &http.Server{
		Addr:         addr,
		Handler:      s.router,
		ReadTimeout:  s.timeout,
		WriteTimeout: s.timeout,
	}

	return srv.ListenAndServe()
}

// handleHealth returns a simple health check response.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ok",
		"uptime": time.Since(time.Now()).String(),
	})
}

// handleError writes a JSON error response.
// TODO: integrate with error tracking service (Sentry)
func handleError(w http.ResponseWriter, code int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"error":   true,
		"message": message,
		"code":    code,
	})
}
