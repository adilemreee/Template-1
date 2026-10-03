package httpapi

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"karman/internal/store"
)

func TestRegisterDeviceCoarsensPlaces(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	s := &Server{Log: slog.New(slog.NewTextHandler(io.Discard, nil)), Store: st}
	body := `{"token":"` + strings.Repeat("ab", 32) + `","env":"sandbox","lat":41.0123,"lon":28.9784,"language":"en",
		"prefs":{"quakeMinMag":4.5,"quakeRadiusKm":9000},
		"places":[{"name":"  Mum's   house ","lat":38.4237,"lon":27.1428},{"name":"","lat":1,"lon":1},{"name":"Nowhere","lat":200,"lon":0},
		{"name":"A","lat":1,"lon":1},{"name":"B","lat":2,"lon":2},{"name":"C","lat":3,"lon":3},{"name":"D","lat":4,"lon":4}]}`
	rec := httptest.NewRecorder()
	s.registerDevice(rec, httptest.NewRequest(http.MethodPost, "/v1/devices", strings.NewReader(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	devices, err := st.Devices()
	if err != nil || len(devices) != 1 {
		t.Fatalf("devices %v, err %v", devices, err)
	}
	d := devices[0]
	if *d.Lat != 41 || *d.Lon != 29 || d.Prefs.QuakeRadiusKm != 2000 {
		t.Fatalf("home not coarsened: %v %v %v", *d.Lat, *d.Lon, d.Prefs.QuakeRadiusKm)
	}
	// Five places at most are read; the empty and out-of-range ones are dropped.
	if len(d.Places) != 3 || d.Places[0].Name != "Mum's house" || d.Places[0].Lat != 38.5 || d.Places[0].Lon != 27 {
		t.Fatalf("places %+v", d.Places)
	}
}
