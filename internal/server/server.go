// Package server implements the whoami-ng HTTP API and static frontend.
package server

import (
	"encoding/json"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"runtime"
	"sort"
	"time"
)

// Server holds shared state for the whoami-ng HTTP handlers.
type Server struct {
	version   string
	startTime time.Time
}

// New builds the whoami-ng HTTP handler, serving the API under /api and the
// embedded frontend (assets) for everything else.
func New(assets fs.FS, version string) http.Handler {
	s := &Server{
		version:   version,
		startTime: time.Now(),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/whoami", s.handleWhoami)
	mux.HandleFunc("GET /api/version", s.handleVersion)
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /readyz", s.handleHealthz)
	mux.HandleFunc("GET /api/generate/stream", s.handleGenerateStream)
	mux.Handle("GET /", http.FileServerFS(assets))

	return withLogging(mux)
}

// withLogging logs each request's method, path, status and latency to
// stdout, so `kubectl logs` shows real traffic — handy while learning how
// requests flow through a Service/Ingress into a pod.
func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		lrw := &loggingResponseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(lrw, r)
		log.Printf("%s %s %d %s %s", r.Method, r.URL.Path, lrw.status, time.Since(start).Round(time.Microsecond), r.RemoteAddr)
	})
}

type loggingResponseWriter struct {
	http.ResponseWriter
	status int
}

func (w *loggingResponseWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

// Flush lets the SSE generator endpoint stream through the logging wrapper.
func (w *loggingResponseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// RequestInfo describes the HTTP request as seen by the server.
type RequestInfo struct {
	Method     string      `json:"method"`
	URL        string      `json:"url"`
	Proto      string      `json:"proto"`
	Host       string      `json:"host"`
	RemoteAddr string      `json:"remoteAddr"`
	Headers    http.Header `json:"headers"`
}

// WhoamiResponse describes this instance of whoami-ng: which pod answered,
// where it's running, and details of the request that reached it.
type WhoamiResponse struct {
	Hostname       string      `json:"hostname"`
	IPs            []string    `json:"ips"`
	PodName        string      `json:"podName,omitempty"`
	PodIP          string      `json:"podIP,omitempty"`
	Namespace      string      `json:"namespace,omitempty"`
	NodeName       string      `json:"nodeName,omitempty"`
	ServiceAccount string      `json:"serviceAccount,omitempty"`
	OS             string      `json:"os"`
	Arch           string      `json:"arch"`
	GoVersion      string      `json:"goVersion"`
	Version        string      `json:"version"`
	StartTime      time.Time   `json:"startTime"`
	Uptime         string      `json:"uptime"`
	Timestamp      time.Time   `json:"timestamp"`
	Request        RequestInfo `json:"request"`
}

func (s *Server) handleWhoami(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()

	resp := WhoamiResponse{
		Hostname:       hostname,
		IPs:            localIPs(),
		PodName:        firstNonEmpty(os.Getenv("POD_NAME"), hostname),
		PodIP:          os.Getenv("POD_IP"),
		Namespace:      os.Getenv("POD_NAMESPACE"),
		NodeName:       os.Getenv("NODE_NAME"),
		ServiceAccount: os.Getenv("POD_SERVICE_ACCOUNT"),
		OS:             runtime.GOOS,
		Arch:           runtime.GOARCH,
		GoVersion:      runtime.Version(),
		Version:        s.version,
		StartTime:      s.startTime,
		Uptime:         time.Since(s.startTime).Round(time.Second).String(),
		Timestamp:      time.Now(),
		Request: RequestInfo{
			Method:     r.Method,
			URL:        r.URL.String(),
			Proto:      r.Proto,
			Host:       r.Host,
			RemoteAddr: r.RemoteAddr,
			Headers:    r.Header,
		},
	}

	writeJSON(w, http.StatusOK, resp)
}

type versionResponse struct {
	Version   string `json:"version"`
	GoVersion string `json:"goVersion"`
	OS        string `json:"os"`
	Arch      string `json:"arch"`
}

func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, versionResponse{
		Version:   s.version,
		GoVersion: runtime.Version(),
		OS:        runtime.GOOS,
		Arch:      runtime.GOARCH,
	})
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// localIPs returns the non-loopback IP addresses bound to this host, sorted
// for stable output.
func localIPs() []string {
	var ips []string
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ips
	}
	for _, addr := range addrs {
		var ip net.IP
		switch v := addr.(type) {
		case *net.IPNet:
			ip = v.IP
		case *net.IPAddr:
			ip = v.IP
		}
		if ip == nil || ip.IsLoopback() {
			continue
		}
		ips = append(ips, ip.String())
	}
	sort.Strings(ips)
	return ips
}
