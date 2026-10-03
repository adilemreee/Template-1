package feeds

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSunFramesPickQuarterHoursAndCache(t *testing.T) {
	var frame bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, 64, 64))
	img.Set(32, 32, color.RGBA{255, 120, 40, 255})
	_ = png.Encode(&frame, img)

	newest := time.Date(2026, 10, 3, 7, 0, 0, 0, time.UTC)
	var listing strings.Builder
	downloads := 0
	for i := 0; i < 120; i++ { // eight hours at the SUVI cadence of four minutes
		s := newest.Add(-time.Duration(i) * 4 * time.Minute).Format("20060102T150405Z")
		e := newest.Add(-time.Duration(i)*4*time.Minute + 4*time.Minute).Format("20060102T150405Z")
		fmt.Fprintf(&listing, `<a href="or_suvi-l2-ci304_g19_s%s_e%s_v1-0-2.png">x</a>`+"\n", s, e)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, ".png") {
			downloads++
			_, _ = w.Write(frame.Bytes())
			return
		}
		_, _ = w.Write([]byte(listing.String()))
	}))
	defer srv.Close()
	old := suviBase
	suviBase = srv.URL + "/"
	defer func() { suviBase = old }()

	h := quietHub(t)
	if err := h.pollSunFrames(context.Background(), "304"); err != nil {
		t.Fatal(err)
	}
	frames := h.SunFrames("304")
	if len(frames) != sunFrameCount {
		t.Fatalf("got %d frames, want %d", len(frames), sunFrameCount)
	}
	if !frames[len(frames)-1].Time.Equal(newest) {
		t.Fatalf("newest frame %v, want %v", frames[len(frames)-1].Time, newest)
	}
	for i := 1; i < len(frames); i++ {
		if gap := frames[i].Time.Sub(frames[i-1].Time); gap < 14*time.Minute {
			t.Fatalf("frames %d and %d only %v apart", i-1, i, gap)
		}
	}
	if _, ok := h.SunFrameJPEG("304", frames[0].ID); !ok {
		t.Fatal("frame image missing")
	}
	first := downloads
	if err := h.pollSunFrames(context.Background(), "304"); err != nil {
		t.Fatal(err)
	}
	if downloads != first {
		t.Fatalf("second poll downloaded %d frames again", downloads-first)
	}
}
