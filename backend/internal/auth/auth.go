// Package auth proves that a caller bought the app (StoreKit 2 AppTransaction JWS signed by
// Apple) and issues short HMAC session tokens for the metered AI endpoints.
package auth

import (
	"crypto/ecdsa"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"
)

//go:embed AppleRootCA-G3.pem
var appleRootPEM []byte

var (
	ErrInvalid = errors.New("invalid credentials")
	ErrExpired = errors.New("token expired")

	oidAppleLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidAppleIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

type Config struct {
	BundleID     string
	AppAppleID   int64 // 0 skips the check (unknown before the first App Store release)
	AllowSandbox bool
	DevToken     string
}

type Verifier struct {
	cfg    Config
	secret []byte
	root   *x509.Certificate
}

// Claims are what a session token carries.
type Claims struct {
	Subject     string `json:"sub"`
	Environment string `json:"env"`
	ExpiresAt   int64  `json:"exp"`
}

// AppTransaction is the subset of StoreKit's AppTransaction payload we rely on.
type AppTransaction struct {
	BundleID                   string `json:"bundleId"`
	AppAppleID                 int64  `json:"appAppleId"`
	Environment                string `json:"environment"`
	AppTransactionID           string `json:"appTransactionId"`
	OriginalPurchaseDate       int64  `json:"originalPurchaseDate"`
	DeviceVerification         string `json:"deviceVerification"`
	OriginalApplicationVersion string `json:"originalApplicationVersion"`
}

func NewVerifier(cfg Config, dataDir string) (*Verifier, error) {
	block, _ := pem.Decode(appleRootPEM)
	if block == nil {
		return nil, errors.New("embedded Apple root certificate is unreadable")
	}
	root, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	secret, err := loadOrCreateSecret(filepath.Join(dataDir, "token.secret"))
	if err != nil {
		return nil, err
	}
	return &Verifier{cfg: cfg, secret: secret, root: root}, nil
}

func loadOrCreateSecret(path string) ([]byte, error) {
	if b, err := os.ReadFile(path); err == nil && len(b) >= 32 {
		return b, nil
	}
	b := make([]byte, 48)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return b, os.WriteFile(path, b, 0o600)
}

// VerifyAppTransaction validates an AppTransaction JWS and returns its payload.
func (v *Verifier) VerifyAppTransaction(jws string) (*AppTransaction, error) {
	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		return nil, ErrInvalid
	}
	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, ErrInvalid
	}
	var header struct {
		Alg string   `json:"alg"`
		X5C []string `json:"x5c"`
	}
	if json.Unmarshal(headerJSON, &header) != nil || header.Alg != "ES256" || len(header.X5C) < 2 {
		return nil, ErrInvalid
	}
	certs := make([]*x509.Certificate, 0, len(header.X5C))
	for _, c := range header.X5C {
		der, err := base64.StdEncoding.DecodeString(c)
		if err != nil {
			return nil, ErrInvalid
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, ErrInvalid
		}
		certs = append(certs, cert)
	}
	leaf := certs[0]
	inter := x509.NewCertPool()
	for _, c := range certs[1:] {
		inter.AddCert(c)
	}
	roots := x509.NewCertPool()
	roots.AddCert(v.root)
	// Apple's JWS leaf certificates are validated at signing time, as Apple's own libraries do.
	verifyAt := time.Now()
	if raw, err := base64.RawURLEncoding.DecodeString(parts[1]); err == nil {
		var signed struct {
			SignedDate int64 `json:"signedDate"`
		}
		if json.Unmarshal(raw, &signed) == nil && signed.SignedDate > 0 {
			verifyAt = time.UnixMilli(signed.SignedDate)
		}
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: inter, CurrentTime: verifyAt, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
		return nil, fmt.Errorf("%w: chain: %v", ErrInvalid, err)
	}
	if !hasExtension(leaf, oidAppleLeaf) || !hasExtension(certs[1], oidAppleIntermediate) {
		return nil, fmt.Errorf("%w: unexpected certificate profile", ErrInvalid)
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, ErrInvalid
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return nil, ErrInvalid
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, digest[:], r, s) {
		return nil, fmt.Errorf("%w: signature", ErrInvalid)
	}
	payloadJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, ErrInvalid
	}
	var tx AppTransaction
	if err := json.Unmarshal(payloadJSON, &tx); err != nil {
		return nil, ErrInvalid
	}
	if tx.BundleID != v.cfg.BundleID {
		return nil, fmt.Errorf("%w: bundle %q", ErrInvalid, tx.BundleID)
	}
	switch tx.Environment {
	case "Production":
		if v.cfg.AppAppleID != 0 && tx.AppAppleID != v.cfg.AppAppleID {
			return nil, fmt.Errorf("%w: app id", ErrInvalid)
		}
	case "Sandbox":
		if !v.cfg.AllowSandbox {
			return nil, fmt.Errorf("%w: sandbox not allowed", ErrInvalid)
		}
	default:
		return nil, fmt.Errorf("%w: environment %q", ErrInvalid, tx.Environment)
	}
	return &tx, nil
}

func hasExtension(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}

// SubjectFor derives a stable, non-reversible purchaser id.
func SubjectFor(tx *AppTransaction) string {
	seed := tx.AppTransactionID
	if seed == "" {
		seed = fmt.Sprintf("%d:%s", tx.OriginalPurchaseDate, tx.DeviceVerification)
	}
	sum := sha256.Sum256([]byte("karman:" + seed))
	return hex.EncodeToString(sum[:12])
}

// Issue mints a session token.
func (v *Verifier) Issue(subject, env string, ttl time.Duration) (string, time.Time) {
	exp := time.Now().Add(ttl)
	payload, _ := json.Marshal(Claims{Subject: subject, Environment: env, ExpiresAt: exp.Unix()})
	p := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, v.secret)
	mac.Write([]byte(p))
	return p + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), exp
}

// Check validates "Bearer <token>" or, when configured, "Dev <token>" authorization headers.
func (v *Verifier) Check(authorization string) (*Claims, error) {
	kind, value, ok := strings.Cut(strings.TrimSpace(authorization), " ")
	if !ok {
		return nil, ErrInvalid
	}
	switch kind {
	case "Dev":
		if v.cfg.DevToken != "" && hmac.Equal([]byte(value), []byte(v.cfg.DevToken)) {
			return &Claims{Subject: "dev", Environment: "Xcode", ExpiresAt: time.Now().Add(time.Hour).Unix()}, nil
		}
		return nil, ErrInvalid
	case "Bearer":
		p, sig, ok := strings.Cut(value, ".")
		if !ok {
			return nil, ErrInvalid
		}
		mac := hmac.New(sha256.New, v.secret)
		mac.Write([]byte(p))
		want := mac.Sum(nil)
		got, err := base64.RawURLEncoding.DecodeString(sig)
		if err != nil || !hmac.Equal(got, want) {
			return nil, ErrInvalid
		}
		raw, err := base64.RawURLEncoding.DecodeString(p)
		if err != nil {
			return nil, ErrInvalid
		}
		var c Claims
		if json.Unmarshal(raw, &c) != nil {
			return nil, ErrInvalid
		}
		if time.Now().Unix() > c.ExpiresAt {
			return nil, ErrExpired
		}
		return &c, nil
	}
	return nil, ErrInvalid
}
