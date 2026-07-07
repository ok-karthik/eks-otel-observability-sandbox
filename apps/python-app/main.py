import os
import time
import logging
from fastapi import FastAPI

# Standard Python logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

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
