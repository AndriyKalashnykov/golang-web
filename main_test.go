package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

// errWriter is a ResponseWriter that fails on Write to exercise error paths.
type errWriter struct {
	header http.Header
}

func (e *errWriter) Header() http.Header         { return e.header }
func (e *errWriter) WriteHeader(_ int)           {}
func (e *errWriter) Write(_ []byte) (int, error) { return 0, errors.New("write failed") }

var _ http.ResponseWriter = (*errWriter)(nil)

func TestMain(m *testing.M) {
	// Register the prometheus counter once for all tests.
	prometheus.MustRegister(promRequestCounter)
	os.Exit(m.Run())
}

func TestProvideDefault(t *testing.T) {
	tests := []struct {
		name       string
		value      string
		defaultVal string
		want       string
	}{
		{"empty value returns default", "", "fallback", "fallback"},
		{"non-empty value returns value", "actual", "fallback", "actual"},
		{"both empty returns empty", "", "", ""},
		{"whitespace is not empty", " ", "fallback", " "},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := provideDefault(tt.value, tt.defaultVal)
			if got != tt.want {
				t.Errorf("provideDefault(%q, %q) = %q, want %q", tt.value, tt.defaultVal, got, tt.want)
			}
		})
	}
}

func TestGetenv(t *testing.T) {
	tests := []struct {
		name     string
		key      string
		fallback string
		envValue string
		setEnv   bool
		want     string
	}{
		{"returns env value when set", "TEST_GETENV_SET", "default", "from-env", true, "from-env"},
		{"returns fallback when unset", "TEST_GETENV_UNSET", "default", "", false, "default"},
		{"returns fallback when empty", "TEST_GETENV_EMPTY", "default", "", true, "default"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.setEnv {
				t.Setenv(tt.key, tt.envValue)
			}
			got := getenv(tt.key, tt.fallback)
			if got != tt.want {
				t.Errorf("getenv(%q, %q) = %q, want %q", tt.key, tt.fallback, got, tt.want)
			}
		})
	}
}

func TestGetMetricValue(t *testing.T) {
	counter := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "test_metric_total",
		Help: "A test counter",
	})

	val := getMetricValue(counter)
	if val != 0 {
		t.Errorf("initial counter value = %f, want 0", val)
	}

	counter.Inc()
	counter.Inc()
	counter.Inc()

	val = getMetricValue(counter)
	if val != 3 {
		t.Errorf("counter value after 3 increments = %f, want 3", val)
	}
}

func TestHandleHealth(t *testing.T) {
	Version = "v1.0.0"
	BuildTime = "2026-01-01_00:00:00"

	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/healthz", http.NoBody)
	rr := httptest.NewRecorder()

	handleHealth(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("status code = %d, want %d", rr.Code, http.StatusOK)
	}

	contentType := rr.Header().Get("Content-Type")
	if contentType != "application/json" {
		t.Errorf("Content-Type = %q, want %q", contentType, "application/json")
	}

	body := rr.Body.String()
	if !strings.Contains(body, `"health":"ok"`) {
		t.Errorf("body missing health:ok, got %q", body)
	}
	if !strings.Contains(body, `"Version":"v1.0.0"`) {
		t.Errorf("body missing Version, got %q", body)
	}
	if !strings.Contains(body, `"BuildTime":"2026-01-01_00:00:00"`) {
		t.Errorf("body missing BuildTime, got %q", body)
	}
}

func TestHandleApp(t *testing.T) {
	t.Setenv("MY_NODE_NAME", "test-node")
	t.Setenv("MY_POD_NAME", "test-pod")
	t.Setenv("MY_POD_NAMESPACE", "test-ns")
	t.Setenv("MY_POD_IP", "10.0.0.1")
	t.Setenv("MY_POD_SERVICE_ACCOUNT", "test-sa")

	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/", http.NoBody)
	req.Host = "localhost:8080"
	rr := httptest.NewRecorder()

	handleApp(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("status code = %d, want %d", rr.Code, http.StatusOK)
	}

	contentType := rr.Header().Get("Content-Type")
	if contentType != "text/plain" {
		t.Errorf("Content-Type = %q, want %q", contentType, "text/plain")
	}

	body := rr.Body.String()

	checks := []struct {
		label    string
		contains string
	}{
		{"greeting", "Hello, World"},
		{"request line", "request"},
		{"host", "Host: localhost:8080"},
		{"node name", "MY_NODE_NAME: test-node"},
		{"pod name", "MY_POD_NAME: test-pod"},
		{"pod namespace", "MY_POD_NAMESPACE: test-ns"},
		{"pod IP", "MY_POD_IP: 10.0.0.1"},
		{"service account", "MY_POD_SERVICE_ACCOUNT: test-sa"},
	}
	for _, c := range checks {
		if !strings.Contains(body, c.contains) {
			t.Errorf("body missing %s (%q), got:\n%s", c.label, c.contains, body)
		}
	}
}

func TestHandleAppDefaultEnv(t *testing.T) {
	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/", http.NoBody)
	rr := httptest.NewRecorder()

	handleApp(rr, req)

	body := rr.Body.String()

	defaults := []string{
		"MY_NODE_NAME: empty",
		"MY_POD_NAME: empty",
		"MY_POD_NAMESPACE: empty",
		"MY_POD_IP: empty",
		"MY_POD_SERVICE_ACCOUNT: empty",
	}
	for _, d := range defaults {
		if !strings.Contains(body, d) {
			t.Errorf("body missing default %q, got:\n%s", d, body)
		}
	}
}

func TestHandleAppIncrementsCounter(t *testing.T) {
	before := getMetricValue(promRequestCounter)

	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/", http.NoBody)
	rr := httptest.NewRecorder()
	handleApp(rr, req)

	after := getMetricValue(promRequestCounter)
	if after != before+1 {
		t.Errorf("counter after handleApp = %f, want %f", after, before+1)
	}
}

func TestHandleAppEmptyHost(t *testing.T) {
	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/", http.NoBody)
	req.Host = ""
	rr := httptest.NewRecorder()

	handleApp(rr, req)

	body := rr.Body.String()
	if !strings.Contains(body, "Host: empty") {
		t.Errorf("empty host should show 'Host: empty', got:\n%s", body)
	}
}

func TestHandleHealthWriteError(_ *testing.T) {
	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/healthz", http.NoBody)
	w := &errWriter{header: http.Header{}}

	handleHealth(w, req)
}

func TestHandleAppWriteError(_ *testing.T) {
	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/", http.NoBody)
	w := &errWriter{header: http.Header{}}

	handleApp(w, req)
}

// httpGet is a helper that creates a request with context and performs GET.
func httpGet(t *testing.T, url string) *http.Response {
	t.Helper()
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, url, http.NoBody)
	if err != nil {
		t.Fatalf("NewRequestWithContext: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	return resp
}

func TestNewServeMux(t *testing.T) {
	t.Setenv("APP_CONTEXT", "/app/")

	mux := newServeMux()
	srv := httptest.NewServer(mux)
	defer srv.Close()

	resp := httpGet(t, srv.URL+"/healthz")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /healthz status = %d, want %d", resp.StatusCode, http.StatusOK)
	}

	resp = httpGet(t, srv.URL+"/app/")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /app/ status = %d, want %d", resp.StatusCode, http.StatusOK)
	}

	resp = httpGet(t, srv.URL+"/metrics")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /metrics status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
}

func TestNewServeMuxDefaultContext(t *testing.T) {
	mux := newServeMux()
	srv := httptest.NewServer(mux)
	defer srv.Close()

	resp := httpGet(t, srv.URL+"/")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET / status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
}
