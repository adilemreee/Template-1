package feeds

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Live weather from NOAA's Global Forecast System (GFS), served by PacIOOS's ERDDAP: 10 m wind,
// 2 m temperature and precipitation on a 1° grid, for the model time just before now and the
// next day in 6-hour steps. Each time step is packed into a 360×181 RGBA8 frame that the app
// uploads straight into a Metal texture and interpolates between in time:
//
//	R  eastward wind   0.5 m/s per step, 128 = calm
//	G  northward wind  0.5 m/s per step, 128 = calm
//	B  temperature     0.5 °C per step, 0 = -80 °C
//	A  precipitation   sqrt(mm/h ÷ 50) × 255
//
// Rows run from 90° N to 90° S, columns from 0° to 359° E.

const (
	WeatherWidth  = 360
	WeatherHeight = 181
	weatherStep   = 6 * time.Hour
	weatherSpan   = 24 * time.Hour
)

// weatherSources are tried in order. CoastWatch's dataset redirects to the same PacIOOS data.
var weatherSources = []string{
	"https://pae-paha.pacioos.hawaii.edu/erddap/griddap/ncep_global.csv0",
	"https://coastwatch.pfeg.noaa.gov/erddap/griddap/NCEP_Global_Best.csv0",
}

// WeatherFrame describes one packed time step. The ID changes whenever the content does,
// so a frame can be cached forever.
type WeatherFrame struct {
	ID    string    `json:"id"`
	Valid time.Time `json:"valid"`
}

type weatherFrame struct {
	WeatherFrame
	raw []byte
	gz  []byte
}

// WeatherSample is the model's weather at one place and time.
type WeatherSample struct {
	WindSpeed float64   `json:"windSpeedMs"`
	WindFrom  float64   `json:"windFromDeg"` // meteorological: where the wind blows from
	TempC     float64   `json:"tempC"`
	RainMMH   float64   `json:"rainMmH"`
	Valid     time.Time `json:"valid"`
}

// StartWeather restores frames from disk and keeps them current.
func (h *Hub) StartWeather(ctx context.Context) {
	h.loadWeather()
	h.mu.Lock()
	if len(h.weather) == 0 {
		delete(h.sources, "gfs-weather") // nothing on disk: fetch now, whatever the cache says
	}
	h.mu.Unlock()
	h.every(ctx, "gfs-weather", 3*time.Hour, h.pollWeather)
}

func (h *Hub) weatherDir() string { return filepath.Join(h.cacheDir, "weather") }

// pollWeather fetches the next day one time step at a time. ERDDAP answers a single step in
// about ten seconds but takes minutes over a strided time range, so steps arrive quickly and
// each is published as soon as it lands: after a cold start, wind is up within seconds.
func (h *Hub) pollWeather(ctx context.Context) error {
	start := time.Now().UTC().Truncate(3 * time.Hour)
	var fresh []weatherFrame
	var lastErr error
	for t := start; !t.After(start.Add(weatherSpan)); t = t.Add(weatherStep) {
		f, err := h.fetchWeatherStep(ctx, t)
		if err != nil {
			lastErr = err
			if ctx.Err() != nil {
				break
			}
			continue
		}
		fresh = append(fresh, f)
		h.storeWeather(h.mergeWeather(fresh, start))
	}
	if len(fresh) == 0 {
		if lastErr == nil {
			lastErr = errNoData
		}
		return lastErr
	}
	h.log.Info("weather updated", "frames", len(fresh), "from", fresh[0].Valid, "to", fresh[len(fresh)-1].Valid)
	if len(fresh) < 3 {
		return fmt.Errorf("only %d of the day's GFS steps arrived: %w", len(fresh), lastErr)
	}
	return nil
}

