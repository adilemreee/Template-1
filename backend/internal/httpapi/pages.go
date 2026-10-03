package httpapi

import (
	"bytes"
	_ "embed"
	"html"
	"net/http"
)

//go:embed pages/privacy.html
var privacyHTML []byte

//go:embed pages/support.html
var supportHTML []byte

func (s *Server) privacy(w http.ResponseWriter, r *http.Request) {
	writePage(w, privacyHTML)
}

func (s *Server) support(w http.ResponseWriter, r *http.Request) {
	s.supportOnce.Do(func() { s.supportPage = renderSupport(s.SupportEmail) })
	writePage(w, s.supportPage)
}

// renderSupport fills in the contact lines; without an address they are simply left out.
func renderSupport(email string) []byte {
	en, tr := "", ""
	if email != "" {
		e := html.EscapeString(email)
		en = `<p>Need help? Email <a href="mailto:` + e + `">` + e + `</a> and we'll get back to you.</p>`
		tr = `<p>Yardım mı lazım? <a href="mailto:` + e + `">` + e + `</a> adresine yaz, sana dönelim.</p>`
	}
	page := bytes.Replace(supportHTML, []byte("{{CONTACT_EN}}"), []byte(en), 1)
	return bytes.Replace(page, []byte("{{CONTACT_TR}}"), []byte(tr), 1)
}

func writePage(w http.ResponseWriter, body []byte) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(body)
}
