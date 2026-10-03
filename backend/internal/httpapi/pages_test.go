package httpapi

import (
	"io"
	"net/http/httptest"
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
