import os

from dotenv import load_dotenv

# Load .env file
load_dotenv()

POSTGRES_USER = os.getenv("POSTGRES_USER")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD")
POSTGRES_SERVER = os.getenv("POSTGRES_SERVER")
POSTGRES_PORT = os.getenv("POSTGRES_PORT")
POSTGRES_DB = os.getenv("POSTGRES_DB")

MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB

AUDIO_DIRECTORY = "public/audio"

IMAGE_DIRECTORY = "public/image"

VIDEO_DIRECTORY = "public/video"

ALLOWED_AUDIO_MIME_TYPES = {
    "audio/mpeg",  # .mp3
    "audio/wav",  # .wav
    "audio/x-wav",  # .wav
    "audio/aac",  # .aac
    "audio/mp4",  # .m4a
    "audio/flac",  # .flac
    "audio/alac",  # .alac
    "audio/aiff",  # .aiff, .aif
    "audio/x-aiff",  # .aiff, .aif
    "audio/ogg",  # .ogg
    "audio/x-ms-wma",  # .wma
}

ALLOWED_AUDIO_EXTENSIONS = {
    ".mp3",
    ".wav",
    ".aac",
    ".m4a",
    ".flac",
    ".alac",
    ".aiff",
    ".aif",
    ".ogg",
    ".wma",
}

ALLOWED_IMAGE_MIME_TYPES = {
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/bmp",
    "image/webp",
    "image/tiff",
    "image/svg+xml",
    "image/vnd.microsoft.icon",
    "image/avif",
    "image/heic",
}

ALLOWED_IMAGE_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".bmp",
    ".webp",
    ".tiff",
    ".tif",
    ".svg",
    ".ico",
    ".avif",
    ".heic",
}

ALLOWED_VIDEO_MIME_TYPES = {
    "video/mp4",
    "video/webm",
    "video/x-msvideo",
    "video/quicktime",
    "video/x-ms-wmv",
    "video/x-flv",
    "video/x-matroska",
    "video/mpeg",
    "video/3gpp",
    "video/x-m4v",
}


ALLOWED_VIDEO_EXTENSIONS = {
    ".mp4",
    ".webm",
    ".avi",
    ".mov",
    ".wmv",
    ".flv",
    ".mkv",
    ".mpeg",
    ".mpg",
    ".3gp",
    ".m4v",
}
