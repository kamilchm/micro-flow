package main

import (
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"time"

	"github.com/gonum/stat/distuv"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var rCounter = prometheus.NewCounter(prometheus.CounterOpts{
	Name: "requests",
	Help: "Number of requests",
})

var rSuccess = prometheus.NewCounter(prometheus.CounterOpts{
	Name: "success",
	Help: "Number of successfully prcoessed requests",
})

var rLatency = prometheus.NewHistogram(prometheus.HistogramOpts{
	Name: "latency_ms",
	Help: "RPC latency distributions in milliseconds.",
	// 50 exponential buckets ranging from 0.5 ms to 3 minutes
	Buckets: prometheus.ExponentialBuckets(0.5, 1.3, 50),
})

type gammaLatencyHello struct {
	gamma      distuv.Gamma
	errors     float64
	errorsRand distuv.Uniform
	speed      float64
}

func (glh *gammaLatencyHello) handleHello(w http.ResponseWriter, r *http.Request) {
	rCounter.Inc()

	if glh.errorsRand.Rand() <= glh.errors {
		http.Error(w, "Upppss, something gone wrong!", http.StatusInternalServerError)
		return
	}

	respTime := glh.gamma.Rand() / glh.speed
	time.Sleep(time.Duration(int(1000*respTime)) * time.Millisecond)
	io.WriteString(w, "hello")

	rSuccess.Inc()
	rLatency.Observe(respTime)
}

func newGammaLatencyHello(errors, alpha, beta, speed float64) *gammaLatencyHello {
	return &gammaLatencyHello{
		gamma:      distuv.Gamma{alpha, beta, rand.New(rand.NewSource(time.Now().UnixNano()))},
		errors:     errors,
		errorsRand: distuv.Uniform{0.0, 1.0, rand.New(rand.NewSource(time.Now().UnixNano()))},
		speed:      speed,
	}
}

func main() {
	port := flag.Int("port", 8080, "port to bind on")

	errors := flag.Float64("errors", 0.0, "error rate for service responses")

	alpha := flag.Float64("alpha", 2.5, "alpha parameter in gamma distribution")
	beta := flag.Float64("beta", 34.6, "beta parameter in gamma distribution")

	speed := flag.Float64("speed", 1.0, "how fast is that microservice")

	flag.Parse()

	helloServer := newGammaLatencyHello(*errors, *alpha, *beta, *speed) //P95 = 0.34977
	//gamma := distuv.Gamma{20, 194.5, rand.New(rand.NewSource(time.Now().UnixNano()))} //P95 = 0.34962

	http.HandleFunc("/", helloServer.handleHello)

	prometheus.MustRegister(rCounter)
	prometheus.MustRegister(rSuccess)
	prometheus.MustRegister(rLatency)
	http.Handle("/metrics", promhttp.Handler())

	listenOn := fmt.Sprintf(":%d", *port)
	fmt.Println("Listening on", listenOn)
	http.ListenAndServe(listenOn, nil)
}
