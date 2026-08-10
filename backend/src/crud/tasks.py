import base64
import json

from ollama import Client
from sqlmodel import Session

from ..core.database import engine, get_session_directly
from ..crud.video import update_video
from ..models.video_model import VideoUpdate

client = Client(host="http://ollama:11434")


MODEL_NAME = "minicpm-v4.6"
MODEL_NAME = "embeddinggemma"


def ensure_model():
    client.pull(MODEL_NAME)


def custom_function(image_path):
    # ensure_model()  # no-op if already pulled, but adds overhead each call

    with open(image_path, "rb") as image_file:
        encoded_string = base64.b64encode(image_file.read()).decode("utf-8")

    response = client.chat(
        model="minicpm-v4.6",
        messages=[
            {
                "role": "user",
                "content": "Describe this image.",
                "images": [encoded_string],
            }
        ],
        stream=False,
    )

    print(response.message.content)

    return response.message.content


def embed_video_description(video_id: int, description: str):
    """Generate an embedding for a video's description and persist it."""
    ensure_model()  # no-op if already pulled, but adds overhead each call

    print("STARTING EMBEDDING")

    response = client.embed(
        model=MODEL_NAME,
        input=description,
    )
    embedding = response["embeddings"][0]

    with get_session_directly() as session:
        update_video(
            session=session,
            id=video_id,
            video_model=VideoUpdate(embedding=embedding),
        )
 
    print(response.embeddings)

    return json.dumps(response.embeddings)
