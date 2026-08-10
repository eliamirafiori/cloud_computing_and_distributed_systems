from typing import Annotated, Any

from fastapi import APIRouter, Depends, Path
from sqlmodel import Session

from ..commons.common_query_params import CommonQueryParams
from ..core.database import get_session
from ..crud.video import read_video, update_video
from ..models.video_model import Video, VideoPublic, VideoUpdate

SessionDep = Annotated[Session, Depends(get_session)]

router = APIRouter(
    prefix="/videos",
    tags=["videos"],
)


@router.get(
    "/{video_id}",
    response_model=VideoPublic,
    status_code=200,
)
async def get_user(
    session: SessionDep,
    video_id: Annotated[int, Path()],
) -> Any:
    """
    Get specific video.

    \f

    :param session: SQLModel session
    :type session: Session
    :param video_id: Video's ID
    :type video_id: int
    :return: Video or None
    :rtype: VideoPublic | None
    """
    return await read_video(session=session, id=video_id)


@router.patch("/{video_id}", response_model=VideoPublic)
async def patch_video(
    session: SessionDep,
    video_id: Annotated[int, Path()],
    video_model: VideoUpdate,
):
    return await update_video(session=session, id=video_id, video_model=video_model)
