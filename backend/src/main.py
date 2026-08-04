import asyncio
import base64
import random

from typing import Annotated, Any
from fastapi import FastAPI, HTTPException, Path
from redis import Redis
from rq import Queue
from rq.exceptions import NoSuchJobError
from rq.job import Job

from .tasks import custom_function, embed_function

app = FastAPI()

redis_conn = Redis(host="redis", port=6379)
q = Queue(connection=redis_conn)


@app.get("/")
async def root():
    return {"message": "Hello World"}


@app.get("/health/", status_code=200)
async def main():
    return {"message": "Up and running!"}


@app.get("/inference/", status_code=200)
def inference():
    job = q.enqueue(custom_function, "./src/image.png")
    return {"job_id": job.id}


@app.get("/embed/{content}", status_code=200)
async def embed(content: Annotated[str, Path()]):
    job = q.enqueue(embed_function, content)

    return {"job_id": job.id}


@app.get("/inference/{job_id}", status_code=200)
def get_result(job_id: str):
    try:
        job = Job.fetch(job_id, connection=redis_conn)
    except NoSuchJobError:
        raise HTTPException(status_code=404, detail="Job not found")

    status = job.get_status()  # queued | started | finished | failed | deferred

    if status == "finished":
        return {"job_id": job_id, "status": status, "result": job.return_value()}
    elif status == "failed":
        return {"job_id": job_id, "status": status, "error": job.exc_info}
    else:
        return {"job_id": job_id, "status": status}
