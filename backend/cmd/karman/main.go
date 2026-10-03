// Command karman runs the Kármán API: live planet state, satellites, imagery, AI briefings
// and push alerts for the iOS app.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"karman/internal/ai"
	"karman/internal/auth"
	"karman/internal/feeds"
	"karman/internal/httpapi"
	"karman/internal/push"
	"karman/internal/store"
)

var version = "1.0.0"

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "gencert" {
		genCert(os.Args[2:])
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "site" {
		exportSite(os.Args[2:])
		return
	}

	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	dataDir := env("KARMAN_DATA_DIR", "./data")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		log.Error("data dir", "err", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	hub := feeds.NewHub(log, filepath.Join(dataDir, "cache"), env("NASA_API_KEY", "DEMO_KEY"))
	hub.Start(ctx)
	hub.StartImagery(ctx)
	hub.StartSunFrames(ctx)
	go hub.PersistLoop(ctx)

	st, err := store.Open(dataDir)
	if err != nil {
		log.Error("store", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	aiSvc := ai.NewService(log, env("ANTHROPIC_API_KEY", ""), env("KARMAN_AI_MODEL", "claude-opus-5-5"), st, func() ai.Digest {
		return ai.BuildDigest(hub.Current())
	})
	aiSvc.Prewarm(ctx, strings.Split(env("KARMAN_PREWARM_LANGS", "en,tr"), ",")...)

	appID, _ := strconv.ParseInt(env("KARMAN_APPLE_APP_ID", "0"), 10, 64)
	verifier, err := auth.NewVerifier(auth.Config{
		BundleID:     env("KARMAN_BUNDLE_ID", "com.adilemre.karman"),
		AppAppleID:   appID,
		AllowSandbox: env("KARMAN_ALLOW_SANDBOX", "true") == "true",
		DevToken:     env("KARMAN_DEV_TOKEN", ""),
	}, dataDir)
	if err != nil {
		log.Error("auth", "err", err)
		os.Exit(1)
	}

	apns, err := push.NewClient(push.APNsConfig{
		KeyPath: env("APNS_KEY_PATH", ""), KeyID: env("APNS_KEY_ID", ""), TeamID: env("APNS_TEAM_ID", ""),
		Topic: env("KARMAN_BUNDLE_ID", "com.adilemre.karman"),
	})
	if err != nil {
		log.Error("apns", "err", err)
	}
	push.NewEngine(log, hub, st, apns).Start(ctx)

	askLimit, _ := strconv.Atoi(env("KARMAN_ASK_DAILY_LIMIT", "25"))
	api := &httpapi.Server{Log: log, Hub: hub, AI: aiSvc, Auth: verifier, Store: st, AskLimit: askLimit, PushActive: apns != nil, Version: version,
		SupportEmail: env("KARMAN_SUPPORT_EMAIL", ""), SiteDir: env("KARMAN_SITE_DIR", "")}

	srv := &http.Server{
		Addr:              env("KARMAN_ADDR", ":9443"),
		Handler:           api.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()

	cert, key := env("KARMAN_TLS_CERT", ""), env("KARMAN_TLS_KEY", "")
	log.Info("karman api starting", "addr", srv.Addr, "tls", cert != "", "ai", aiSvc.Enabled(), "push", apns != nil, "version", version)
	if cert != "" {
		err = srv.ListenAndServeTLS(cert, key)
	} else {
		err = srv.ListenAndServe()
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("server", "err", err)
		os.Exit(1)
	}
}

// genCert creates a self-signed ECDSA certificate for an IP/hostname and prints the SPKI pin
// the iOS app uses to trust it.
func genCert(args []string) {
	fs := flag.NewFlagSet("gencert", flag.ExitOnError)
	host := fs.String("host", "127.0.0.1", "comma-separated IPs or DNS names")
	out := fs.String("out", ".", "output directory")
	days := fs.Int("days", 820, "validity in days (Apple caps TLS server certs at 825)")
	keyPath := fs.String("key", "", "reuse this PEM private key so the app's pin stays valid")
	_ = fs.Parse(args)

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	if *keyPath != "" {
		pemBytes, err := os.ReadFile(*keyPath)
		if err != nil {
			panic(err)
		}
		block, _ := pem.Decode(pemBytes)
		if block == nil {
			panic("no PEM block in " + *keyPath)
		}
		parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			panic(err)
		}
		ec, ok := parsed.(*ecdsa.PrivateKey)
		if !ok {
			panic("only ECDSA keys are supported")
		}
		key = ec
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "Karman API", Organization: []string{"Karman"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Duration(*days) * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	for _, h := range strings.Split(*host, ",") {
		if ip := net.ParseIP(strings.TrimSpace(h)); ip != nil {
			tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
		} else if h != "" {
			tmpl.DNSNames = append(tmpl.DNSNames, strings.TrimSpace(h))
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		panic(err)
	}
	keyDER, _ := x509.MarshalPKCS8PrivateKey(key)
	_ = os.MkdirAll(*out, 0o755)
	_ = os.WriteFile(filepath.Join(*out, "tls.crt"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	_ = os.WriteFile(filepath.Join(*out, "tls.key"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600)
	spki, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	sum := sha256.Sum256(spki)
	fmt.Println("certificate written to", *out)
	fmt.Println("SPKI SHA-256 pin:", base64.StdEncoding.EncodeToString(sum[:]))
}

// exportSite writes privacy.html and support.html for static hosting (GitHub Pages, your own domain).
func exportSite(args []string) {
	fs := flag.NewFlagSet("site", flag.ExitOnError)
	out := fs.String("out", "site", "output directory")
	email := fs.String("support-email", env("KARMAN_SUPPORT_EMAIL", ""), "contact address shown on the support page")
	_ = fs.Parse(args)
	if err := os.MkdirAll(*out, 0o755); err != nil {
		panic(err)
	}
	for name, body := range httpapi.StaticPages(*email) {
		if err := os.WriteFile(filepath.Join(*out, name), body, 0o644); err != nil {
			panic(err)
		}
		fmt.Println("wrote", filepath.Join(*out, name))
	}
}
