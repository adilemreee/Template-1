package feeds

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"sync"
	"time"

	"golang.org/x/image/draw"
)

// Time-lapse of the Sun: SUVI publishes a frame every four minutes; we keep a frame every
// quarter hour over the last six hours per band, small enough to stream to a phone.

const (
	sunFrameCount   = 24
	sunFrameSpacing = 15 * time.Minute
	sunFrameSize    = 768
)

// SunFrame is one frame of a band's time-lapse, oldest first in a list.
type SunFrame struct {
	ID   string    `json:"id"`
	Time time.Time `json:"t"`
}

type sunFrameSet struct {
	mu     sync.RWMutex
	frames map[string][]SunFrame // band → selected frames, oldest first
	jpegs  map[string][]byte     // band/id → JPEG
}

var sunFrames = &sunFrameSet{frames: map[string][]SunFrame{}, jpegs: map[string][]byte{}}

// suviBase is where SWPC publishes SUVI frames (a variable so tests can point elsewhere).
var suviBase = "https://services.swpc.noaa.gov/images/animations/suvi/primary/"

var suviName = regexp.MustCompile(`or_suvi-l2-ci(\d{3})_g\d+_s(\d{8}T\d{6}Z)_e\d{8}T\d{6}Z_v[\d-]+\.png`)

// StartSunFrames keeps every band's time-lapse current.
func (h *Hub) StartSunFrames(ctx context.Context) {
	h.loadSunFrames()
	bands := make([]string, 0, len(SunBands))
	for b := range SunBands {
		bands = append(bands, b)
	}
	sort.Strings(bands)
	h.every(ctx, "suvi-frames", 10*time.Minute, func(ctx context.Context) error {
		var firstErr error
		for _, b := range bands {
			if err := h.pollSunFrames(ctx, b); err != nil && firstErr == nil {
				firstErr = err
			}
		}
		return firstErr
	})
}

// SunFrames lists the time-lapse frames available for a band, oldest first.
func (h *Hub) SunFrames(band string) []SunFrame {
	sunFrames.mu.RLock()
	defer sunFrames.mu.RUnlock()
	return slices.Clone(sunFrames.frames[band])
}

// SunFrameJPEG returns one time-lapse frame.
func (h *Hub) SunFrameJPEG(band, id string) ([]byte, bool) {
	sunFrames.mu.RLock()
	defer sunFrames.mu.RUnlock()
	b, ok := sunFrames.jpegs[band+"/"+id]
	return b, ok
}

func (h *Hub) sunFrameDir(band string) string {
	return filepath.Join(h.cacheDir, fmt.Sprintf("sun-%d", sunFrameSize), band)
}

func (h *Hub) pollSunFrames(ctx context.Context, band string) error {
	base := fmt.Sprintf("%s%s/", suviBase, band)
	listing, err := h.get(ctx, base)
	if err != nil {
		return err
	}
	type entry struct {
		name string
		id   string
		t    time.Time
	}
	var all []entry
	seen := map[string]bool{}
	for _, m := range suviName.FindAllSubmatch(listing, -1) {
		name, id := string(m[0]), string(m[2])
		if string(m[1]) != band || seen[id] {
			continue
		}
		t, err := time.Parse("20060102T150405Z", id)
		if err != nil {
			continue
		}
		seen[id] = true
		all = append(all, entry{name, id, t})
	}
	if len(all) == 0 {
		return errNoData
	}
	sort.Slice(all, func(i, j int) bool { return all[i].t.After(all[j].t) }) // newest first

	// Walk back from the newest frame, keeping one per spacing interval.
	var picked []entry
	for _, e := range all {
		if len(picked) == sunFrameCount {
			break
		}
		if len(picked) == 0 || picked[len(picked)-1].t.Sub(e.t) >= sunFrameSpacing-time.Minute {
			picked = append(picked, e)
		}
	}
	slices.Reverse(picked) // oldest first

	_ = os.MkdirAll(h.sunFrameDir(band), 0o755)
	frames := make([]SunFrame, 0, len(picked))
	fresh := map[string][]byte{}
	for _, e := range picked {
		key := band + "/" + e.id
		sunFrames.mu.RLock()
		jpg, ok := sunFrames.jpegs[key]
		sunFrames.mu.RUnlock()
		if !ok {
			raw, err := h.get(ctx, base+e.name)
			if err != nil {
				continue // keep going; a missing frame just shortens the loop
			}
			if jpg, err = encodeSunFrame(raw); err != nil {
				continue
			}
			_ = os.WriteFile(filepath.Join(h.sunFrameDir(band), e.id+".jpg"), jpg, 0o644)
		}
		fresh[key] = jpg
		frames = append(frames, SunFrame{ID: e.id, Time: e.t})
	}
	if len(frames) == 0 {
		return errNoData
	}

	sunFrames.mu.Lock()
	for k := range sunFrames.jpegs {
		if filepath.Dir(k) == band {
			delete(sunFrames.jpegs, k)
		}
	}
	for k, v := range fresh {
		sunFrames.jpegs[k] = v
	}
	sunFrames.frames[band] = frames
	sunFrames.mu.Unlock()

	// Drop frames that have scrolled out of the window.
	if files, err := os.ReadDir(h.sunFrameDir(band)); err == nil {
		for _, f := range files {
			if _, keep := fresh[band+"/"+f.Name()[:len(f.Name())-len(filepath.Ext(f.Name()))]]; !keep {
				_ = os.Remove(filepath.Join(h.sunFrameDir(band), f.Name()))
			}
		}
	}
	return nil
}

// loadSunFrames restores frames saved by a previous run so restarts download nothing twice.
func (h *Hub) loadSunFrames() {
	for band := range SunBands {
		files, err := os.ReadDir(h.sunFrameDir(band))
		if err != nil {
			continue
		}
		var frames []SunFrame
		for _, f := range files {
			id := f.Name()[:len(f.Name())-len(filepath.Ext(f.Name()))]
			t, err := time.Parse("20060102T150405Z", id)
			if err != nil {
				continue
			}
			b, err := os.ReadFile(filepath.Join(h.sunFrameDir(band), f.Name()))
			if err != nil {
				continue
			}
			sunFrames.jpegs[band+"/"+id] = b
			frames = append(frames, SunFrame{ID: id, Time: t})
		}
		sort.Slice(frames, func(i, j int) bool { return frames[i].Time.Before(frames[j].Time) })
		sunFrames.frames[band] = frames
	}
}

// encodeSunFrame crops the burned-in caption, keeps a square around the disc and shrinks it.
func encodeSunFrame(raw []byte) ([]byte, error) {
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	b := src.Bounds()
	side := b.Dy() * 92 / 100
	x0 := b.Min.X + (b.Dx()-side)/2
	crop := image.Rect(x0, b.Min.Y, x0+side, b.Min.Y+side)
	dst := image.NewRGBA(image.Rect(0, 0, sunFrameSize, sunFrameSize))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, crop, draw.Over, nil)
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 80}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