// fetchWeatherStep gets one time step, trying each source in turn.
func (h *Hub) fetchWeatherStep(ctx context.Context, t time.Time) (weatherFrame, error) {
	var lastErr error
	for _, base := range weatherSources {
		sctx, cancel := context.WithTimeout(ctx, 100*time.Second)
		frames, err := h.fetchWeather(sctx, weatherURL(base, t, t))
		cancel()
		if err == nil && len(frames) > 0 {
			return frames[0], nil
		}
		if err == nil {
			err = errNoData
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	return weatherFrame{}, lastErr
}

// mergeWeather overlays fresh steps on the stored ones that are still inside the window.
func (h *Hub) mergeWeather(fresh []weatherFrame, start time.Time) []weatherFrame {
	end := start.Add(weatherSpan)
	byTime := map[int64]weatherFrame{}
	h.mu.RLock()
	for _, f := range h.weather {
		if !f.Valid.Before(start) && !f.Valid.After(end) {
			byTime[f.Valid.Unix()] = f
		}
	}
	h.mu.RUnlock()
	for _, f := range fresh {
		byTime[f.Valid.Unix()] = f
	}
	out := make([]weatherFrame, 0, len(byTime))
	for _, f := range byTime {
		out = append(out, f)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Valid.Before(out[j].Valid) })
	return out
}

// weatherURL asks ERDDAP for one time step (start == end) or every 6-hour step between start
// and end, on a 1° grid. Brackets are percent-encoded: ERDDAP runs on Tomcat, which rejects them raw.
func weatherURL(base string, start, end time.Time) string {
	stride := int(weatherStep / (3 * time.Hour)) // the dataset is 3-hourly
	timeSel := fmt.Sprintf("%%5B(%s)%%5D", start.Format(time.RFC3339))
	if !end.Equal(start) {
		timeSel = fmt.Sprintf("%%5B(%s):%d:(%s)%%5D", start.Format(time.RFC3339), stride, end.Format(time.RFC3339))
	}
	sel := timeSel + "%5B(90):2:(-90)%5D%5B(0):2:(359.5)%5D"
	vars := []string{"ugrd10m", "vgrd10m", "tmp2m", "pratesfc"}
	for i, v := range vars {
		vars[i] = v + sel
	}
	return base + "?" + strings.Join(vars, ",")
}

func (h *Hub) fetchWeather(ctx context.Context, url string) ([]weatherFrame, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "KarmanEarth/1.1 (backend for the Karman iOS app)")
	resp, err := h.slowClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
		if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusTooManyRequests {
			return nil, fmt.Errorf("GFS: HTTP %d: %w", resp.StatusCode, errRateLimited)
		}
		return nil, fmt.Errorf("GFS: HTTP %d", resp.StatusCode)
	}
	return parseWeatherCSV(io.LimitReader(resp.Body, 256<<20))
}

// parseWeatherCSV streams ERDDAP's header-less CSV (time, lat, lon, u, v, t2m, rain rate) into
// packed frames, keeping only time steps that cover nearly the whole grid.
func parseWeatherCSV(r io.Reader) ([]weatherFrame, error) {
	type building struct {
		valid time.Time
		raw   []byte
		cells int
	}
	var frames []*building
	var cur *building
	var curStamp string
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		f := strings.Split(sc.Text(), ",")
		if len(f) < 7 {
			continue
		}
		if cur == nil || f[0] != curStamp {
			t, err := time.Parse(time.RFC3339, f[0])
			if err != nil {
				continue
			}
			curStamp = f[0]
			cur = nil
			for _, b := range frames {
				if b.valid.Equal(t) {
					cur = b
				}
			}
			if cur == nil {
				cur = &building{valid: t.UTC(), raw: neutralWeather()}
				frames = append(frames, cur)
			}
		}
		lat, err1 := strconv.ParseFloat(f[1], 64)
		lon, err2 := strconv.ParseFloat(f[2], 64)
		if err1 != nil || err2 != nil {
			continue
		}
		row, col := int(math.Round(90-lat)), int(math.Round(lon))
		if row < 0 || row >= WeatherHeight || col < 0 || col >= WeatherWidth {
			continue
		}
		i := (row*WeatherWidth + col) * 4
		if u, ok := number(f[3]); ok {
			cur.raw[i] = encodeWind(u)
		}
		if v, ok := number(f[4]); ok {
			cur.raw[i+1] = encodeWind(v)
		}
		if k, ok := number(f[5]); ok {
			cur.raw[i+2] = encodeTemp(k - 273.15)
		}
		if p, ok := number(f[6]); ok {
			cur.raw[i+3] = encodeRain(p * 3600)
		}
		cur.cells++
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	var out []weatherFrame
	for _, b := range frames {
		if b.cells < WeatherWidth*WeatherHeight*95/100 {
			continue
		}
		out = append(out, packWeather(b.valid, b.raw))
	}
	if len(out) == 0 {
		return nil, errNoData
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Valid.Before(out[j].Valid) })
	return out, nil
}

func number(s string) (float64, bool) {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false
	}
	return v, true
}

