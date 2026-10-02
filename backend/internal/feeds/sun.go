package feeds

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png"
	"sync"
	"time"

	"golang.org/x/image/draw"
)

// Live images of the Sun from NOAA GOES-19 SUVI, cropped and re-encoded small for phones.

var SunBands = map[string]bool{"304": true, "171": true, "195": true}

type sunImage struct {
	jpeg    []byte
	fetched time.Time
	taken   time.Time
}

type sunCache struct {
	mu     sync.Mutex
	images map[string]sunImage
}

var suns = &sunCache{images: map[string]sunImage{}}

// SunImage returns a cached JPEG of the latest SUVI frame in the given band.
func (h *Hub) SunImage(ctx context.Context, band string) ([]byte, time.Time, error) {
	if !SunBands[band] {
		return nil, time.Time{}, fmt.Errorf("unknown band %q", band)
	}
	suns.mu.Lock()
	cached, ok := suns.images[band]
	suns.mu.Unlock()
	if ok && time.Since(cached.fetched) < 8*time.Minute {
		return cached.jpeg, cached.taken, nil
	}
	raw, err := h.get(ctx, fmt.Sprintf("https://services.swpc.noaa.gov/images/animations/suvi/primary/%s/latest.png", band))
	if err != nil {
		if ok {
			return cached.jpeg, cached.taken, nil
		}
		return nil, time.Time{}, err
	}
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, time.Time{}, err
	}
	b := src.Bounds()
	// Crop the burned-in caption at the bottom and keep a square around the disc.
	side := b.Dy() * 92 / 100
	x0 := b.Min.X + (b.Dx()-side)/2
	crop := image.Rect(x0, b.Min.Y, x0+side, b.Min.Y+side)
	const out = 720
	dst := image.NewRGBA(image.Rect(0, 0, out, out))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, crop, draw.Over, nil)
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 86}); err != nil {
		return nil, time.Time{}, err
	}
	img := sunImage{jpeg: buf.Bytes(), fetched: time.Now(), taken: time.Now().Add(-6 * time.Minute)}
	suns.mu.Lock()
	suns.images[band] = img
	suns.mu.Unlock()
	return img.jpeg, img.taken, nil
}
