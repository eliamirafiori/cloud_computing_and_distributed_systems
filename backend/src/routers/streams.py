import os
import httpx

from typing import Annotated, Any

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Path,
    Request,
)
from fastapi.responses import Response, StreamingResponse
from pydantic import ValidationError
from sqlmodel import Session, select

from ..commons.constants import AUDIO_DIRECTORY, VIDEO_DIRECTORY
from ..commons.common_query_params import CommonQueryParams
from ..core.database import get_session

# dependency injection to get the current user session
SessionDep = Annotated[Session, Depends(get_session)]

# create router for streams
router = APIRouter(
    prefix="/streams",  # router prefix url
    tags=["streams"],  # router tag
)


@router.get(
    "/video/{video_id}",  # endpoint url after the prefix specified earlier
    name="stream_video",  # Name of the endpoint, FastAPI uses it to recognize this endpoint
)
async def get_video(
    session: SessionDep,  # request must pass a JWT, with this dependency we extract its data to verify the user
    video_id: Annotated[int, Path()],  # the song ID
    request: Request,
):

    # Construct the absolute path
    video_path = os.path.join(f"data/media/{video_id}.mp4")

    try:
        file_size = os.path.getsize(video_path)
        range_header = request.headers.get("range")

        def iter_file(path: str, start: int, end: int, chunk_size: int = 64 * 1024):
            with open(path, "rb") as f:
                f.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    chunk = f.read(min(chunk_size, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    yield chunk  # yields bytes, not int, so StreamingResponse works correctly

        if range_header:
            # Parse the Range header
            range_start, range_end = range_header.replace("bytes=", "").split("-")
            range_start = int(range_start)
            range_end = int(range_end) if range_end else file_size - 1

            if range_start >= file_size or range_end >= file_size:
                raise HTTPException(
                    status_code=416, detail="Requested Range Not Satisfiable"
                )

            chunk_size = range_end - range_start + 1
            # with open(video_path, "rb") as video_file:
            #     video_file.seek(range_start)
            #     data = video_file.read(chunk_size)

            headers = {
                "Content-Range": f"bytes {range_start}-{range_end}/{file_size}",
                "Accept-Ranges": "bytes",
                "Content-Length": str(chunk_size),
                "Content-Type": "video/mp4",
            }
            return StreamingResponse(
                iter_file(
                    path=video_path,
                    start=range_start,
                    end=range_end,
                    chunk_size=chunk_size,
                ),
                status_code=206,
                headers=headers,
            )

        # If no Range header, return the entire file
        # with open(video_path, "rb") as video_file:
        #     data = video_file.read()

        headers = {
            "Content-Length": str(file_size),
            "Content-Type": "video/mp4",
        }
        return StreamingResponse(
            iter_file(
                path=video_path,
                start=0,
                end=file_size - 1,
            ),
            headers=headers,
        )

    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Video file not found")
