package feeds

import (
	"bytes"
	"context"
	"fmt"
	"image/jpeg"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Daily true-colour mosaics from NASA GIBS (VIIRS / MODIS corrected reflectance).
// We keep a few days on disk and let the app download the newest complete day.

var gibsLayers = []string{
	"VIIRS_NOAA20_CorrectedReflectance_TrueColor",
	"VIIRS_SNPP_CorrectedReflectance_TrueColor",
	"MODIS_Terra_CorrectedReflectance_TrueColor",
}

func (h *Hub) imageryDir() string { return filepath.Join(h.cacheDir, "imagery") }

// StartImagery fetches yesterday's global mosaic (complete in GIBS by early UTC morning).
func (h *Hub) StartImagery(ctx context.Context) {
	h.every(ctx, "gibs-imagery", time.Hour, h.pollImagery)
}

func (h *Hub) pollImagery(ctx context.Context) error {
	_ = os.MkdirAll(h.imageryDir(), 0o755)
	day := time.Now().UTC().Add(-24 * time.Hour).Format("2006-01-02")
	path := filepath.Join(h.imageryDir(), day+".jpg")
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	var lastErr error
	for _, layer := range gibsLayers {
		url := fmt.Sprintf("https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi?SERVICE=WMS&REQUEST=GetMap&VERSION=1.3.0&LAYERS=%s&CRS=EPSG:4326&BBOX=-90,-180,90,180&WIDTH=4096&HEIGHT=2048&FORMAT=image/jpeg&TIME=%s", layer, day)
		body, err := h.get(ctx, url)
		if err != nil {
			lastErr = err
			continue
		}
		img, err := jpeg.Decode(bytes.NewReader(body))
		if err != nil || img.Bounds().Dx() != 4096 {
			lastErr = fmt.Errorf("gibs %s: not a full mosaic", layer)
			continue
		}
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, body, 0o644); err != nil {
			return err
		}
		if err := os.Rename(tmp, path); err != nil {
			return err
		}
		h.log.Info("stored daily imagery", "day", day, "layer", layer, "bytes", len(body))
		h.pruneImagery(4)
		return nil
	}
	return lastErr
}

func (h *Hub) pruneImagery(keep int) {
	days := h.ImageryDays()
	for i := keep; i < len(days); i++ {
		_ = os.Remove(filepath.Join(h.imageryDir(), days[i]+".jpg"))
	}
}

// ImageryDays lists stored mosaics, newest first.
func (h *Hub) ImageryDays() []string {
	entries, _ := os.ReadDir(h.imageryDir())
	var days []string
	for _, e := range entries {
		if name := e.Name(); strings.HasSuffix(name, ".jpg") {
			days = append(days, strings.TrimSuffix(name, ".jpg"))
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(days)))
	return days
}

func (h *Hub) ImageryPath(day string) (string, bool) {
	if _, err := time.Parse("2006-01-02", day); err != nil {
		return "", false
	}
	p := filepath.Join(h.imageryDir(), day+".jpg")
	if _, err := os.Stat(p); err != nil {
		return "", false
	}
	return p, true
}
