package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.4.0"
	"go.opentelemetry.io/otel/trace"

	otelpyroscope "github.com/grafana/otel-profiling-go"
	"github.com/grafana/pyroscope-go"
)

var tracer trace.Tracer

// 1. Initialize OpenTelemetry SDK Programmatically
func initTracer() (*sdktrace.TracerProvider, error) {
	ctx := context.Background()

	// Get endpoint from environment variable, fallback to local collector
	collectorAddr := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if collectorAddr == "" {
		collectorAddr = "otel-collector:4317"
	}

	// Create OTLP gRPC Exporter
	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithEndpoint(collectorAddr),
	)
	if err != nil {
		return nil, err
	}

	// Define resources (service details)
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceNameKey.String("golang-checkout-service"),
			semconv.ServiceVersionKey.String("1.0.0"),
		),
	)
	if err != nil {
		return nil, err
	}

	// Instantiate TracerProvider with Batch Processor
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)

	// Set global variables wrapped with Pyroscope profiling provider
	otel.SetTracerProvider(otelpyroscope.NewTracerProvider(tp))
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, // Standard W3C Trace Context
		propagation.Baggage{},
	))

	tracer = otel.Tracer("golang-checkout-tracer")
	return tp, nil
}

func main() {
	// Initialize Pyroscope continuous profiling
	pyroscopeAddr := os.Getenv("PYROSCOPE_SERVER_ADDRESS")
	if pyroscopeAddr == "" {
		pyroscopeAddr = "http://localhost:4040"
	}
	log.Printf("Initializing Pyroscope profiling targeting: %s", pyroscopeAddr)
	_, _ = pyroscope.Start(pyroscope.Config{
		ApplicationName: "golang-checkout-service",
		ServerAddress:   pyroscopeAddr,
		ProfileTypes: []pyroscope.ProfileType{
			pyroscope.ProfileCPU,
			pyroscope.ProfileAllocObjects,
			pyroscope.ProfileAllocSpace,
			pyroscope.ProfileInuseObjects,
			pyroscope.ProfileInuseSpace,
		},
	})

	tp, err := initTracer()
	if err != nil {
		log.Fatalf("failed to initialize tracer: %v", err)
	}
	defer func() {
		if err := tp.Shutdown(context.Background()); err != nil {
			log.Printf("Error shutting down tracer provider: %v", err)
		}
	}()

	// Define route handler
	http.HandleFunc("/checkout", handleCheckout)

	// Wrap server handler with OTel HTTP middleware for automatic ingress span creation
	wrappedHandler := otelhttp.NewHandler(http.DefaultServeMux, "ingress_request")

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Go application listening on port %s...", port)
	if err := http.ListenAndServe(":"+port, wrappedHandler); err != nil {
		log.Fatal(err)
	}
}

func handleCheckout(w http.ResponseWriter, r *http.Request) {
	// The otelhttp middleware automatically extracts trace context and starts an ingress span.
	// We retrieve that span context from the request:
	ctx := r.Context()
	span := trace.SpanFromContext(ctx)
	span.SetName("execute_checkout")
	span.SetAttributes(semconv.HTTPTargetKey.String("/checkout"))

	log.Println("[Go App] Starting checkout flow...")
	time.Sleep(50 * time.Millisecond) // Simulate work

	// Call python-app (Payment Service)
	pythonAppURL := os.Getenv("PAYMENT_SERVICE_URL")
	if pythonAppURL == "" {
		pythonAppURL = "http://python-app:8001"
	}

	log.Printf("[Go App] Calling payment service: %s/process-payment", pythonAppURL)
	err := callPaymentService(ctx, pythonAppURL)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(1, err.Error()) // Code 1 = Error
		http.Error(w, fmt.Sprintf("Payment failed: %v", err), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	w.Write([]byte("Checkout successful and payment processed!"))
}

func callPaymentService(ctx context.Context, baseURL string) error {
	// Start a nested outbound span
	tr := otel.Tracer("http-client")
	var childSpan trace.Span
	ctx, childSpan = tr.Start(ctx, "HTTP POST /process-payment")
	defer childSpan.End()

	req, err := http.NewRequestWithContext(ctx, "POST", baseURL+"/process-payment", nil)
	if err != nil {
		return err
	}

	// Create instrumented HTTP Client.
	// otelhttp.Transport automatically injects the active W3C traceparent header 
	// from ctx into the outgoing HTTP Request headers!
	client := &http.Client{
		Transport: otelhttp.NewTransport(http.DefaultTransport),
		Timeout:   2 * time.Second,
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("payment service returned status code %d", resp.StatusCode)
	}

	return nil
}
