// Package store persists devices, alert de-duplication, AI usage and cached briefings in SQLite.
package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"

	"karman/internal/ai"
)

type Store struct {
	db *sql.DB
}

type DevicePrefs struct {
	QuakeMinMag     float64 `json:"quakeMinMag"`
	QuakeRadiusKm   float64 `json:"quakeRadiusKm"`
	GlobalMajor     bool    `json:"globalMajor"`
	Aurora          bool    `json:"aurora"`
	AuroraMinChance int     `json:"auroraMinChance"`
	Launches        bool    `json:"launches"`
	SpaceStorms     bool    `json:"spaceStorms"`
}

type Device struct {
	Token     string      `json:"token"`
	Env       string      `json:"env"` // "sandbox" | "production"
	Lat       *float64    `json:"lat,omitempty"`
	Lon       *float64    `json:"lon,omitempty"`
	Language  string      `json:"language"`
	TZOffset  int         `json:"tzOffsetMinutes"`
	Prefs     DevicePrefs `json:"prefs"`
	UpdatedAt time.Time   `json:"updatedAt"`
}

func Open(dir string) (*Store, error) {
	db, err := sql.Open("sqlite", filepath.Join(dir, "karman.db")+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	schema := `
CREATE TABLE IF NOT EXISTS briefings (key TEXT PRIMARY KEY, body TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS devices (token TEXT PRIMARY KEY, body TEXT NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sent_alerts (device TEXT NOT NULL, alert_key TEXT NOT NULL, sent_at INTEGER NOT NULL, PRIMARY KEY (device, alert_key));
CREATE TABLE IF NOT EXISTS usage (subject TEXT NOT NULL, day TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (subject, day));
CREATE TABLE IF NOT EXISTS purchasers (subject TEXT PRIMARY KEY, environment TEXT NOT NULL, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL);
`
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// ---- briefings (implements ai.Store) -------------------------------------------------

func (s *Store) GetBriefing(key string) (*ai.Briefing, bool) {
	var body string
	if err := s.db.QueryRow(`SELECT body FROM briefings WHERE key = ?`, key).Scan(&body); err != nil {
		return nil, false
	}
	var b ai.Briefing
	if json.Unmarshal([]byte(body), &b) != nil {
		return nil, false
	}
	return &b, true
}

func (s *Store) PutBriefing(key string, b *ai.Briefing) error {
	body, _ := json.Marshal(b)
	_, err := s.db.Exec(`INSERT OR REPLACE INTO briefings (key, body, created_at) VALUES (?, ?, ?)`, key, string(body), time.Now().Unix())
	return err
}

// ---- devices -----------------------------------------------------------------------------

func (s *Store) UpsertDevice(d Device) error {
	d.UpdatedAt = time.Now().UTC()
	body, _ := json.Marshal(d)
	_, err := s.db.Exec(`INSERT INTO devices (token, body, updated_at) VALUES (?, ?, ?)
ON CONFLICT(token) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`, d.Token, string(body), d.UpdatedAt.Unix())
	return err
}

func (s *Store) DeleteDevice(token string) error {
	_, err := s.db.Exec(`DELETE FROM devices WHERE token = ?`, token)
	return err
}

func (s *Store) Devices() ([]Device, error) {
	rows, err := s.db.Query(`SELECT body FROM devices WHERE updated_at > ?`, time.Now().Add(-60*24*time.Hour).Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		var body string
		if rows.Scan(&body) != nil {
			continue
		}
		var d Device
		if json.Unmarshal([]byte(body), &d) == nil {
			out = append(out, d)
		}
	}
	return out, rows.Err()
}

// MarkSent records an alert for a device; it returns false if it was already sent.
func (s *Store) MarkSent(device, key string) (bool, error) {
	res, err := s.db.Exec(`INSERT OR IGNORE INTO sent_alerts (device, alert_key, sent_at) VALUES (?, ?, ?)`, device, key, time.Now().Unix())
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

func (s *Store) PruneSent(olderThan time.Duration) {
	_, _ = s.db.Exec(`DELETE FROM sent_alerts WHERE sent_at < ?`, time.Now().Add(-olderThan).Unix())
	_, _ = s.db.Exec(`DELETE FROM briefings WHERE created_at < ?`, time.Now().Add(-72*time.Hour).Unix())
	_, _ = s.db.Exec(`DELETE FROM usage WHERE day < ?`, time.Now().Add(-14*24*time.Hour).Format("2006-01-02"))
}

// ---- usage quotas ------------------------------------------------------------------------

var ErrQuota = errors.New("daily quota exceeded")

// Consume increments today's counter for subject, failing once limit is reached.
func (s *Store) Consume(subject string, limit int) (remaining int, err error) {
	day := time.Now().UTC().Format("2006-01-02")
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var count int
	_ = tx.QueryRow(`SELECT count FROM usage WHERE subject = ? AND day = ?`, subject, day).Scan(&count)
	if count >= limit {
		return 0, ErrQuota
	}
	if _, err := tx.Exec(`INSERT INTO usage (subject, day, count) VALUES (?, ?, 1)
ON CONFLICT(subject, day) DO UPDATE SET count = count + 1`, subject, day); err != nil {
		return 0, err
	}
	return limit - count - 1, tx.Commit()
}

func (s *Store) Remaining(subject string, limit int) int {
	var count int
	_ = s.db.QueryRow(`SELECT count FROM usage WHERE subject = ? AND day = ?`, subject, time.Now().UTC().Format("2006-01-02")).Scan(&count)
	return max(0, limit-count)
}

func (s *Store) RecordPurchaser(subject, env string) {
	now := time.Now().Unix()
	_, _ = s.db.Exec(`INSERT INTO purchasers (subject, environment, first_seen, last_seen) VALUES (?, ?, ?, ?)
ON CONFLICT(subject) DO UPDATE SET last_seen = excluded.last_seen`, subject, env, now, now)
}

func (s *Store) Stats() map[string]int {
	out := map[string]int{}
	for name, q := range map[string]string{
		"devices":    `SELECT COUNT(*) FROM devices`,
		"purchasers": `SELECT COUNT(*) FROM purchasers`,
		"briefings":  `SELECT COUNT(*) FROM briefings`,
	} {
		var n int
		_ = s.db.QueryRow(q).Scan(&n)
		out[name] = n
	}
	return out
}
