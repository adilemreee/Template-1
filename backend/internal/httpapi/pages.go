package httpapi

import (
	"bytes"
	_ "embed"
	"html"
	"net/http"
	"strings"
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

// StaticPages returns the privacy and support pages as standalone files for hosting on any
// static web host (App Store Connect needs both URLs behind a publicly trusted certificate).
func StaticPages(supportEmail string) map[string][]byte {
	support := bytes.ReplaceAll(renderSupport(supportEmail), []byte(`href="privacy"`), []byte(`href="privacy.html"`))
	privacy := bytes.ReplaceAll(privacyHTML, []byte(`href="support"`), []byte(`href="support.html"`))
	return map[string][]byte{"privacy.html": privacy, "support.html": support}
}

func writePage(w http.ResponseWriter, body []byte) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(body)
}

// siteHandler serves the static product website (index, images, preview video) without
// directory listings. Media is immutable per release, so it is cached for a day.
func siteHandler(dir string) http.Handler {
	files := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if p != "/" && strings.HasSuffix(p, "/") {
			http.NotFound(w, r)
			return
		}
		if strings.HasPrefix(p, "/img/") || strings.HasPrefix(p, "/media/") {
			w.Header().Set("Cache-Control", "public, max-age=86400")
		} else {
			w.Header().Set("Cache-Control", "public, max-age=600")
		}
		files.ServeHTTP(w, r)
	})
}
