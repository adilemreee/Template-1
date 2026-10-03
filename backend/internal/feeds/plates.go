package feeds

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"sync"
)

// Tectonic plate boundaries (Bird 2003, PB2002), merged into polylines by motion and packed
// by tools/build_plates.py. They change on geological time scales, so they ship in the binary.
//
//go:embed plates.json
var platesJSON []byte

var plates struct {
	once sync.Once
	gz   []byte
	etag string
}

// Plates returns the gzipped plate-boundary model and its ETag.
func Plates() (plain, gz []byte, etag string) {
	plates.once.Do(func() {
		sum := sha256.Sum256(platesJSON)
		plates.gz = gzipBytes(platesJSON)
		plates.etag = `"` + hex.EncodeToString(sum[:10]) + `"`
	})
	return platesJSON, plates.gz, plates.etag
}
