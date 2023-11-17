package main

// https://ashishb.net/tech/docker-101-a-basic-web-server-displaying-hello-world/
// https://tutorialedge.net/golang/creating-simple-web-server-with-golang/
// https://blog.gopheracademy.com/advent-2017/kubernetes-ready-service/
// https://semaphoreci.com/community/tutorials/how-to-deploy-a-go-web-application-with-docker
// https://prometheus.io/docs/tutorials/instrumenting_http_server_in_go/

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

// default noun
var messageTo = "World"

// built into binary using ldflags
var Version string
var BuildTime string

// Prometehus request counter for this container
var promRequestCounter = prometheus.NewCounter(
	prometheus.CounterOpts{
		Name: "request_count_promtotal", // suffix '_promtotal' intentionally for prometheus-adapter rule
		Help: "No of total request handled by container",
	},
)

// prometheus.Counter does not have Get or GetValue method, workaround:
// https://stackoverflow.com/questions/57952695/prometheus-counters-how-to-get-current-value-with-golang-client/58875389#58875389
func getMetricValue(col prometheus.Collector) float64 {
	c := make(chan prometheus.Metric, 1) // 1 for metric with no vector
	col.Collect(c)                       // collect current metric value into the channel
	m := dto.Metric{}
	_ = (<-c).Write(&m) // read metric value from the channel
	return *m.Counter.Value
}

func StartWebServer() {
	prometheus.MustRegister(promRequestCounter)

	// handlers
	http.HandleFunc("/healthz", handleHealth)
	http.HandleFunc("/shutdown", handleShutdown)
	http.Handle("/metrics", promhttp.Handler())

	// APP_CONTEXT defaults to root
	appContext := getenv("APP_CONTEXT", "/")
	log.Printf("app context: %s", appContext)
	http.HandleFunc(appContext, handleApp)

	port := getenv("PORT", "8080")
	log.Printf("Starting web server on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		panic(err)
	}

}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, "{\"health\":\"ok\", \"Version\":\"%s\", \"BuildTime\":\"%s\"}", Version, BuildTime)
}

func handleApp(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Header().Set("Content-Type", "text/plain")

	// print main hello message
	fmt.Fprintf(w, "Hello, %s\n", messageTo)

	// writes count and path
	mainMsgFormat := "request %d %s %s\n"
	prc := getMetricValue(promRequestCounter)
	prcInt := int(math.Round(prc))
	log.Printf(mainMsgFormat, prcInt, r.Method, r.URL.Path)
	_, err := fmt.Fprintf(w, mainMsgFormat, prcInt, r.Method, r.URL.Path)
	if err != nil {
		fmt.Println(err)
	}

	// increment prometheus counter
	promRequestCounter.Inc()

	// 'Host' header is promoted to Request.Host field and removed from Header map
	_, err = fmt.Fprintf(w, "Host: %s\n", provideDefault(r.Host, "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_NODE_NAME
	_, err = fmt.Fprintf(w, "MY_NODE_NAME: %s\n", getenv("MY_NODE_NAME", "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_POD_NAME
	_, err = fmt.Fprintf(w, "MY_POD_NAME: %s\n", getenv("MY_POD_NAME", "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_POD_NAMESPACE
	_, err = fmt.Fprintf(w, "MY_POD_NAMESPACE: %s\n", getenv("MY_POD_NAMESPACE", "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_POD_IP
	_, err = fmt.Fprintf(w, "MY_POD_IP: %s\n", getenv("MY_POD_IP", "empty"))
	if err != nil {
		fmt.Println(err)
	}

	// env MY_POD_SERVICE_ACCOUNT
	_, err = fmt.Fprintf(w, "MY_POD_SERVICE_ACCOUNT: %s\n", getenv("MY_POD_SERVICE_ACCOUNT", "empty"))
	if err != nil {
		fmt.Println(err)
	}
}

// provide default for value
func provideDefault(value, defaultVal string) string {
	if len(value) == 0 {
		return defaultVal
	}
	return value
}

// pull from OS environment variable, provide default
func getenv(key, fallback string) string {
	value := os.Getenv(key)
	if len(value) == 0 {
		return fallback
	}
	return value
}

// non-graceful and abrupt exit
func handleShutdown(w http.ResponseWriter, r *http.Request) {
	log.Printf("About to abruptly exit")
	os.Exit(0)
}

func main() {
	StartWebServer()
}
