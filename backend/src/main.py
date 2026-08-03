import base64
import asyncio
import random

from fastapi import FastAPI
from redis import Redis
from rq import Queue

from .tasks import custom_function

app = FastAPI()

q = Queue(connection=Redis(host="redis", port=6379))


@app.get("/")
async def root():
    return {"message": "Hello World"}


@app.get("/health/", status_code=200)
async def main():
    return {"message": "Up and running!"}


@app.get("/inference/", status_code=200)
async def inference():

    job = q.enqueue(custom_function, "./src/image.png")

    return {"job_id": job.id}


@app.get("/inference-sync/", status_code=200)
def inference_sync():
    job = q.enqueue(custom_function, "./src/image.png")
    result = job.latest_result(timeout=120)  # blocks until done or timeout
    return {"job_id": job.id, "result": result.return_value if result else None}


@app.get("/simulate/", status_code=200)
async def simulate(delay: float = 2.0, jitter: float = 0.5):
    """
    http://backend:8000/simulate/?delay=2&jitter=0.5
    Simulates work without touching Redis/RQ/Ollama.
    delay: base seconds to 'process'
    jitter: random +/- variance to mimic real-world variability
    """
    actual_delay = delay + random.uniform(-jitter, jitter)
    await asyncio.sleep(max(0, actual_delay))
    return {"message": "done", "simulated_delay": actual_delay}
