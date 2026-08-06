import os

from fastapi import UploadFile, File, HTTPException
from typing import Annotated

from ..commons.constants import (
    ALLOWED_AUDIO_MIME_TYPES,
    ALLOWED_AUDIO_EXTENSIONS,
    ALLOWED_IMAGE_MIME_TYPES,
    ALLOWED_IMAGE_EXTENSIONS,
    ALLOWED_VIDEO_MIME_TYPES,
    ALLOWED_VIDEO_EXTENSIONS,
)


def validate_video_file(file: UploadFile):
    # Validate MIME type
    if file.content_type not in ALLOWED_VIDEO_MIME_TYPES:
        raise HTTPException(status_code=400, detail="Unsupported file type.")

    # Validate file extension
    _, ext = os.path.splitext(file.filename)
    if ext.lower() not in ALLOWED_VIDEO_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Unsupported file extension.")


def validate_audio_file(file: UploadFile):
    # Validate MIME type
    if file.content_type not in ALLOWED_AUDIO_MIME_TYPES:
        raise HTTPException(status_code=400, detail="Unsupported file type.")

    # Validate file extension
    _, ext = os.path.splitext(file.filename)
    if ext.lower() not in ALLOWED_AUDIO_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Unsupported file extension.")


def validate_image_file(file: UploadFile):
    # Validate MIME type
    if file.content_type not in ALLOWED_IMAGE_MIME_TYPES:
        raise HTTPException(status_code=400, detail="Unsupported file type.")

    # Validate file extension
    _, ext = os.path.splitext(file.filename)
    if ext.lower() not in ALLOWED_IMAGE_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Unsupported file extension.")
