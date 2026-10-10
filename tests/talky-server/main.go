package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

type AccessCode struct {
	Version   int    `json:"version"`
	Origin    string `json:"origin"`
	ChannelID string `json:"channel_id"`
	Channel   int    `json:"channel"`
	Token     string `json:"token"`
}

func DecodeAccessCode(code string) (AccessCode, error) {
	var s AccessCode
	if len(code) > 4096 {
		return s, errors.New("invalid access code")
	}
	data, err := base64.RawURLEncoding.Strict().DecodeString(code)
	if err != nil || base64.RawURLEncoding.EncodeToString(data) != code {
		return s, errors.New("invalid access code")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := uniqueFields(data, "version", "origin", "channel_id", "channel", "token"); err != nil {
		return s, errors.New("invalid access code")
	}
	if err := d.Decode(&s); err != nil {
		return AccessCode{}, errors.New("invalid access code")
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return AccessCode{}, errors.New("invalid access code")
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(s.Token)
	if s.Version != 2 || validateOrigin(s.Origin) != nil || s.ChannelID == "" || len(s.ChannelID) > 128 || strings.ContainsAny(s.ChannelID, ":\r\n\t ") || (s.Channel < 1 || s.Channel > 4) || err != nil || len(raw) != 32 || len(s.Token) != 43 {
		return AccessCode{}, errors.New("invalid or unsupported access code")
	}
	return s, nil
}
func setup(c Config, channel int, token string) string {
	data, _ := json.Marshal(AccessCode{2, c.Origin, c.ChannelID, channel, token})
	return base64.RawURLEncoding.EncodeToString(data)
}
func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
func loadConfig(path string) (Config, error) {
	var c Config
	info, err := os.Lstat(path)
	if err != nil {
		return c, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return c, errors.New("config must be a regular mode-0600 file")
	}
	file, err := os.Open(path)
	if err != nil {
		return c, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 32769))
	if err != nil || len(data) > 32768 {
		return c, errors.New("config exceeds limit")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := uniqueFields(data, "version", "origin", "channel_id", "channel_hashes", "relay_urls", "relay_secret", "trusted_proxy_cidrs"); err != nil {
		return c, errors.New("invalid config JSON")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil {
		return c, errors.New("invalid config JSON")
	}
	var hashes []string
	if json.Unmarshal(fields["channel_hashes"], &hashes) != nil || len(hashes) != 4 {
		return c, errors.New("config requires exactly four channel hashes")
	}
	if err := d.Decode(&c); err != nil {
		return c, errors.New("invalid config JSON")
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return c, errors.New("invalid config JSON")
	}
	return c, c.validate()
}
func writeConfig(path string, c Config, exclusive bool) error {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	var file *os.File
	if exclusive {
		file, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	} else {
		file, err = os.CreateTemp(filepath.Dir(path), ".walkied-config-*")
	}
	if err != nil {
		return err
	}
	name := file.Name()
	saved := false
	defer func() {
		file.Close()
		if !saved {
			os.Remove(name)
		}
	}()
	if err = file.Chmod(0600); err != nil {
		return err
	}
	if _, err = file.Write(data); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if !exclusive {
		if err = os.Rename(name, path); err != nil {
			return err
		}
	}
	saved = true
	return nil
}
func run(args []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: walkied init|rotate|serve")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	configPath := flags.String("config", "", "configuration path")
	var origin, listen *string
	var channel *int
	switch args[0] {
	case "init":
		origin = flags.String("origin", "", "HTTPS origin")
	case "rotate":
		channel = flags.Int("channel", 0, "channel 1–4")
	case "serve":
		listen = flags.String("listen", "127.0.0.1:8080", "listen address")
	default:
		return errors.New("unknown command")
	}
	if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 || *configPath == "" {
		return errors.New("invalid arguments: --config is required")
	}
	switch args[0] {
	case "init":
		if err := validateOrigin(*origin); err != nil {
			return err
		}
		c := Config{Version: 2, Origin: *origin, ChannelID: randomID(), RelayURLs: []string{}, TrustedProxyCIDRs: []string{}}
		var tokens [4]string
		for i := range tokens {
			tokens[i] = randomID()
			c.ChannelHashes[i] = tokenHash(tokens[i])
		}
		if err := writeConfig(*configPath, c, true); err != nil {
			return err
		}
		for i, token := range tokens {
			if _, err := fmt.Fprintf(out, "Channel %d: %s\n", i+1, setup(c, i+1, token)); err != nil {
				return err
			}
		}
		return nil
	case "rotate":
		if *channel < 1 || *channel > 4 {
			return errors.New("channel must be 1–4")
		}
		c, err := loadConfig(*configPath)
		if err != nil {
			return err
		}
		token := randomID()
		c.ChannelHashes[*channel-1] = tokenHash(token)
		if err := writeConfig(*configPath, c, false); err != nil {
			return err
		}
		_, err = fmt.Fprintf(out, "Channel %d: %s\n", *channel, setup(c, *channel, token))
		return err
	case "serve":
		c, err := loadConfig(*configPath)
		if err != nil {
			return err
		}
		host, _, err := net.SplitHostPort(*listen)
		if err != nil {
			return errors.New("invalid listen address")
		}
		ip := net.ParseIP(host)
		if (ip == nil || !ip.IsLoopback()) && len(c.TrustedProxyCIDRs) == 0 {
			return errors.New("non-loopback listening requires a trusted TLS proxy")
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		server := &http.Server{Addr: *listen, Handler: NewServer(c), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 8192, BaseContext: func(net.Listener) context.Context { return ctx }}
		done := make(chan error, 1)
		go func() { done <- server.ListenAndServe() }()
		select {
		case err := <-done:
			if errors.Is(err, http.ErrServerClosed) {
				return nil
			}
			return err
		case <-ctx.Done():
			shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			return server.Shutdown(shutdown)
		}
	}
	return nil
}
func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// encoding/json permits duplicate keys; credential and config envelopes do not.
func uniqueFields(data []byte, fields ...string) error {
	if !utf8.Valid(data) {
		return errors.New("invalid UTF-8")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	token, err := d.Token()
	if err != nil || token != json.Delim('{') {
		return errors.New("expected object")
	}
	seen := map[string]bool{}
	for d.More() {
		key, err := d.Token()
		if err != nil {
			return err
		}
		name, ok := key.(string)
		if !ok || seen[name] {
			return errors.New("duplicate field")
		}
		allowed := false
		for _, field := range fields {
			if name == field {
				allowed = true
			}
		}
		if !allowed {
			return errors.New("unknown field")
		}
		seen[name] = true
		var value json.RawMessage
		if err := d.Decode(&value); err != nil {
			return err
		}
	}
	if _, err := d.Token(); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return errors.New("extra JSON")
	}
	return nil
}
