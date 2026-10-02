// Package planet defines the normalized "state of the planet" that the app consumes.
// Upstream feeds change formats from time to time; keeping the app on this schema means
// those changes are absorbed here instead of in shipped binaries.
package planet

import "time"

type Snapshot struct {
	GeneratedAt time.Time      `json:"generatedAt"`
	Quakes      []Quake        `json:"quakes"`
	Events      []NaturalEvent `json:"events"`
	Aurora      *Aurora        `json:"aurora,omitempty"`
	Space       *SpaceWeather  `json:"space,omitempty"`
	Launches    []Launch       `json:"launches"`
	NEOs        []NEO          `json:"neos"`
	Sources     []SourceState  `json:"sources"`
}

type Quake struct {
	ID      string    `json:"id"`
	Mag     float64   `json:"mag"`
	Place   string    `json:"place"`
	Time    time.Time `json:"time"`
	Lat     float64   `json:"lat"`
	Lon     float64   `json:"lon"`
	DepthKm float64   `json:"depthKm"`
	Tsunami bool      `json:"tsunami,omitempty"`
	Felt    int       `json:"felt,omitempty"`
	Alert   string    `json:"alert,omitempty"`
	Sig     int       `json:"sig"`
	URL     string    `json:"url,omitempty"`
}

type TrackPoint struct {
	Lat   float64   `json:"lat"`
	Lon   float64   `json:"lon"`
	Time  time.Time `json:"time"`
	Value float64   `json:"value,omitempty"`
}

type NaturalEvent struct {
	ID        string       `json:"id"`
	Kind      string       `json:"kind"` // wildfire, storm, volcano, ice, flood, dust, drought, landslide, other
	Title     string       `json:"title"`
	Lat       float64      `json:"lat"`
	Lon       float64      `json:"lon"`
	Time      time.Time    `json:"time"`
	Value     float64      `json:"value,omitempty"`
	Unit      string       `json:"unit,omitempty"`
	Track     []TrackPoint `json:"track,omitempty"`
	Source    string       `json:"source,omitempty"`
	SourceURL string       `json:"sourceUrl,omitempty"`
}

// Aurora carries NOAA SWPC's OVATION probability grid: 360 longitudes (0..359 E) x
// 181 latitudes (-90..90), row-major by latitude, one byte (0-100 %) per cell, base64.
type Aurora struct {
	Observed   time.Time `json:"observed"`
	Forecast   time.Time `json:"forecast"`
	MaxNorth   int       `json:"maxNorth"`
	MaxSouth   int       `json:"maxSouth"`
	Grid       string    `json:"grid"`
	GridWidth  int       `json:"gridWidth"`
	GridHeight int       `json:"gridHeight"`
}

type Sample struct {
	T time.Time `json:"t"`
	V float64   `json:"v"`
}

type SpaceWeather struct {
	Kp          float64      `json:"kp"`
	KpEstimated float64      `json:"kpEstimated"`
	KpTime      time.Time    `json:"kpTime"`
	GScale      int          `json:"gScale"`
	KpHistory   []Sample     `json:"kpHistory"`
	KpForecast  []Sample     `json:"kpForecast"`
	WindSpeed   float64      `json:"windSpeed"`
	WindDensity float64      `json:"windDensity"`
	Bz          float64      `json:"bz"`
	Bt          float64      `json:"bt"`
	WindTime    time.Time    `json:"windTime"`
	WindHistory []Sample     `json:"windHistory"`
	BzHistory   []Sample     `json:"bzHistory"`
	XrayFlux    float64      `json:"xrayFlux"`
	XrayClass   string       `json:"xrayClass"`
	XrayTime    time.Time    `json:"xrayTime"`
	XrayHistory []Sample     `json:"xrayHistory"`
	Flares      []Flare      `json:"flares"`
	Alerts      []SpaceAlert `json:"alerts"`
}

type Flare struct {
	Begin  time.Time `json:"begin"`
	Peak   time.Time `json:"peak"`
	End    time.Time `json:"end,omitzero"`
	Class  string    `json:"class"`
	Region string    `json:"region,omitempty"`
}

type SpaceAlert struct {
	Time    time.Time `json:"time"`
	Code    string    `json:"code"`
	Title   string    `json:"title"`
	Message string    `json:"message"`
}

type Launch struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Provider     string    `json:"provider"`
	Rocket       string    `json:"rocket"`
	Mission      string    `json:"mission,omitempty"`
	Orbit        string    `json:"orbit,omitempty"`
	Pad          string    `json:"pad"`
	Location     string    `json:"location"`
	Lat          float64   `json:"lat"`
	Lon          float64   `json:"lon"`
	NET          time.Time `json:"net"`
	Status       string    `json:"status"`
	StatusAbbrev string    `json:"statusAbbrev"`
	Webcast      string    `json:"webcast,omitempty"`
	Image        string    `json:"image,omitempty"`
}

type NEO struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Approach     time.Time `json:"approach"`
	MissKm       float64   `json:"missKm"`
	MissLunar    float64   `json:"missLunar"`
	DiameterMinM float64   `json:"diameterMinM"`
	DiameterMaxM float64   `json:"diameterMaxM"`
	VelocityKps  float64   `json:"velocityKps"`
	Hazardous    bool      `json:"hazardous"`
	URL          string    `json:"url,omitempty"`
}

type SourceState struct {
	Name      string    `json:"name"`
	UpdatedAt time.Time `json:"updatedAt,omitzero"`
	OK        bool      `json:"ok"`
}

// Satellite is a compact OMM element set suitable for SGP4 propagation on device.
type Satellite struct {
	Name        string  `json:"name"`
	NoradID     int     `json:"id"`
	Epoch       string  `json:"epoch"`
	MeanMotion  float64 `json:"mm"`
	Ecc         float64 `json:"ecc"`
	Inc         float64 `json:"inc"`
	RAAN        float64 `json:"raan"`
	ArgP        float64 `json:"argp"`
	MeanAnomaly float64 `json:"ma"`
	BStar       float64 `json:"bstar"`
	NDot        float64 `json:"ndot"`
	NDDot       float64 `json:"nddot"`
}
