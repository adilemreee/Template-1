// Package push delivers alerts through Apple Push Notification service (token-based auth)
// and decides which device should hear about which planetary event.
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

type APNsConfig struct {
	KeyPath string
	KeyID   string
	TeamID  string
	Topic   string // bundle id
}

type Client struct {
	cfg  APNsConfig
	key  *ecdsa.PrivateKey
	http *http.Client

	mu    sync.Mutex
	jwt   string
	jwtAt time.Time
}

var ErrUnregistered = errors.New("device token is no longer valid")

func NewClient(cfg APNsConfig) (*Client, error) {
	if cfg.KeyPath == "" || cfg.KeyID == "" || cfg.TeamID == "" {
		return nil, nil // push disabled
	}
	raw, err := os.ReadFile(cfg.KeyPath)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("APNs key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("APNs key must be an EC P-256 key (.p8)")
	}
	return &Client{cfg: cfg, key: key, http: &http.Client{Timeout: 15 * time.Second}}, nil
}

func (c *Client) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.jwt != "" && time.Since(c.jwtAt) < 45*time.Minute {
		return c.jwt, nil
	}
	enc := base64.RawURLEncoding
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.cfg.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": c.cfg.TeamID, "iat": time.Now().Unix()})
	signing := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	c.jwt = signing + "." + enc.EncodeToString(sig)
	c.jwtAt = time.Now()
	return c.jwt, nil
}

type Notification struct {
	DeviceToken string
	Sandbox     bool
	Title       string
	Subtitle    string
	Body        string
	ThreadID    string
	Critical    bool // time-sensitive interruption level
	CollapseID  string
	Data        map[string]any
}

func (c *Client) Send(ctx context.Context, n Notification) error {
	jwt, err := c.token()
	if err != nil {
		return err
	}
	host := "https://api.push.apple.com"
	if n.Sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	alert := map[string]any{"title": n.Title, "body": n.Body}
	if n.Subtitle != "" {
		alert["subtitle"] = n.Subtitle
	}
	aps := map[string]any{"alert": alert, "sound": "default", "thread-id": n.ThreadID, "mutable-content": 1}
	if n.Critical {
		aps["interruption-level"] = "time-sensitive"
	}
	payload := map[string]any{"aps": aps}
	if n.Data != nil {
		payload["karman"] = n.Data
	}
	body, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+n.DeviceToken, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", c.cfg.Topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(6*time.Hour).Unix()))
	if n.CollapseID != "" {
		req.Header.Set("apns-collapse-id", n.CollapseID)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	var reason struct {
		Reason string `json:"reason"`
	}
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	_ = json.Unmarshal(b, &reason)
	if resp.StatusCode == http.StatusGone || reason.Reason == "BadDeviceToken" || reason.Reason == "Unregistered" || reason.Reason == "DeviceTokenNotForTopic" {
		return ErrUnregistered
	}
	return fmt.Errorf("apns %d: %s", resp.StatusCode, reason.Reason)
}
