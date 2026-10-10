package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Version           int       `json:"version"`
	Origin            string    `json:"origin"`
	ChannelID         string    `json:"channel_id"`
	ChannelHashes     [4]string `json:"channel_hashes"`
	RelayURLs         []string  `json:"relay_urls"`
	RelaySecret       string    `json:"relay_secret"`
	TrustedProxyCIDRs []string  `json:"trusted_proxy_cidrs"`
}

func validateOrigin(origin string) error {
	u, err := url.Parse(origin)
	// Allow HTTP for localhost/127.0.0.1 testing
	allowHTTP := u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1"
	validScheme := u.Scheme == "https" || (allowHTTP && u.Scheme == "http")
	if err != nil || !validScheme || u.Hostname() == "" || strings.Contains(u.Hostname(), "%") || u.User != nil || u.Path != "" || u.RawQuery != "" || u.ForceQuery || strings.Contains(origin, "#") || u.Fragment != "" || u.Opaque != "" || strings.ContainsAny(origin, "\r\n\t ") {
		return errors.New("origin must be an HTTPS origin without path, credentials, query, or fragment")
	}
	if u.Port() != "" {
		p, err := strconv.Atoi(u.Port())
		if err != nil || p < 1 || p > 65535 {
			return errors.New("invalid origin port")
		}
	}
	return nil
}
func (c Config) validate() error {
	if c.Version != 2 {
		return errors.New("unsupported configuration version")
	}
	if err := validateOrigin(c.Origin); err != nil {
		return err
	}
	if c.ChannelID == "" || len(c.ChannelID) > 128 || strings.ContainsAny(c.ChannelID, ":\r\n\t ") {
		return errors.New("invalid channel id")
	}
	seen := map[string]bool{}
	for _, hash := range c.ChannelHashes {
		b, err := hex.DecodeString(hash)
		if err != nil || len(b) != 32 {
			return errors.New("invalid channel hash")
		}
		canonical := strings.ToLower(hash)
		if seen[canonical] {
			return errors.New("channel hashes must differ")
		}
		seen[canonical] = true
	}
	if (len(c.RelayURLs) > 0) != (c.RelaySecret != "") {
		return errors.New("relay URLs and secret must be configured together")
	}
	for _, raw := range c.RelayURLs {
		u, err := url.Parse(raw)
		if err != nil || (u.Scheme != "turn" && u.Scheme != "turns") || u.Opaque == "" || strings.ContainsAny(raw, "\r\n ") {
			return errors.New("invalid TURN URL")
		}
	}
	for _, cidr := range c.TrustedProxyCIDRs {
		if _, err := netip.ParsePrefix(cidr); err != nil {
			return errors.New("invalid trusted proxy CIDR")
		}
	}
	return nil
}

type service struct {
	mu        sync.Mutex
	config    Config
	rooms     [4]*channel
	proxies   []netip.Prefix
	anonymous bucket
	ips       map[netip.Addr]*bucket
}

