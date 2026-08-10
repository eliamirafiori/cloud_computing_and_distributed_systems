from fastapi import (
    APIRouter,
    Depends,
    Path,
)
from sqlmodel import Session
from typing import Annotated
from redis import Redis
from rq import Queue

from ..core.database import get_session
from ..crud.tasks import embed_function

# Dependency injection to get the current user session
SessionDep = Annotated[Session, Depends(get_session)]

# Create router for embeddings
router = APIRouter(
    prefix="/embeddings",  # Router prefix url
    tags=["embeddings"],  # Router tag
)

redis_conn = Redis(host="redis", port=6379)
q = Queue(connection=redis_conn)


@router.get("/embed/{content}", status_code=200)
async def embed(content: Annotated[str, Path()]):
    job = q.enqueue(embed_function, content)

    return {"job_id": job.id}
