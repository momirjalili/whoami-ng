package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"
)

// Caps on the server-side traffic generator ("curl mode"). This endpoint
// fires HTTP requests at a caller-supplied target from inside the pod, which
// is genuinely useful for testing in-cluster DNS/Service load balancing —
// but also a mild SSRF surface, so it's kept firmly bounded and is meant for
// a local, non-public-facing learning cluster only.
const (
	maxGenerateCount       = 500
	maxGenerateConcurrency = 20
	maxGenerateDelayMs     = 5000
	generateRequestTimeout = 5 * time.Second
)

// genResult is one line of the SSE stream: the outcome of a single request
// fired by the generator.
type genResult struct {
	Index     int     `json:"index"`
	Status    int     `json:"status"`
	OK        bool    `json:"ok"`
	LatencyMs float64 `json:"latencyMs"`
	Pod       string  `json:"pod,omitempty"`
	Error     string  `json:"error,omitempty"`
}

// genSummary is the final SSE event, aggregating all results.
type genSummary struct {
	Total        int     `json:"total"`
	Succeeded    int     `json:"succeeded"`
	Failed       int     `json:"failed"`
	AvgLatencyMs float64 `json:"avgLatencyMs"`
	DurationMs   float64 `json:"durationMs"`
}

// whoamiProbe is used to opportunistically pull a pod identity out of a
// response body when the target happens to be another whoami-ng instance.
type whoamiProbe struct {
	PodName  string `json:"podName"`
	Hostname string `json:"hostname"`
}

func (s *Server) handleGenerateStream(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()

	target := q.Get("target")
	parsed, err := url.Parse(target)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		http.Error(w, "target must be an absolute http(s) URL", http.StatusBadRequest)
		return
	}

	count := clampInt(parseIntDefault(q.Get("count"), 20), 1, maxGenerateCount)
	concurrency := clampInt(parseIntDefault(q.Get("concurrency"), 5), 1, maxGenerateConcurrency)
	delayMs := clampInt(parseIntDefault(q.Get("delayMs"), 200), 0, maxGenerateDelayMs)

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	writeSSE(w, flusher, "config", map[string]int{
		"count": count, "concurrency": concurrency, "delayMs": delayMs,
	})

	client := &http.Client{Timeout: generateRequestTimeout}
	ctx := r.Context()

	jobs := make(chan int, count)
	for i := 0; i < count; i++ {
		jobs <- i
	}
	close(jobs)

	results := make(chan genResult)
	var wg sync.WaitGroup
	wg.Add(concurrency)
	for w := 0; w < concurrency; w++ {
		go func() {
			defer wg.Done()
			for idx := range jobs {
				select {
				case <-ctx.Done():
					return
				default:
				}
				results <- fireRequest(client, target, idx)
				if delayMs > 0 {
					select {
					case <-time.After(time.Duration(delayMs) * time.Millisecond):
					case <-ctx.Done():
						return
					}
				}
			}
		}()
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	start := time.Now()
	summary := genSummary{}
	var totalLatency float64

	for res := range results {
		summary.Total++
		if res.OK {
			summary.Succeeded++
		} else {
			summary.Failed++
		}
		totalLatency += res.LatencyMs

		writeSSE(w, flusher, "result", res)

		select {
		case <-ctx.Done():
			// Client went away; stop writing but let workers drain in the background.
			return
		default:
		}
	}

	if summary.Total > 0 {
		summary.AvgLatencyMs = totalLatency / float64(summary.Total)
	}
	summary.DurationMs = float64(time.Since(start).Milliseconds())
	writeSSE(w, flusher, "done", summary)
}

func fireRequest(client *http.Client, target string, idx int) genResult {
	start := time.Now()
	req, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		return genResult{Index: idx, Error: err.Error()}
	}

	resp, err := client.Do(req)
	latency := float64(time.Since(start).Microseconds()) / 1000.0
	if err != nil {
		return genResult{Index: idx, LatencyMs: latency, Error: err.Error()}
	}
	defer resp.Body.Close()

	var probe whoamiProbe
	_ = json.NewDecoder(resp.Body).Decode(&probe)
	pod := firstNonEmpty(probe.PodName, probe.Hostname)

	return genResult{
		Index:     idx,
		Status:    resp.StatusCode,
		OK:        resp.StatusCode >= 200 && resp.StatusCode < 400,
		LatencyMs: latency,
		Pod:       pod,
	}
}

func writeSSE(w http.ResponseWriter, flusher http.Flusher, event string, v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
	flusher.Flush()
}

func parseIntDefault(s string, def int) int {
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}

func clampInt(n, min, max int) int {
	if n < min {
		return min
	}
	if n > max {
		return max
	}
	return n
}
