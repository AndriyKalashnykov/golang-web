package main

import (
	"fmt"
	"log"
	"math"
	"net/http"
	"os"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	dto "github.com/prometheus/client_model/go"
)

// messageTo is the default noun.
var messageTo = "World"

// Version is built into binary using ldflags.
var Version string

// BuildTime is built into binary using ldflags.
var BuildTime string

// promRequestCounter is the Prometheus request counter for this container.
var promRequestCounter = prometheus.NewCounter(
	prometheus.CounterOpts{ //nolint:promlinter // suffix '_promtotal' intentionally for prometheus-adapter rule
		Name: "request_count_promtotal",
		Help: "No of total request handled by container",
	},
)

// prometheus.Counter does not have Get or GetValue method, workaround:
// https://stackoverflow.com/questions/57952695/prometheus-counters-how-to-get-current-value-with-golang-client/58875389#58875389
func getMetricValue(col prometheus.Collector) float64 {
	c := make(chan prometheus.Metric, 1) // 1 for metric with no vector
	col.Collect(c)                       // collect current metric value into the channel
	m := dto.Metric{}
	_ = (<-c).Write(&m) //nolint:errcheck // metric write error is not actionable
	return *m.Counter.Value
}

// StartWebServer initializes handlers and starts the HTTP server.
func StartWebServer() {
	prometheus.MustRegister(promRequestCounter)

	// handlers.
	http.HandleFunc("/healthz", handleHealth)
	http.HandleFunc("/shutdown", handleShutdown)
	http.Handle("/metrics", promhttp.Handler())

	// APP_CONTEXT defaults to root.
	appContext := getenv("APP_CONTEXT", "/")
	log.Printf("app context: %s", appContext)
	http.HandleFunc(appContext, handleApp)

	port := getenv("PORT", "8080")
	log.Printf("Starting web server on port %s", port)
	log.Printf("Open http://localhost:%s%s", port, appContext)
	if err := http.ListenAndServe(":"+port, nil); err != nil { // #nosec G114 -- simple test server //nolint:gosec
		panic(err)
	}
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, err := fmt.Fprintf(w, "{\"health\":\"ok\", \"Version\":\"%s\", \"BuildTime\":\"%s\"}", Version, BuildTime)
	if err != nil {
		fmt.Println(err)
	}
}

func handleApp(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)

	// Print main hello message.
	_, err := fmt.Fprintf(w, "Hello, %s\n", messageTo)
	if err != nil {
		fmt.Println(err)
	}

	// Writes count and path.
	mainMsgFormat := "request %d %s %s\n"
	prc := getMetricValue(promRequestCounter)
	prcInt := int(math.Round(prc))
	log.Printf(mainMsgFormat, prcInt, r.Method, r.URL.Path)              // #nosec G706 -- test server //nolint:gosec
	_, err = fmt.Fprintf(w, mainMsgFormat, prcInt, r.Method, r.URL.Path) // #nosec G705 -- test server //nolint:gosec
	if err != nil {
		fmt.Println(err)
	}

	// Increment prometheus counter.
	promRequestCounter.Inc()

	// 'Host' header is promoted to Request.Host field and removed from Header map.
	_, err = fmt.Fprintf(w, "Host: %s\n", provideDefault(r.Host, "empty")) // #nosec G705 -- test server //nolint:gosec
	if err != nil {
		fmt.Println(err)
	}

	// env MY_NODE_NAME.
	_, err = fmt.Fprintf(w, "MY_NODE_NAME: %s\n", getenv("MY_NODE_NAME", "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_POD_NAME.
	_, err = fmt.Fprintf(w, "MY_POD_NAME: %s\n", getenv("MY_POD_NAME", "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_POD_NAMESPACE.
	_, err = fmt.Fprintf(w, "MY_POD_NAMESPACE: %s\n", getenv("MY_POD_NAMESPACE", "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_POD_IP.
	_, err = fmt.Fprintf(w, "MY_POD_IP: %s\n", getenv("MY_POD_IP", "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_POD_SERVICE_ACCOUNT.
	_, err = fmt.Fprintf(w, "MY_POD_SERVICE_ACCOUNT: %s\n", getenv("MY_POD_SERVICE_ACCOUNT", "empty"))
	if err != nil {
		fmt.Println(err)
	}
}

// provideDefault returns defaultVal when value is empty.
func provideDefault(value, defaultVal string) string {
	if value == "" {
		return defaultVal
	}
	return value
}

// getenv pulls from OS environment variable, provides a default.
func getenv(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}

// handleShutdown performs a non-graceful and abrupt exit.
func handleShutdown(_ http.ResponseWriter, _ *http.Request) {
	log.Printf("About to abruptly exit")
	os.Exit(0)
}

func main() {
	StartWebServer()
}
