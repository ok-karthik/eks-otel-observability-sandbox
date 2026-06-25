import os
import time
import logging
from fastapi import FastAPI
from pyroscope import configure as pyroscope_configure
from pyroscope.otel import PyroscopeSpanProcessor
from opentelemetry import trace

# Standard Python logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize Pyroscope continuous profiling
pyroscope_addr = os.getenv("PYROSCOPE_SERVER_ADDRESS")
if not pyroscope_addr:
    pyroscope_addr = "http://localhost:4040"

logger.info(f"[Python App] Initializing Pyroscope profiling targeting: {pyroscope_addr}")
pyroscope_configure(
    application_name="python-payment-service",
    server_address=pyroscope_addr,
)

# Attach PyroscopeSpanProcessor to the active tracer provider
provider = trace.get_tracer_provider()
provider.add_span_processor(PyroscopeSpanProcessor())

app = FastAPI(title="Python Payment Service", version="1.0.0")

@app.post("/process-payment")
async def process_payment():
    # Because of auto-instrumentation, this log will be dynamically 
    # decorated with active trace_id and span_id by the OTel agent!
    logger.info("[Python App] Entering process_payment handler...")
    
    time.sleep(80 / 1000)  # Simulate Stripe / Database transaction latency
    
    logger.info("[Python App] Payment successfully captured!")
    return {
        "status": "success",
        "gateway": "stripe",
        "transaction_id": "tx_stripe_9941a"
    }

@app.get("/health")
async def health():
    return {"status": "healthy"}