func NewServer(c Config) http.Handler {
	if err := c.validate(); err != nil {
		panic(err)
	}
	s := &service{config: c, ips: make(map[netip.Addr]*bucket)}
	for i, h := range c.ChannelHashes {
		room := &channel{config: c, room: i + 1, epoch: randomID()}
		b, _ := hex.DecodeString(h)
		copy(room.hash[:], b)
		s.rooms[i] = room
	}
	for _, p := range c.TrustedProxyCIDRs {
		prefix, _ := netip.ParsePrefix(p)
		s.proxies = append(s.proxies, prefix)
	}
	return s
}
func parseRoomRoute(path string) (int, string, bool) {
	parts := strings.Split(path, "/")
	if len(parts) != 5 || parts[1] != "v3" || parts[2] != "channels" || len(parts[3]) != 1 || parts[3][0] < '1' || parts[3][0] > '4' {
		return 0, "", false
	}
	endpoint := parts[4]
	return int(parts[3][0] - '0'), endpoint, endpoint == "access" || endpoint == "events" || endpoint == "presence" || endpoint == "signal" || endpoint == "ice" || endpoint == "session"
}
func writeError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(struct {
		Error string `json:"error"`
	}{code})
}
func (s *service) requestIP(r *http.Request) (netip.Addr, bool) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return netip.Addr{}, false
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return netip.Addr{}, false
	}
	ip = ip.Unmap()
	for _, p := range s.proxies {
		if p.Contains(ip) {
			return ip, true
		}
	}
	return ip, false
}
func (s *service) reject(w http.ResponseWriter, ip netip.Addr) {
	s.mu.Lock()
	now := time.Now()
	global := s.anonymous.allow(now, 20, 100)
	for addr, limit := range s.ips {
		if now.Sub(limit.updated) > time.Minute {
			delete(s.ips, addr)
		}
	}
	limit := s.ips[ip]
	if limit == nil && len(s.ips) < 1024 {
		limit = &bucket{}
		s.ips[ip] = limit
	}
	allowed := limit != nil && limit.allow(now, 1, 20)
	s.mu.Unlock()
	if !global || !allowed {
		w.Header().Set("Retry-After", "1")
		writeError(w, 429, "rate_limited")
	} else {
		writeError(w, 401, "invalid_access")
	}
}
func (s *service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.URL.Path == "/healthz" && r.Method == "GET" {
		w.WriteHeader(200)
		return
	}
	if r.URL.Path == "/v1" || strings.HasPrefix(r.URL.Path, "/v1/") || r.URL.Path == "/v2" || strings.HasPrefix(r.URL.Path, "/v2/") {
		writeError(w, 410, "unsupported_protocol")
		return
	}
	number, endpoint, ok := parseRoomRoute(r.URL.Path)
	if !ok || ((endpoint == "access" || endpoint == "events" || endpoint == "ice") && r.Method != "GET") || ((endpoint == "presence" || endpoint == "signal") && r.Method != "POST") || (endpoint == "session" && r.Method != "DELETE") {
		http.NotFound(w, r)
		return
	}
	room := s.rooms[number-1]
	ip, trusted := s.requestIP(r)
	auth := r.Header.Get("Authorization")
	token := strings.TrimPrefix(auth, "Bearer ")
	digest := sha256.Sum256([]byte(token))
	valid := strings.HasPrefix(auth, "Bearer ") && len(token) == 43
	room.mu.Lock()
	now := time.Now()
	room.expire(now)
	i := -1
	var slot *session
	var allowed bool
	if endpoint == "access" || endpoint == "events" {
		if subtle.ConstantTimeCompare(digest[:], room.hash[:]) == 1 && valid {
			i = 0
			allowed = room.admission.allow(now, 2, 60)
		}
	} else {
		// Compare every live slot under its room lock; public IDs never authenticate.
		for n, candidate := range room.slots {
			var hash [32]byte
			if candidate != nil {
				hash = candidate.tokenHash
			}
			matches := subtle.ConstantTimeCompare(digest[:], hash[:])
			if matches == 1 && candidate != nil && valid {
				i = n
				slot = candidate
			}
		}
		if slot != nil {
			allowed = slot.control.allow(now, 2, 60)
		}
	}
	room.mu.Unlock()
	if i < 0 {
		s.reject(w, ip)
		return
	}
	if !allowed {
		w.Header().Set("Retry-After", "1")
		writeError(w, 429, "rate_limited")
		return
	}
	if r.TLS == nil && !ip.IsLoopback() && !(trusted && r.Header.Get("X-Forwarded-Proto") == "https") {
		http.Error(w, "HTTPS required", 400)
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" && origin != s.config.Origin {
		http.Error(w, "origin rejected", 403)
		return
	}
	switch endpoint {
	case "access":
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(struct {
			ID string `json:"channel_id"`
		}{roomChannelID(s.config.ChannelID, number)})
	case "events":
		room.events(w, r)
	case "presence":
		room.presence(w, r, i, slot)
	case "signal":
		room.signal(w, r, i, slot)
	case "ice":
		room.ice(w, i, slot)
	case "session":
		room.remove(w, r, i, slot)
	}
}