func packWeather(valid time.Time, raw []byte) weatherFrame {
	sum := sha256.Sum256(raw)
	id := valid.UTC().Format("2006010215") + "-" + hex.EncodeToString(sum[:4])
	return weatherFrame{WeatherFrame: WeatherFrame{ID: id, Valid: valid.UTC()}, raw: raw, gz: gzipBytes(raw)}
}

// neutralWeather is a calm, 0 °C, dry frame that missing cells fall back to.
func neutralWeather() []byte {
	raw := make([]byte, WeatherWidth*WeatherHeight*4)
	t := encodeTemp(0)
	for i := 0; i < len(raw); i += 4 {
		raw[i], raw[i+1], raw[i+2], raw[i+3] = 128, 128, t, 0
	}
	return raw
}

func clampByte(v float64) byte { return byte(math.Max(0, math.Min(255, math.Round(v)))) }

func encodeWind(ms float64) byte { return clampByte(ms*2 + 128) }
func encodeTemp(c float64) byte  { return clampByte((c + 80) * 2) }
func encodeRain(mmh float64) byte {
	if mmh <= 0 {
		return 0
	}
	return clampByte(math.Sqrt(mmh/50) * 255)
}

func decodeWind(b float64) float64 { return (b - 128) / 2 }
func decodeTemp(b float64) float64 { return b/2 - 80 }
func decodeRain(b float64) float64 {
	f := b / 255
	return f * f * 50
}

func (h *Hub) storeWeather(frames []weatherFrame) {
	_ = os.MkdirAll(h.weatherDir(), 0o755)
	keep := map[string]bool{"index.json": true}
	for _, f := range frames {
		name := f.ID + ".rgba"
		keep[name] = true
		path := filepath.Join(h.weatherDir(), name)
		if _, err := os.Stat(path); err != nil {
			_ = os.WriteFile(path, f.raw, 0o644)
		}
	}
	index := make([]WeatherFrame, len(frames))
	for i, f := range frames {
		index[i] = f.WeatherFrame
	}
	if b, err := json.Marshal(index); err == nil {
		_ = os.WriteFile(filepath.Join(h.weatherDir(), "index.json"), b, 0o644)
	}
	if files, err := os.ReadDir(h.weatherDir()); err == nil {
		for _, f := range files {
			if !keep[f.Name()] {
				_ = os.Remove(filepath.Join(h.weatherDir(), f.Name()))
			}
		}
	}
	h.mu.Lock()
	h.weather = frames
	h.mu.Unlock()
	h.notify(ChangeWeather)
}

// loadWeather restores the frames a previous run stored, so restarts serve weather at once.
func (h *Hub) loadWeather() {
	b, err := os.ReadFile(filepath.Join(h.weatherDir(), "index.json"))
	if err != nil {
		return
	}
	var index []WeatherFrame
	if json.Unmarshal(b, &index) != nil {
		return
	}
	var frames []weatherFrame
	for _, f := range index {
		raw, err := os.ReadFile(filepath.Join(h.weatherDir(), f.ID+".rgba"))
		if err != nil || len(raw) != WeatherWidth*WeatherHeight*4 {
			continue
		}
		frames = append(frames, weatherFrame{WeatherFrame: f, raw: raw, gz: gzipBytes(raw)})
	}
	h.mu.Lock()
	h.weather = frames
	h.mu.Unlock()
}

// WeatherFrames lists the stored time steps, oldest first.
func (h *Hub) WeatherFrames() []WeatherFrame {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]WeatherFrame, len(h.weather))
	for i, f := range h.weather {
		out[i] = f.WeatherFrame
	}
	return out
}

// WeatherFrameData returns one packed frame, raw and gzipped.
func (h *Hub) WeatherFrameData(id string) (raw, gz []byte, ok bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, f := range h.weather {
		if f.ID == id {
			return f.raw, f.gz, true
		}
	}
	return nil, nil, false
}

