from http.client import HTTPException
from typing import Annotated

from cloud_computing_and_distributed_systems.backend.src.models.video_model import Video
from fastapi import (
    APIRouter,
    Depends,
    Path,
)
from redis import Redis
from rq import Queue
from sqlmodel import Session

from ..core.database import get_session
from ..crud.tasks import embed_video_description

# Dependency injection to get the current user session
SessionDep = Annotated[Session, Depends(get_session)]

# Create router for embeddings
router = APIRouter(
    prefix="/embeddings",  # Router prefix url
    tags=["embeddings"],  # Router tag
)

redis_conn = Redis(host="redis", port=6379)
q = Queue("videos", connection=redis_conn)


@router.post("/embed/{video_id}", status_code=202)
async def embed_video(
    session: SessionDep,
    video_id: Annotated[int, Path()],
):
    db_video = session.get(Video, video_id)
    if not db_video:
        raise HTTPException(status_code=404, detail="Video not found")

    description = db_video.description or "No description provided"
    job = q.enqueue(embed_video_description, db_video.id, description)

    return {"job_id": job.id, "video_id": video_id, "status": "queued"}
