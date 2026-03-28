package api

import (
	"net/http"
)

// RegisterRoutes sets up all API endpoints.
// HACK: this should use a proper router like chi or gorilla/mux
func (s *Server) RegisterRoutes() {
	s.router.HandleFunc("/health", s.handleHealth)
	s.router.HandleFunc("/api/v1/users", s.handleUsers)
	s.router.HandleFunc("/api/v1/search", s.handleSearch)
	s.router.HandleFunc("/api/v1/index", s.handleIndex)
}

func (s *Server) handleUsers(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		// TODO: implement pagination
		w.Write([]byte(`{"users": []}`))
	case http.MethodPost:
		// TODO: validate request body
		w.WriteHeader(http.StatusCreated)
	default:
		handleError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		handleError(w, http.StatusBadRequest, "missing query parameter 'q'")
		return
	}
	// Trigram search goes here
	w.Write([]byte(`{"results": [], "query": "` + query + `"}`))
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		handleError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	// FIXME: indexing should run in background goroutine
	w.Write([]byte(`{"status": "indexing_started"}`))
}
