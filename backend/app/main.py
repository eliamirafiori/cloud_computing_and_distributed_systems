import base64

from fastapi import FastAPI
from redis import Redis
from rq import Queue

from tasks import custom_function

app = FastAPI()

q = Queue(connection=Redis(host="redis", port=6379))


@app.get("/")
async def root():
    return {"message": "Hello World"}


@app.get("/health/", status_code=200)
async def main():
    return {"message": "Up and running!"}


@app.get("/inference/")
async def inference():

    job = q.enqueue(custom_function, "image.png")

    return {"job_id": job.id}
