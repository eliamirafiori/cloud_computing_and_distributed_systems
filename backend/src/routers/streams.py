import os
import httpx

from typing import Annotated, Any

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Path,
    Security,
    Request,
)
from fastapi.responses import Response, StreamingResponse
from pydantic import ValidationError
from sqlmodel import Session, select

from ..commons.constants import AUDIO_DIRECTORY
from ..commons.common_query_params import CommonQueryParams
from ..commons.enums import Scope
from ..core.auth_utils import get_current_active_user
from ..core.database import get_session
from ..crud.customers import read_song, update_song
from ..models.analysis_model import Song, SongCreate, SongPublic, SongUpdate

# dependency injection to get the current user session
SessionDep = Annotated[Session, Depends(get_session)]

# create router for streams
router = APIRouter(
    prefix="/streams",  # router prefix url
    tags=["streams"],  # router tag
)


@router.get(
    "/{song_id}",  # endpoint url after the prefix specified earlier
    # dependencies=[
    #     Security(get_current_active_user, scopes=[Scope.ITEMS_CREATE])
    # ],  # security check, user needs to have permissions to interact with this endpoint
    response_model=None,  # "None" if you use a default Response from fastapi.responses
    status_code=201,  # HTTP status code returned if no errors occur
)
async def post_song(
    session: SessionDep,  # request must pass a JWT, with this dependency we extract its data to verify the user
    song_id: Annotated[int, Path()],  # the song ID
    request: Request,  # the song in a file-like object
) -> Any:  # returns Any because it gets overrided by the response_model
    """
    Stream a song file.

    \f

    :param session: SQLModel session
    :type session: Session
    :param song_id: Song's ID
    :type song_id: int
    :param request: The request
    :type request: Request
    :return: The new created Song
    :rtype: SongPublic
    """
    base_dir = os.path.dirname(
        os.path.abspath(__file__)
    )  # Get the directory of this file
    audio_path = os.path.join(
        # base_dir, "..", "..", f"public/audio/{song_id}.mp3"
        f"{AUDIO_DIRECTORY}/{song_id}.mp3"
    )  # Construct the absolute path

    try:
        file_size = os.path.getsize(audio_path)
        range_header = request.headers.get("range")
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
            with open(audio_path, "rb") as audio_file:
                audio_file.seek(range_start)
                data = audio_file.read(chunk_size)

            headers = {
                "Content-Range": f"bytes {range_start}-{range_end}/{file_size}",
                "Accept-Ranges": "bytes",
                "Content-Length": str(chunk_size),
                "Content-Type": "audio/mpeg",
            }
            return Response(data, status_code=206, headers=headers)

        # If no Range header, return the entire file
        with open(audio_path, "rb") as audio_file:
            data = audio_file.read()

        headers = {
            "Content-Length": str(file_size),
            "Content-Type": "audio/mpeg",
        }
        return Response(data, headers=headers)

    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Audio file not found")


@router.get(
    "/remote/{song_id}",  # endpoint url after the prefix specified earlier
    dependencies=[
        Security(get_current_active_user, scopes=[Scope.ITEMS_CREATE])
    ],  # security check, user needs to have permissions to interact with this endpoint
    response_model=None,  # "None" if you use a default Response from fastapi.responses
    status_code=201,  # HTTP status code returned if no errors occur
)
async def post_song(
    session: SessionDep,  # request must pass a JWT, with this dependency we extract its data to verify the user
    song_id: Annotated[int, Path()],  # the song ID
    request: Request,  # the song in a file-like object
) -> Any:  # returns Any because it gets overrided by the response_model
    """
    Stream a song file.

    \f

    :param session: SQLModel session
    :type session: Session
    :param song_id: Song's ID
    :type song_id: int
    :param request: The request
    :type request: Request
    :return: The new created Song
    :rtype: SongPublic
    """
    # compose remote url
    remote_url = f"http://127.0.0.1:8080/public/audio/{song_id}.mp3"

    try:
        # Initiate a streaming GET request to the external URL
        async with httpx.AsyncClient() as client:
            response = await client.get(remote_url, timeout=None)
            response.raise_for_status()

            # Determine the content type from the response headers
            content_type = response.headers.get(
                "Content-Type", "application/octet-stream"
            )

            # Stream the content to the client
            return StreamingResponse(response.aiter_bytes(), media_type=content_type)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Error fetching the file: {exc}")


@router.get("/video")
async def video2(request: Request):
    base_dir = os.path.dirname(
        os.path.abspath(__file__)
    )  # Get the directory of this file
    video_path = os.path.join(
        # base_dir, "..", "public/video/large_video.mp4"
        "public/video/large_video.mp4"
    )  # Construct the absolute path

    try:
        file_size = os.path.getsize(video_path)
        range_header = request.headers.get("range")
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
            with open(video_path, "rb") as video_file:
                video_file.seek(range_start)
                data = video_file.read(chunk_size)

            headers = {
                "Content-Range": f"bytes {range_start}-{range_end}/{file_size}",
                "Accept-Ranges": "bytes",
                "Content-Length": str(chunk_size),
                "Content-Type": "video/mp4",
            }
            return StreamingResponse(data, status_code=206, headers=headers)

        # If no Range header, return the entire file
        with open(video_path, "rb") as video_file:
            data = video_file.read()

        headers = {
            "Content-Length": str(file_size),
            "Content-Type": "video/mp4",
        }
        return StreamingResponse(data, headers=headers)

    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Video file not found")
