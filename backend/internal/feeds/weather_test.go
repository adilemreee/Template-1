package feeds

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// gfsCSV renders a synthetic ERDDAP csv0 response over the whole 1° grid.
func gfsCSV(times []time.Time, fn func(t time.Time, lat, lon float64) (u, v, k, rate float64)) string {
	var b strings.Builder
	for _, t := range times {
		for lat := 90; lat >= -90; lat-- {
			for lon := 0; lon < 360; lon++ {
				u, v, k, rate := fn(t, float64(lat), float64(lon))
				fmt.Fprintf(&b, "%s,%d.0,%d.0,%g,%g,%g,%g\n", t.Format(time.RFC3339), lat, lon, u, v, k, rate)
			}
		}
	}
	return b.String()
}

func TestWeatherFramesDecodeToTheModelValues(t *testing.T) {
	t0 := time.Date(2026, 10, 3, 9, 0, 0, 0, time.UTC)
	t1 := t0.Add(6 * time.Hour)
	csv := gfsCSV([]time.Time{t1, t0}, func(t time.Time, lat, lon float64) (float64, float64, float64, float64) {
		shift := 0.0
		if t.Equal(t1) {
			shift = 4
		}
		return lat/10 + shift, lon/100 - 1, 273.15 + lat/3, 2.0 / 3600 // 2 mm/h everywhere
	})
	frames, err := parseWeatherCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatal(err)
	}
	if len(frames) != 2 || !frames[0].Valid.Equal(t0) || !frames[1].Valid.Equal(t1) {
		t.Fatalf("frames %+v", frames)
	}
	if !strings.HasPrefix(frames[0].ID, "2026100309-") || frames[0].ID == frames[1].ID {
		t.Fatalf("ids %q %q", frames[0].ID, frames[1].ID)
	}
	h := quietHub(t)
	h.storeWeather(frames)

	s, ok := h.WeatherAt(40, 120, t0)
	if !ok {
		t.Fatal("no sample")
	}
	wantU, wantV := 4.0, 0.2
	u := s.WindSpeed * -math.Sin(s.WindFrom*math.Pi/180)
	v := s.WindSpeed * -math.Cos(s.WindFrom*math.Pi/180)
	if math.Abs(u-wantU) > 0.3 || math.Abs(v-wantV) > 0.3 {
		t.Fatalf("wind u=%.2f v=%.2f, want %.2f %.2f", u, v, wantU, wantV)
	}
	if math.Abs(s.TempC-40.0/3) > 0.3 {
		t.Fatalf("temperature %.2f", s.TempC)
	}
	if math.Abs(s.RainMMH-2) > 0.3 {
		t.Fatalf("rain %.2f mm/h", s.RainMMH)
	}
	// Halfway between the frames the eastward wind is halfway between 4 and 8 m/s.
	mid, _ := h.WeatherAt(40, 120, t0.Add(3*time.Hour))
	if u := mid.WindSpeed * -math.Sin(mid.WindFrom*math.Pi/180); math.Abs(u-6) > 0.3 {
		t.Fatalf("interpolated u=%.2f, want 6", u)
	}

	// A restart restores the same frames from disk.
	warm := NewHub(h.log, h.cacheDir, "DEMO_KEY")
	warm.loadWeather()
	if got := warm.WeatherFrames(); len(got) != 2 || got[1].ID != frames[1].ID {
		t.Fatalf("restored %+v", got)
	}
	if raw, gz, ok := warm.WeatherFrameData(frames[0].ID); !ok || len(raw) != WeatherWidth*WeatherHeight*4 || len(gz) == 0 {
		t.Fatal("restored frame data missing")
	}
}

func TestPartialWeatherFramesAreDropped(t *testing.T) {
	t0 := time.Date(2026, 10, 3, 9, 0, 0, 0, time.UTC)
	full := gfsCSV([]time.Time{t0}, func(time.Time, float64, float64) (float64, float64, float64, float64) { return 1, 1, 280, 0 })
	partial := "2026-10-03T15:00:00Z,10.0,10.0,1,1,280,0\n"
	frames, err := parseWeatherCSV(strings.NewReader(full + partial + "Error {\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(frames) != 1 || !frames[0].Valid.Equal(t0) {
		t.Fatalf("got %d frames", len(frames))
	}
}

func TestPollWeatherAsksForSixHourlyStepsAndFallsBack(t *testing.T) {
	var requests atomic.Int32
	var query string
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		query = r.URL.RawQuery
		now := time.Now().UTC().Truncate(3 * time.Hour)
		_, _ = io.WriteString(w, gfsCSV([]time.Time{now, now.Add(6 * time.Hour)}, func(time.Time, float64, float64) (float64, float64, float64, float64) {
			return 3, -2, 290, 0
		}))
	}))
	defer good.Close()
	broken := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusInternalServerError) }))
	defer broken.Close()
	old := weatherSources
	weatherSources = []string{broken.URL + "/a.csv0", good.URL + "/b.csv0"}
	defer func() { weatherSources = old }()

	h := quietHub(t)
	if err := h.pollWeather(context.Background()); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 1 || len(h.WeatherFrames()) != 2 {
		t.Fatalf("requests %d, frames %d", requests.Load(), len(h.WeatherFrames()))
	}
	for _, want := range []string{"ugrd10m%5B(", "):2:(", "%5B(90):2:(-90)%5D", ",pratesfc%5B"} {
		if !strings.Contains(query, want) {
			t.Fatalf("query %q lacks %q", query, want)
		}
	}
	if _, err := os.Stat(filepath.Join(h.weatherDir(), "index.json")); err != nil {
		t.Fatal("index not persisted")
	}
}

