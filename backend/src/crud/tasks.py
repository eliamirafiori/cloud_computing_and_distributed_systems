import base64
import json
import httpx

from ollama import Client

from ..core.database import get_session_directly
from ..crud.video import vector_search

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


BACKEND_URL = "http://my_backend:8000"  # service name from docker-compose


def embed_video_description(video_id: int, description: str):
    ensure_model()

    print("STARTING EMBEDDING")

    response = client.embed(model=MODEL_NAME, input=description)
    embedding = response["embeddings"][0]

    with httpx.Client(base_url=BACKEND_URL, timeout=10.0) as http_client:
        resp = http_client.patch(
            f"/videos/{video_id}",
            json={"embedding": embedding},
        )
        resp.raise_for_status()

    print(response.embeddings)
    return json.dumps(response.embeddings)


def embed_and_search(query: str, top_k: int = 10):
    ensure_model()

    response = client.embed(model=MODEL_NAME, input=query)
    embedding = response["embeddings"][0]

    with get_session_directly() as session:
        results = vector_search(session, embedding, top_k=top_k)
        return {
            "query": query,
            "results": [{"id": r.id, "description": r.description} for r in results],
        }