// WeatherAt interpolates the model's weather at a place and time (bilinear in space, linear
// between the two frames around t).
func (h *Hub) WeatherAt(lat, lon float64, t time.Time) (WeatherSample, bool) {
	h.mu.RLock()
	frames := h.weather
	h.mu.RUnlock()
	if len(frames) == 0 {
		return WeatherSample{}, false
	}
	a, b, mix := frames[0], frames[0], 0.0
	for i := 1; i < len(frames); i++ {
		if !t.After(frames[i].Valid) {
			a, b = frames[i-1], frames[i]
			span := b.Valid.Sub(a.Valid).Seconds()
			mix = math.Max(0, math.Min(1, t.Sub(a.Valid).Seconds()/span))
			break
		}
		a, b = frames[i], frames[i]
	}
	var ch [4]float64
	for c := 0; c < 4; c++ {
		ch[c] = sampleWeather(a.raw, lat, lon, c)*(1-mix) + sampleWeather(b.raw, lat, lon, c)*mix
	}
	u, v := decodeWind(ch[0]), decodeWind(ch[1])
	from := math.Mod(math.Atan2(-u, -v)*180/math.Pi+360, 360)
	valid := a.Valid
	if mix > 0.5 {
		valid = b.Valid
	}
	return WeatherSample{WindSpeed: math.Hypot(u, v), WindFrom: from, TempC: decodeTemp(ch[2]), RainMMH: decodeRain(ch[3]), Valid: valid}, true
}

func sampleWeather(raw []byte, lat, lon float64, channel int) float64 {
	y := math.Max(0, math.Min(WeatherHeight-1, 90-lat))
	x := math.Mod(math.Mod(lon, 360)+360, 360)
	x0, y0 := int(x), int(y)
	x1, y1 := (x0+1)%WeatherWidth, min(y0+1, WeatherHeight-1)
	fx, fy := x-float64(x0), y-float64(y0)
	at := func(col, row int) float64 { return float64(raw[(row*WeatherWidth+col)*4+channel]) }
	top := at(x0, y0)*(1-fx) + at(x1, y0)*fx
	bottom := at(x0, y1)*(1-fx) + at(x1, y1)*fx
	return top*(1-fy) + bottom*fy
}

// WeatherExtreme is one of the planet's most striking model cells right now.
type WeatherExtreme struct {
	ID    string  `json:"id"`
	Kind  string  `json:"kind"` // hottest, coldest, windiest, wettest
	Lat   float64 `json:"lat"`
	Lon   float64 `json:"lon"`
	Value float64 `json:"value"`
	Unit  string  `json:"unit"`
}

// WeatherExtremes scans the frame nearest t for the hottest, coldest, windiest and wettest cells.
func (h *Hub) WeatherExtremes(t time.Time) []WeatherExtreme {
	h.mu.RLock()
	frames := h.weather
	h.mu.RUnlock()
	if len(frames) == 0 {
		return nil
	}
	f := frames[0]
	for _, c := range frames[1:] {
		if math.Abs(c.Valid.Sub(t).Seconds()) < math.Abs(f.Valid.Sub(t).Seconds()) {
			f = c
		}
	}
	hot := WeatherExtreme{ID: "wx-hottest", Kind: "hottest", Unit: "°C", Value: math.Inf(-1)}
	cold := WeatherExtreme{ID: "wx-coldest", Kind: "coldest", Unit: "°C", Value: math.Inf(1)}
	windy := WeatherExtreme{ID: "wx-windiest", Kind: "windiest", Unit: "km/h"}
	wet := WeatherExtreme{ID: "wx-wettest", Kind: "wettest", Unit: "mm/h"}
	for row := 0; row < WeatherHeight; row++ {
		lat := 90 - float64(row)
		for col := 0; col < WeatherWidth; col++ {
			i := (row*WeatherWidth + col) * 4
			lon := float64(col)
			if lon > 180 {
				lon -= 360
			}
			temp := decodeTemp(float64(f.raw[i+2]))
			if temp > hot.Value {
				hot.Value, hot.Lat, hot.Lon = temp, lat, lon
			}
			if temp < cold.Value {
				cold.Value, cold.Lat, cold.Lon = temp, lat, lon
			}
			if math.Abs(lat) < 85 { // winds at the pole rows are an artefact of the grid
				speed := math.Hypot(decodeWind(float64(f.raw[i])), decodeWind(float64(f.raw[i+1]))) * 3.6
				if speed > windy.Value {
					windy.Value, windy.Lat, windy.Lon = speed, lat, lon
				}
			}
			if rain := decodeRain(float64(f.raw[i+3])); rain > wet.Value {
				wet.Value, wet.Lat, wet.Lon = rain, lat, lon
			}
		}
	}
	out := []WeatherExtreme{hot, cold, windy}
	if wet.Value >= 1 {
		out = append(out, wet)
	}
	for i := range out {
		out[i].Value = round(out[i].Value, 1)
	}
	return out
}
