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

type gammaLatencyHello struct {
	gamma   distuv.Gamma
	speed   float64
	success float64
}

func (glh *gammaLatencyHello) handleHello(w http.ResponseWriter, r *http.Request) {
	rCounter.Inc()
	time.Sleep(time.Duration(int(1000*glh.gamma.Rand())) * time.Millisecond)
	io.WriteString(w, "hello")
}

func newGammaLatencyHello(alpha, beta, speed, success float64) *gammaLatencyHello {
	return &gammaLatencyHello{
		gamma:   distuv.Gamma{alpha, beta, rand.New(rand.NewSource(time.Now().UnixNano()))},
		speed:   speed,
		success: success,
	}
}

func main() {
	port := flag.Int("port", 8080, "port to bind on")
	flag.Parse()

	helloServer := newGammaLatencyHello(2.5, 34.6, 1.0, 1.0) //P95 = 0.34977
	//gamma := distuv.Gamma{20, 194.5, rand.New(rand.NewSource(time.Now().UnixNano()))} //P95 = 0.34962

	http.HandleFunc("/", helloServer.handleHello)

	prometheus.MustRegister(rCounter)
	http.Handle("/metrics", promhttp.Handler())

	listenOn := fmt.Sprintf(":%d", *port)
	fmt.Println("Listening on", listenOn)
	http.ListenAndServe(listenOn, nil)
}
