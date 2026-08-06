import os
import subprocess
import aiofiles

from typing import Annotated, Any
from fastapi import (
    APIRouter,
    BackgroundTasks,
    Request,
    Depends,
    HTTPException,
    Path,
    Security,
    File,
    UploadFile,
    Response,
)
from sqlmodel import Session, select
from ..utils.file_utils import validate_video_file
from ..core.database import get_session
from ..crud.video import create_video, update_video
from ..models.video_model import VideoCreate, VideoPublic, VideoUpdate

# Dependency injection to get the current user session
SessionDep = Annotated[Session, Depends(get_session)]

# Create router for uploads
router = APIRouter(
    prefix="/uploads",  # Router prefix url
    tags=["uploads"],  # Router tag
)


@router.post(
    "/video/",  # Endpoint url after the prefix specified earlier
    status_code=201,  # HTTP status code returned if no errors occur
)
async def post_video(
    session: SessionDep,  # Request must pass a JWT, with this dependency we extract its data to verify the user
    request: Request,  # Represents the incoming HTTP request from the client
    video_model: VideoCreate,  # Video model
    file: Annotated[UploadFile, File()],  # the song in a file-like object
) -> Any:  # Returns Any because it gets overrided by the response_model
    """
    Upload a video for a new analysis.
    \f
    :param session: SQLModel session
    :type session: Session
    :param request: HTTP Request
    :type request: Request
    :param analysis_id: Analysis ID
    :type analysis_id: int
    :param study_title: Title of the study
    :type study_title: str
    :param role: Participant's role [attendee | speaker]
    :type role: str
    :param file: Video file
    :type file: UploadFile
    :return: The analysis model
    :rtype: AnalysisPublic
    """
    # Validate file
    validate_video_file(file)

    # Create the new video instance
    db_video: VideoPublic = await create_video(session=session, video=video_model)

    # TODO: start job to embed the description of the video

    # Get the media directory
    base_dir = f"data/media/"

    # Create directory if it doesn't exists
    os.makedirs(f"{base_dir}", exist_ok=True)

    # Construct the absolute path
    video_path = os.path.join(f"{base_dir}/{file.filename}")

    # Save the video on disk
    async with aiofiles.open(video_path, "wb") as out_file:
        while content := await file.read(1024):  # async read chunk
            await out_file.write(content)  # async write chunk

    # Save the path to the video_url field
    file_relative_path = f"{file.filename}"
    # url_for() method to generate a full URL to another endpoint in our app, in this case one named "media"
    file_url = request.url_for("media", path=file_relative_path)

    updated_video: VideoUpdate = VideoUpdate(video_url=str(file_url))
    return await update_video(session=session, id=db_video.id, analysis=updated_video)
