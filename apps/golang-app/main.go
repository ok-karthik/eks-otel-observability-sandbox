package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// 1. Initialize OpenTelemetry Tracer
func initTracer() (*sdktrace.TracerProvider, error) {
	ctx := context.Background()

	// Get collector endpoint (e.g. otel-collector:4317 or lgtm:4317)
	collectorAddr := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if collectorAddr == "" {
		collectorAddr = "otel-collector:4317"
	}

	// Clean up scheme prefixes (http:// or https://) for gRPC connection
	collectorAddr = strings.TrimPrefix(collectorAddr, "http://")
	collectorAddr = strings.TrimPrefix(collectorAddr, "https://")

	// Create gRPC exporter to send traces to the collector
	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithEndpoint(collectorAddr),
	)
	if err != nil {
		return nil, err
	}

	// Define our Service Name and Version resource attributes
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceNameKey.String("golang-checkout-service"),
			semconv.ServiceVersionKey.String("1.0.0"),
		),
	)
	if err != nil {
		return nil, err
	}

	// Create and register the Tracer Provider
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	// Ensure W3C Trace Context headers propagate transparently in HTTP calls
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return tp, nil
}

func main() {
	// Initialize OTel
	tp, err := initTracer()
	if err != nil {
		log.Fatalf("failed to initialize tracer: %v", err)
	}
	defer tp.Shutdown(context.Background())

	// Route handler
	http.HandleFunc("/checkout", handleCheckout)

	// Wrap our HTTP server handler with OTel middleware
	// This automatically creates a span for every incoming request!
	otelHandler := otelhttp.NewHandler(http.DefaultServeMux, "ingress_request")

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Go application listening on port %s...", port)
	if err := http.ListenAndServe(":"+port, otelHandler); err != nil {
		log.Fatal(err)
	}
}

func handleCheckout(w http.ResponseWriter, r *http.Request) {
	log.Println("[Go App] Starting checkout flow...")
	time.Sleep(50 * time.Millisecond) // Simulate some work

	// Call the Python Payment Service
	pythonAppURL := os.Getenv("PAYMENT_SERVICE_URL")
	if pythonAppURL == "" {
		pythonAppURL = "http://python-app:8001"
	}

	// The Python payment service endpoint is a POST request.
	// We use otelhttp.Post to send a POST request with context propagation.
	log.Printf("[Go App] Calling payment service: %s/process-payment", pythonAppURL)
	resp, err := otelhttp.Post(r.Context(), pythonAppURL+"/process-payment", "application/json", nil)
	if err != nil {
		http.Error(w, fmt.Sprintf("Payment call failed: %v", err), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		http.Error(w, "Payment service failed", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	w.Write([]byte("Checkout successful and payment processed!"))
}
