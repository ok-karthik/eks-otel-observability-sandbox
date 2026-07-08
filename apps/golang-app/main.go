package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func main() {
	// Initialize OTel Telemetry (Traces & Metrics)
	ctx := context.Background()
	shutdown, err := InitTelemetry(ctx)
	if err != nil {
		log.Fatalf("failed to initialize telemetry: %v", err)
	}
	defer func() {
		// Use a separate context for shutdown with a timeout to prevent hanging on exit
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := shutdown(shutdownCtx); err != nil {
			log.Printf("Error shutting down telemetry: %v", err)
		}
	}()

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
