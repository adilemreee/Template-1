package httpapi

import (
	_ "embed"
	"net/http"
)

//go:embed pages/privacy.html
var privacyHTML []byte

func (s *Server) privacy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(privacyHTML)
}
