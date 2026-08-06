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
from ..core.auth_utils import get_current_active_user
from ..core.database import get_session
from ..crud.analysis import read_analysis, update_analysis
from ..crud.study import read_study
from ..crud.study_analysis import get_study_from_analysis
from ..crud.study_participant import read_study_participant
from ..crud.participant import read_participant
from ..models.analysis_model import AnalysisPublic, AnalysisUpdate
from ..models.study_model import StudyPublic
from ..models.participant_model import ParticipantPublic
from ..models.study_analysis import StudyAnalysis
from ..models.study_participant import StudyParticipant

# Dependency injection to get the current user session
SessionDep = Annotated[Session, Depends(get_session)]

# Create router for uploads
router = APIRouter(
    prefix="/uploads",  # Router prefix url
    tags=["uploads"],  # Router tag
)


@router.post(
    "/video/{analysis_id}",  # Endpoint url after the prefix specified earlier
    status_code=201,  # HTTP status code returned if no errors occur
)
async def post_video(
    session: SessionDep,  # Request must pass a JWT, with this dependency we extract its data to verify the user
    request: Request,  # Represents the incoming HTTP request from the client
    # study_title: Annotated[str, Path()],  # The study title
    # role: Annotated[str, Path()],  # The person's role depicted in the video
    analysis_id: Annotated[int, Path()],  # Analysis ID
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

    # Get analysis
    db_analysis: AnalysisPublic = await read_analysis(session=session, id=analysis_id)

    # Get study title
    db_study: StudyPublic = await get_study_from_analysis(
        session=session, analysis_id=analysis_id
    )
    study_title: str = db_study.title

    # Get attendee's role
    db_participant: ParticipantPublic = await read_participant(
        session=session, id=db_analysis.participant_id, username=None
    )
    db_study_participant: StudyParticipant = await read_study_participant(
        session=session, study_id=db_study.id, participant_id=db_participant.id
    )
    role: str = db_study_participant.role

    # Get attendee's username
    filename: str = db_participant.username

    # Get the study directory
    base_dir = f"data/studies/{study_title}"

    # Participant role
    role_dir = "attendees" if role == "attendee" else "speaker"

    # Create directory if it doesn't exists
    os.makedirs(f"{base_dir}/{role_dir}", exist_ok=True)

    # Get file extension, it contains the "."
    _, ext = os.path.splitext(file.filename)
    video_path = os.path.join(
        f"{base_dir}/{role_dir}/{filename}{ext}"
    )  # Construct the absolute path

    # Save the video on disk
    async with aiofiles.open(video_path, "wb") as out_file:
        # Alternative way, save in chunks
        # This way is better for videos or large files
        while content := await file.read(1024):  # async read chunk
            await out_file.write(content)  # async write chunk

    # Save the path to the song_url field
    file_relative_path = f"studies/{study_title}/{role_dir}/{filename}{ext}"
    # url_for() method to generate a full URL to another endpoint in our app, in this case one named "data"
    file_url = request.url_for("data", path=file_relative_path)

    updated_analysis: AnalysisUpdate = AnalysisUpdate(recording_url=str(file_url))
    await update_analysis(session=session, id=db_analysis.id, analysis=updated_analysis)

    return {"url": str(file_url)}