func TestYearOfQuakes(t *testing.T) {
	type feature map[string]any
	var features []feature
	start := time.Now().Add(-300 * 24 * time.Hour)
	for i := 0; i < 150; i++ {
		mag := 4.5 + float64(i%30)/10
		features = append(features, feature{
			"id":         fmt.Sprintf("us%04d", i),
			"properties": map[string]any{"mag": mag, "place": "Somewhere", "time": start.Add(time.Duration(i) * time.Hour).UnixMilli(), "sig": 400, "type": "earthquake", "tsunami": 0},
			"geometry":   map[string]any{"coordinates": []float64{140.12345, 35.6789, 10}},
		})
	}
	body, _ := json.Marshal(map[string]any{"features": features})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("minmagnitude") != "4.5" || r.URL.Query().Get("orderby") != "time-asc" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_, _ = w.Write(body)
	}))
	defer srv.Close()
	old := fdsnBase
	fdsnBase = srv.URL
	defer func() { fdsnBase = old }()

	h := quietHub(t)
	if err := h.pollHistory(context.Background()); err != nil {
		t.Fatal(err)
	}
	gz, etag, ok := h.QuakeHistory()
	if !ok || etag == "" {
		t.Fatal("history missing")
	}
	zr, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		MinMag float64 `json:"minMag"`
		Quakes []struct {
			ID  string  `json:"id"`
			Mag float64 `json:"mag"`
			Lat float64 `json:"lat"`
		} `json:"quakes"`
	}
	if err := json.NewDecoder(zr).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.MinMag != 4.5 || len(got.Quakes) != 150 || got.Quakes[0].Lat != 35.68 {
		t.Fatalf("decoded %+v", got.Quakes[:1])
	}
	stats, _ := h.YearStats()
	if stats.M45Plus != 150 || stats.M6Plus != 75 || stats.M7Plus != 25 || stats.Strongest.Mag != 7.4 {
		t.Fatalf("stats %+v", stats)
	}
	warm := NewHub(h.log, h.cacheDir, "DEMO_KEY")
	warm.loadHistory()
	if _, etag2, ok := warm.QuakeHistory(); !ok || etag2 != etag {
		t.Fatal("history not restored from disk")
	}
}

func TestCloudsRoundAndCache(t *testing.T) {
	var calls atomic.Int32
	var gotQuery, gotUA string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		gotQuery, gotUA = r.URL.RawQuery, r.Header.Get("User-Agent")
		w.Header().Set("Expires", time.Now().Add(30*time.Minute).UTC().Format(http.TimeFormat))
		now := time.Now().UTC().Truncate(time.Hour)
		_, _ = fmt.Fprintf(w, `{"properties":{"timeseries":[
			{"time":"%s","data":{"instant":{"details":{"cloud_area_fraction":12.4,"relative_humidity":70.2,"air_temperature":11.25}}}},
			{"time":"%s","data":{"instant":{"details":{"cloud_area_fraction":88.0}}}},
			{"time":"%s","data":{"instant":{"details":{"cloud_area_fraction":5.0}}}}]}}`,
			now.Format(time.RFC3339), now.Add(time.Hour).Format(time.RFC3339), now.Add(200*time.Hour).Format(time.RFC3339))
	}))
	defer srv.Close()
	old := metBase
	metBase = srv.URL
	defer func() { metBase = old }()
	clouds.mu.Lock()
	clear(clouds.entries)
	clouds.mu.Unlock()

	h := quietHub(t)
	h.SetContact("support@example.com")
	fc, err := h.Clouds(context.Background(), 41.0123, 28.9784)
	if err != nil {
		t.Fatal(err)
	}
	if gotQuery != "lat=41.0&lon=29.0" || !strings.Contains(gotUA, "support@example.com") {
		t.Fatalf("query %q, user agent %q", gotQuery, gotUA)
	}
	if len(fc.Points) != 2 || fc.Points[0].Cloud != 12 || fc.Points[0].TempC != 11.3 || fc.Points[1].Cloud != 88 {
		t.Fatalf("points %+v", fc.Points)
	}
	if _, err := h.Clouds(context.Background(), 41.2, 29.1); err != nil || calls.Load() != 1 {
		t.Fatalf("second call: err %v, upstream calls %d", err, calls.Load())
	}
}

func TestPlatesAreEmbedded(t *testing.T) {
	plain, gz, etag := Plates()
	if len(gz) == 0 || etag == "" {
		t.Fatal("empty")
	}
	var p struct {
		Kinds  map[string][][]float64 `json:"kinds"`
		Plates []struct {
			Code string `json:"code"`
		} `json:"plates"`
	}
	if err := json.Unmarshal(plain, &p); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"divergent", "convergent", "transform"} {
		if len(p.Kinds[k]) < 100 {
			t.Fatalf("%s: %d lines", k, len(p.Kinds[k]))
		}
		for _, line := range p.Kinds[k] {
			if len(line) < 4 || len(line)%2 != 0 {
				t.Fatalf("%s line with %d numbers", k, len(line))
			}
		}
	}
	if len(p.Plates) < 15 {
		t.Fatalf("%d plate labels", len(p.Plates))
	}
}
