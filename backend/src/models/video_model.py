from datetime import datetime

from pydantic import BaseModel
from sqlmodel import Field, SQLModel
from pgvector.sqlalchemy import VECTOR


class VideoBase(SQLModel):
    """
    Base model for a video analysis. This model is used to define the common fields.

    \f

    :param video_url: Video url
    :type video_url: str | None
    :param streaming_url: Streaming url
    :type streaming_url: str | None
    :param description: Description of the uploaded video
    :type description: str | None
    :param embedding: Video's embedding
    :type embedding: list[float] | None
    """

    video_url: str | None = Field(default=None)
    streaming_url: str | None = Field(default=None)
    description: str | None = Field(default=None)
    embedding: list[float] | None = Field(default=None, sa_type=VECTOR(768))

    model_config = {
        "json_schema_extra": {
            "examples": [
                {
                    "video_id": 1,
                    "video_url": "http://...",
                    "streaming_url": "http://...",
                    "description": "In this video...",
                    "embedding": [1, 2, 3],
                }
            ]
        },
    }


class Video(VideoBase, table=True):
    """
    Model for Video. This model is used to define the table structure.
    Inherits from VideoBase.

    \f

    :param id: ID of the analysis
    :type id: int | None
    :param created_at: Creation date of the analysis
    :type created_at: datetime | None
    """

    id: int | None = Field(default=None, primary_key=True, index=True)
    # The created_at field is automatically set to the current date and time when a new record is created.
    created_at: datetime | None = Field(default_factory=datetime.now, index=True)


class VideoCreate(VideoBase):
    """
    Model for creating a new video. This model is used to define the fields required for creating a new video.
    Inherits from VideoBase.

    \f
    """

    pass


class VideoPublic(VideoBase):
    """
    Model for reading a video. This model is used to define the fields returned when reading a video.
    Inherits from VideoBase.

    \f

    :param id: ID of the video
    :type id: int
    """

    id: int


class VideoUpdate(VideoBase):
    """
    Model for updating a video. This model is used to define the fields that can be updated.

    \f

    :param video_url: Video url
    :type video_url: str | None
    :param streaming_url: Streaming url
    :type streaming_url: str | None
    :param description: Description of the uploaded video
    :type description: str | None
    :param embedding: Video's embedding
    :type embedding: list[float] | None
    """

    video_url: str | None = Field(default=None)
    streaming_url: str | None = Field(default=None)
    description: int | None = Field(default=None)
    embedding: list[float] | None = Field(default=None, sa_type=VECTOR(768))
