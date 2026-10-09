package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"
)

type Server struct {
	mu       sync.Mutex
	channels map[int]*Channel
}

type Channel struct {
	mu          sync.Mutex
	accessCodes map[string]bool
	sessions    map[string]*Session
}

type Session struct {
	ID            string
	Token         string
	Member        string
	Tuned         bool
	Transmitting  bool
	Revision      int
	EventChan     chan ServerEvent
	LastHeartbeat time.Time
}

type ServerEvent struct {
	Event string
	Data  interface{}
}

func NewServer() *Server {
	return &Server{
		channels: make(map[int]*Channel),
	}
}

func (s *Server) getOrCreateChannel(id int) *Channel {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.channels[id] == nil {
		s.channels[id] = &Channel{
			accessCodes: make(map[string]bool),
			sessions:    make(map[string]*Session),
		}
	}
	return s.channels[id]
}

func randomToken(prefix string) string {
	b := make([]byte, 8)
	rand.Read(b)
	return prefix + hex.EncodeToString(b)
}

func (s *Server) handleCreateAccess(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	channelID := 1
	ch := s.getOrCreateChannel(channelID)
	
	code := randomToken("code_")
	ch.mu.Lock()
	ch.accessCodes[code] = true
	ch.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"access_code": code})
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	auth := r.Header.Get("Authorization")
	if auth == "" || len(auth) < 8 {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	accessCode := auth[7:] // Remove "Bearer "

	channelID := 1
	ch := s.getOrCreateChannel(channelID)
	
	ch.mu.Lock()
	if !ch.accessCodes[accessCode] {
		ch.mu.Unlock()
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if len(ch.sessions) >= 2 {
		ch.mu.Unlock()
		http.Error(w, "Channel full", http.StatusConflict)
		return
	}

	sessionID := randomToken("sess_")
	sessionToken := randomToken("tok_")
	member := "A"
	if len(ch.sessions) == 1 {
		member = "B"
	}

	session := &Session{
		ID:            sessionID,
		Token:         sessionToken,
		Member:        member,
		EventChan:     make(chan ServerEvent, 100),
		LastHeartbeat: time.Now(),
	}
	ch.sessions[sessionID] = session
	ch.mu.Unlock()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming not supported", http.StatusInternalServerError)
		return
	}

	// Send join event
	joinData := map[string]interface{}{
		"session_token": sessionToken,
		"event": map[string]interface{}{
			"session_id":     sessionID,
			"member":         member,
			"local":          map[string]bool{"tuned": false, "transmitting": false},
			"peer":           nil,
			"negotiation_id": nil,
		},
	}
	fmt.Fprintf(w, "event: join\n")
	jsonBytes, _ := json.Marshal(joinData)
	fmt.Fprintf(w, "data: %s\n\n", jsonBytes)
	flusher.Flush()

	// Keep connection alive and send events
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			fmt.Fprintf(w, ": keepalive\n\n")
			flusher.Flush()
		case event := <-session.EventChan:
			fmt.Fprintf(w, "event: %s\n", event.Event)
			jsonBytes, _ := json.Marshal(event.Data)
			fmt.Fprintf(w, "data: %s\n\n", jsonBytes)
			flusher.Flush()
		case <-r.Context().Done():
			ch.mu.Lock()
			delete(ch.sessions, sessionID)
			ch.mu.Unlock()
			return
		}
	}
}

func (s *Server) handlePresence(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	auth := r.Header.Get("Authorization")
	if auth == "" || len(auth) < 8 {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	sessionToken := auth[7:]

	var body map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	sessionID := body["session_id"].(string)
	tuned := body["tuned"].(bool)
	transmitting := body["transmitting"].(bool)
	revision := int(body["revision"].(float64))

	channelID := 1
	ch := s.getOrCreateChannel(channelID)
	
	ch.mu.Lock()
	defer ch.mu.Unlock()

	var sess *Session
	for _, s := range ch.sessions {
		if s.Token == sessionToken && s.ID == sessionID {
			sess = s
			break
		}
	}

	if sess == nil {
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}

	if revision <= sess.Revision {
		w.WriteHeader(http.StatusOK)
		return
	}

	sess.Tuned = tuned
	sess.Transmitting = transmitting
	sess.Revision = revision
	sess.LastHeartbeat = time.Now()

	w.WriteHeader(http.StatusOK)
}

func (s *Server) handleSignal(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	auth := r.Header.Get("Authorization")
	if auth == "" || len(auth) < 8 {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	sessionToken := auth[7:]

	var body map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	_ = body["kind"]
	payload := body["payload"].(map[string]interface{})

	channelID := 1
	ch := s.getOrCreateChannel(channelID)
	
	ch.mu.Lock()
	defer ch.mu.Unlock()

	var fromSession string
	for _, s := range ch.sessions {
		if s.Token == sessionToken {
			fromSession = s.ID
			break
		}
	}

	if fromSession == "" {
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}

	// Broadcast to other sessions
	for _, s := range ch.sessions {
		if s.ID != fromSession {
			signalEvent := ServerEvent{
				Event: "signal",
				Data: map[string]interface{}{
					"from":    fromSession,
					"payload": payload,
				},
			}
			select {
			case s.EventChan <- signalEvent:
			default:
			}
		}
	}

	w.WriteHeader(http.StatusOK)
}

func (s *Server) handleICE(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	auth := r.Header.Get("Authorization")
	if auth == "" || len(auth) < 8 {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	// Return mock STUN and TURN servers
	response := map[string]interface{}{
		"ice_servers": []map[string]interface{}{
			{"urls": "stun:stun.l.google.com:19302"},
			{
				"urls":       "turn:turn.example.com:3478",
				"username":   "testuser",
				"credential": "testpass",
			},
		},
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func (s *Server) handleDeleteSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	auth := r.Header.Get("Authorization")
	if auth == "" || len(auth) < 8 {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	sessionToken := auth[7:]

	var body map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	sessionID := body["session_id"].(string)

	channelID := 1
	ch := s.getOrCreateChannel(channelID)
	
	ch.mu.Lock()
	defer ch.mu.Unlock()

	for _, s := range ch.sessions {
		if s.Token == sessionToken && s.ID == sessionID {
			delete(ch.sessions, sessionID)
			close(s.EventChan)
			w.WriteHeader(http.StatusOK)
			return
		}
	}

	http.Error(w, "Session not found", http.StatusNotFound)
}

func main() {
	s := NewServer()

	http.HandleFunc("/v3/channels/1/access", s.handleCreateAccess)
	http.HandleFunc("/v3/channels/1/events", s.handleEvents)
	http.HandleFunc("/v3/channels/1/presence", s.handlePresence)
	http.HandleFunc("/v3/channels/1/signal", s.handleSignal)
	http.HandleFunc("/v3/channels/1/ice", s.handleICE)
	http.HandleFunc("/v3/channels/1/session", s.handleDeleteSession)

	log.Println("Server starting on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
