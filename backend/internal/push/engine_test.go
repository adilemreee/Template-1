package push

import (
	"testing"

	"karman/internal/store"
)

func TestNearestPlaceInsideRadius(t *testing.T) {
	places := []store.Place{{Name: "Izmir", Lat: 38.5, Lon: 27}, {Name: "Ankara", Lat: 40, Lon: 33}}
	p, dist, ok := nearestPlace(places, 38.2, 27.3, 300)
	if !ok || p.Name != "Izmir" || dist > 50 {
		t.Fatalf("got %v %.0f %v", p, dist, ok)
	}
	if _, _, ok := nearestPlace(places, 10, 10, 300); ok {
		t.Fatal("a quake far from every place matched")
	}
	if _, _, ok := nearestPlace(nil, 38.2, 27.3, 300); ok {
		t.Fatal("no places, no match")
	}
}

func TestVisibleAuroraChanceFallsOffWithDistance(t *testing.T) {
	grid := make([]byte, 360*181)
	grid[(68+90)*360+20] = 80 // a bright oval cell over northern Scandinavia
	near := VisibleAuroraChance(grid, 360, 67, 20)
	far := VisibleAuroraChance(grid, 360, 60, 20)
	none := VisibleAuroraChance(grid, 360, 41, 29)
	if near < 70 || far >= near || far == 0 || none != 0 {
		t.Fatalf("near %d far %d none %d", near, far, none)
	}
}
