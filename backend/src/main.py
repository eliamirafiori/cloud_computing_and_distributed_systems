"""
MiraFLIX by Elia Mirafiori
"""

__author__ = "Elia Mirafiori"
__authors__ = "Elia Mirafiori"
__contact__ = "el.mirafiori@gmail.com"
__copyright__ = "Copyright © 2026 Elia Mirafiori"
__license__ = "GPLv3"
__date__ = "06 Aug 2026"
__version__ = "1.0.0"

import asyncio
import base64
import random
import os

from typing import Annotated, Any
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Path
from fastapi.responses import ORJSONResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from redis import Redis
from rq import Queue
from rq.exceptions import NoSuchJobError
from rq.job import Job

from .tasks import custom_function, embed_function
from .routers import streams, uploads

# Load environment variables from the .env file (if present)
load_dotenv()

app = FastAPI(
    title="MiraFLIX",
    default_response_class=ORJSONResponse,  # It's faster than JSONResponse
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Create the public directory if it doesn't exists (relative path to where the Docker is started)
os.makedirs(
    "./data", exist_ok=True
)  # TODO: find a better name or best practices for media streaming

# Mount the public directory
app.mount("/data", StaticFiles(directory="./data"), name="data")

# Including all the routers
app.include_router(streams.router)
app.include_router(uploads.router)

redis_conn = Redis(host="redis", port=6379)
q = Queue(connection=redis_conn)


@app.get("/", status_code=200)
async def root():
    return {"message": "Up and running!"}


@app.get("/health/", status_code=200)
async def main():
    return {"message": "Healthy, up and running!"}


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
