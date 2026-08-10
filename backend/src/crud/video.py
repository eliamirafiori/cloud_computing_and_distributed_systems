from typing import Annotated

from fastapi import Body, Depends, HTTPException
from sqlmodel import Session, or_, select

from ..commons.common_query_params import CommonQueryParams
from ..models.video_model import Video, VideoCreate, VideoPublic, VideoUpdate


async def create_video(
    session: Session,
    video: VideoCreate,
) -> VideoPublic:
    """
    Create a new video.

    \f

    :param session: SQLModel session
    :type session: Session
    :param video: Video to create
    :type video: VideoCreate
    :return: Created video
    :rtype: VideoPublic
    """
    db_video = Video.model_validate(video)
    session.add(db_video)
    session.commit()
    session.refresh(db_video)
    return db_video


async def read_videos(
    session: Session,
    params: CommonQueryParams = Depends(),
) -> list[VideoPublic]:
    """
    Get all videos with pagination.

    \f

    :param session: SQLModel session
    :type session: Session
    :param params: Common parameters for pagination
    :type params: CommonParams
    :return: List of videos
    :rtype: list[VideoPublic]
    """
    videos = session.exec(select(Video).offset(params.offset).limit(params.limit)).all()
    return videos


async def read_video(
    session: Session,
    id: Annotated[int, Body()],
) -> VideoPublic | None:
    """
    Get specific video by ID.

    \f

    :param session: SQLModel session
    :type session: Session
    :param id: String to filter on
    :type id: int
    :return: Video or None
    :rtype: VideoPublic | None
    """

    db_video = session.exec(select(Video).where(Video.id == id)).first()

    if not db_video:
        raise HTTPException(404, detail="Video not found")

    return db_video


async def update_video(
    session: Session,
    id: int,
    video_model: VideoUpdate,
) -> VideoPublic:
    """
    Update specific video.

    \f

    :param session: SQLModel session
    :type session: Session
    :param id: Video's ID
    :type id: int
    :param video: The video's data
    :type video: VideoCreate
    :return: Video instance
    :rtype: VideoPublic
    """
    db_video = session.get(Video, id)  # Get the existing video instance
    if not db_video:  # Check if the video exists
        raise HTTPException(status_code=404, detail="Video not found")

    video_data = video_model.model_dump(exclude_unset=True)  # Get only updated values
    for key, value in video_data.items():  # Iterate through analysis's data
        # Map key and value from user's data to its db instance
        setattr(db_video, key, value)

    session.add(db_video)  # Add the updated version to the DB
    session.commit()  # Commit the cheanges to the DB
    session.refresh(db_video)  # Refresh the db_analysis instance
    return db_video


async def delete_video(
    session: Session,
    id: int,
) -> None:
    """
    Delete specific video.

    \f

    :param session: SQLModel session
    :type session: Session
    :param id: Video's ID
    :type id: int
    :return: Nothing, as expected when returning STATUS CODE 204
    :rtype: None
    """
    db_video = session.get(Video, id)  # Get the existing video instance
    if not db_video:  # Check if the video exists
        raise HTTPException(status_code=404, detail="Video not found")

    session.delete(db_video)  # Delete the instance of the video
    session.commit()  # Commit the changes to the DB
