package httpapi

import (
	"io"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSupportPage(t *testing.T) {
	for _, tc := range []struct {
		email string
		want  string
	}{
		{"", ""},
		{"help@example.com", `mailto:help@example.com`},
	} {
		s := &Server{SupportEmail: tc.email}
		rec := httptest.NewRecorder()
		s.support(rec, httptest.NewRequest("GET", "/support", nil))
		body, _ := io.ReadAll(rec.Body)
		page := string(body)
		if strings.Contains(page, "{{") {
			t.Fatalf("unfilled placeholder in support page (email %q)", tc.email)
		}
		if tc.want != "" && strings.Count(page, tc.want) != 2 {
			t.Fatalf("expected contact link in both languages, got %d", strings.Count(page, tc.want))
		}
		if tc.want == "" && strings.Contains(page, "mailto:") {
			t.Fatal("contact link rendered without an address")
		}
		if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
			t.Fatalf("content type %q", ct)
		}
	}
}

func TestSiteHandler(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "index.html"), []byte("<h1>Kármán</h1>"), 0o644)
	_ = os.MkdirAll(filepath.Join(dir, "img"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "img", "a.webp"), []byte("x"), 0o644)
	h := siteHandler(dir)
	for path, want := range map[string]int{"/": 200, "/img/a.webp": 200, "/img/": 404, "/missing.html": 404, "/../etc/passwd": 404} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		if rec.Code != want && !(path == "/../etc/passwd" && rec.Code >= 300) {
			t.Errorf("%s: got %d, want %d", path, rec.Code, want)
		}
	}
}

func TestClientIPTrustsOnlyLocalProxy(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "203.0.113.9:5555"
	r.Header.Set("X-Real-IP", "198.51.100.1")
	if got := clientIP(r); got != "203.0.113.9" {
		t.Fatalf("spoofed header trusted from remote peer: %s", got)
	}
	r.RemoteAddr = "127.0.0.1:5555"
	if got := clientIP(r); got != "198.51.100.1" {
		t.Fatalf("local proxy header ignored: %s", got)
	}
	r.Header.Del("X-Real-IP")
	r.Header.Set("X-Forwarded-For", "10.0.0.1, 198.51.100.7")
	if got := clientIP(r); got != "198.51.100.7" {
		t.Fatalf("forwarded-for: %s", got)
	}
}
