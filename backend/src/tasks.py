import base64
import json

from ollama import Client

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


def embed_function(content: str):
    """ """
    ensure_model()

    response = client.embed(
        model=MODEL_NAME,
        input=content,
    )
    print(json.dumps(response.embeddings))
    return json.dumps(response.embeddings)
