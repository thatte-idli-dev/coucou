package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

func randomID() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("secure randomness unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}

type status struct {
	Online       bool   `json:"online"`
	Tuned        bool   `json:"tuned"`
	Transmitting bool   `json:"transmitting"`
	Revision     uint64 `json:"revision"`
	TuningEpoch  uint64 `json:"tuning_epoch"`
}
type event struct {
	Epoch         string          `json:"epoch"`
	Sequence      uint64          `json:"sequence"`
	ChannelID     string          `json:"channel_id"`
	SessionID     string          `json:"session_id"`
	Member        string          `json:"member"`
	Local         status          `json:"local"`
	Peer          status          `json:"peer"`
	NegotiationID string          `json:"negotiation_id"`
	From          string          `json:"from,omitempty"`
	Kind          string          `json:"kind,omitempty"`
	Payload       json.RawMessage `json:"payload,omitempty"`
}
type envelope struct {
	name string
	data event
}
type session struct {
	tokenHash [32]byte
	control   bucket
	id        string
	state     status
	lease     time.Time
	events    chan envelope
	done      chan struct{}
	timer     *time.Timer
}
type bucket struct {
	tokens  float64
	updated time.Time
}

func (b *bucket) allow(now time.Time, rate, burst float64) bool {
	if b.updated.IsZero() {
		b.tokens = burst
	} else {
		b.tokens = min(burst, b.tokens+now.Sub(b.updated).Seconds()*rate)
	}
	b.updated = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

type channel struct {
	// ponytail: one lock covers exactly two slots; split only if room capacity changes.
	mu          sync.Mutex
	config      Config
	room        int
	hash        [32]byte
	admission   bucket
	epoch       string
	sequence    uint64
	negotiation string
	slots       [2]*session
}

func memberName(i int) string                         { return string(rune('A' + i)) }
func roomChannelID(namespace string, room int) string { return namespace + ":" + strconv.Itoa(room) }
func (s *channel) snapshot(i int) event {
	v := event{Epoch: s.epoch, Sequence: s.sequence, ChannelID: roomChannelID(s.config.ChannelID, s.room), Member: memberName(i)}
	if slot := s.slots[i]; slot != nil {
		v.SessionID = slot.id
		v.Local = slot.state
		if peer := s.slots[1-i]; peer != nil {
			v.Peer = peer.state
			v.NegotiationID = s.negotiation
		}
	}
	return v
}
func (s *channel) drop(i int) {
	if slot := s.slots[i]; slot != nil {
		slot.timer.Stop()
		close(slot.done)
		s.slots[i] = nil
		s.negotiation = ""
	}
}
func (s *channel) broadcast() {
	for {
		s.sequence++
		evicted := false
		for i, slot := range s.slots {
			if slot == nil {
				continue
			}
			e := envelope{"state", s.snapshot(i)}
			select {
			case slot.events <- e:
			default:
				s.drop(i)
				evicted = true
			}
		}
		if !evicted {
			return
		}
	}
}
func (s *channel) expire(now time.Time) {
	changed := false
	for i, slot := range s.slots {
		if slot != nil && !now.Before(slot.lease) {
			s.drop(i)
			changed = true
		}
	}
	if changed {
		s.broadcast()
	}
}
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 64*1024+1024)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var large *http.MaxBytesError
		if errors.As(err, &large) {
			http.Error(w, "body too large", 413)
		} else {
			http.Error(w, "invalid body", 400)
		}
		return false
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	err = d.Decode(v)
	if err == nil {
		var extra any
		if d.Decode(&extra) != io.EOF {
			err = errors.New("trailing JSON")
		}
	}
	if err != nil {
		http.Error(w, "invalid JSON", 400)
		return false
	}
	return true
}
func (s *channel) events(w http.ResponseWriter, r *http.Request) {
	rc := http.NewResponseController(w)
	s.mu.Lock()
	s.expire(time.Now())
	i := -1
	for n, slot := range s.slots {
		if slot == nil {
			i = n
			break
		}
	}
	if i < 0 {
		s.mu.Unlock()
		writeError(w, 409, "channel_full")
		return
	}
	// Unsupported deadlines cannot provide the stream's bounded failure guarantee.
	if err := rc.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		s.mu.Unlock()
		writeError(w, 503, "unavailable")
		return
	}
	token := randomID()
	slot := &session{tokenHash: sha256.Sum256([]byte(token)), id: randomID(), state: status{Online: true}, lease: time.Now().Add(35 * time.Second), events: make(chan envelope, 64), done: make(chan struct{})}
	s.slots[i] = slot
	slot.timer = time.AfterFunc(35*time.Second, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.slots[i] != slot {
			return
		}
		s.expire(time.Now())
		if s.slots[i] == slot {
			slot.timer.Reset(time.Until(slot.lease))
		}
	})
	s.sequence++
	initial := s.snapshot(i)
	// A new stream always begins with a fresh full snapshot.
	s.broadcast()
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if s.slots[i] == slot {
			s.drop(i)
			s.broadcast()
		}
		s.mu.Unlock()
	}()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	write := func(e envelope) bool {
		if err := rc.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
			return false
		}
		var payload any = e.data
		if e.name == "snapshot" {
			payload = struct {
				Token string `json:"session_token"`
				Event event  `json:"event"`
			}{token, e.data}
		}
		data, _ := json.Marshal(payload)
		_, err := fmt.Fprintf(w, "id: %s:%d\nevent: %s\ndata: %s\n\n", e.data.Epoch, e.data.Sequence, e.name, data)
		return err == nil && rc.Flush() == nil
	}
	if !write(envelope{"snapshot", initial}) {
		return
	}
	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-slot.done:
			return
		case e := <-slot.events:
			if !write(e) {
				return
			}
		case <-keepalive.C:
			if err := rc.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
				return
			}
			if _, err := io.WriteString(w, ": keepalive\n\n"); err != nil || rc.Flush() != nil {
				return
			}

		}
	}
}
func (s *channel) presence(w http.ResponseWriter, r *http.Request, i int, expected *session) {
	var cmd struct {
		SessionID    string `json:"session_id"`
		Revision     uint64 `json:"revision"`
		Tuned        bool   `json:"tuned"`
		Transmitting bool   `json:"transmitting"`
		Restart      bool   `json:"restart_negotiation"`
	}
	if !decode(w, r, &cmd) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expire(time.Now())
	slot := s.slots[i]
	if slot == nil || slot != expected || slot.id != cmd.SessionID {
		writeError(w, 409, "stale_session")
		return
	}
	if cmd.Transmitting && !cmd.Tuned {
		http.Error(w, "transmitting requires tuned", 400)
		return
	}
	slot.lease = time.Now().Add(35 * time.Second)
	slot.timer.Reset(35 * time.Second)
	if cmd.Revision <= slot.state.Revision {
		w.WriteHeader(200)
		return
	}
	if cmd.Tuned && !slot.state.Tuned {
		slot.state.TuningEpoch++
	}
	slot.state.Revision = cmd.Revision
	slot.state.Tuned = cmd.Tuned
	slot.state.Transmitting = cmd.Transmitting
	peer := s.slots[1-i]
	if !cmd.Tuned || peer == nil || !peer.state.Tuned {
		s.negotiation = ""
	} else if s.negotiation == "" || cmd.Restart {
		s.negotiation = randomID()
	}
	s.broadcast()
	w.WriteHeader(200)
}
func (s *channel) signal(w http.ResponseWriter, r *http.Request, i int, expected *session) {
	var cmd struct {
		SessionID     string          `json:"session_id"`
		NegotiationID string          `json:"negotiation_id"`
		Kind          string          `json:"kind"`
		Payload       json.RawMessage `json:"payload"`
	}
	if !decode(w, r, &cmd) {
		return
	}
	if len(cmd.Payload) > 64*1024 {
		http.Error(w, "payload too large", 413)
		return
	}
	if len(cmd.Payload) == 0 || string(cmd.Payload) == "null" || (cmd.Kind != "offer" && cmd.Kind != "answer" && cmd.Kind != "candidate") {
		http.Error(w, "invalid signal", 400)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expire(time.Now())
	slot, peer := s.slots[i], s.slots[1-i]
	if slot == nil || slot != expected || slot.id != cmd.SessionID {
		writeError(w, 409, "stale_session")
		return
	}
	if peer == nil || !slot.state.Tuned || !peer.state.Tuned {
		writeError(w, 409, "stale_session")
		return
	}
	if cmd.NegotiationID == "" || cmd.NegotiationID != s.negotiation {
		w.WriteHeader(200)
		return
	}
	if (cmd.Kind == "offer" && i != 0) || (cmd.Kind == "answer" && i != 1) {
		http.Error(w, "invalid negotiation role", 403)
		return
	}
	s.sequence++
	e := s.snapshot(1 - i)
	e.From = memberName(i)
	e.Kind = cmd.Kind
	e.Payload = cmd.Payload
	select {
	case peer.events <- envelope{"signal", e}:
	default:
		s.drop(1 - i)
		s.broadcast()
	}
	w.WriteHeader(200)
}
func (s *channel) ice(w http.ResponseWriter, i int, expected *session) {
	s.mu.Lock()
	s.expire(time.Now())
	slot := s.slots[i]
	owned := slot != nil && slot == expected
	s.mu.Unlock()
	if !owned {
		writeError(w, 409, "stale_session")
		return
	}
	if len(s.config.RelayURLs) == 0 {
		writeError(w, 503, "unavailable")
		return
	}
	expiry := time.Now().Add(time.Hour).Unix()
	username := fmt.Sprintf("%d:%s:%s", expiry, roomChannelID(s.config.ChannelID, s.room), memberName(i))
	mac := hmac.New(sha1.New, []byte(s.config.RelaySecret))
	mac.Write([]byte(username))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(struct {
		URLs         []string `json:"urls"`
		Username     string   `json:"username"`
		Credential   string   `json:"credential"`
		ExpiresAt    int64    `json:"expires_at"`
		RefreshAfter int      `json:"refresh_after"`
	}{s.config.RelayURLs, username, base64.StdEncoding.EncodeToString(mac.Sum(nil)), expiry, 2700})
}

func (s *channel) remove(w http.ResponseWriter, r *http.Request, i int, expected *session) {
	var cmd struct {
		SessionID string `json:"session_id"`
	}
	if !decode(w, r, &cmd) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expire(time.Now())
	if s.slots[i] == nil || s.slots[i] != expected || s.slots[i].id != cmd.SessionID {
		writeError(w, 409, "stale_session")
		return
	}
	s.drop(i)
	s.broadcast()
	w.WriteHeader(204)
}
