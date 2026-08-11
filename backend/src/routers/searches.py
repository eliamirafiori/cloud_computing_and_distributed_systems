import os
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Form, HTTPException
from redis import Redis
from rq import Queue
from rq.job import Job
from rq.exceptions import NoSuchJobError
from sqlmodel import Session

from ..core.database import get_session
from ..crud.tasks import embed_and_search

SessionDep = Annotated[Session, Depends(get_session)]

router = APIRouter(prefix="/searches", tags=["searches"])

redis_conn = Redis(host="redis", port=6379)
q = Queue("videos", connection=redis_conn)


@router.post("/search/", status_code=202)
async def post_search(
    session: SessionDep,
    query: Annotated[str, Form()],
) -> Any:
    """
    Submit a search query. Returns immediately with a job_id;
    poll GET /searches/search/{job_id} for the result.
    """
    if not query.strip():
        raise HTTPException(status_code=422, detail="Query cannot be empty")

    job = q.enqueue(
        embed_and_search,
        query,
        job_timeout="30s",  # kill it if Ollama/DB hang
        result_ttl=3600,  # keep result around for polling
        failure_ttl=3600,  # keep failure info around too
    )
    return {"job_id": job.id, "status": "queued"}


@router.get("/search/{job_id}")
async def get_search_result(job_id: str) -> Any:
    try:
        job = Job.fetch(job_id, connection=redis_conn)
    except NoSuchJobError:
        raise HTTPException(status_code=404, detail="Job not found")

    if job.is_finished:
        return {"status": "done", "result": job.result}
    if job.is_failed:
        return {"status": "failed", "error": str(job.exc_info)}
    return {"status": job.get_status()}  # queued / started / deferred
