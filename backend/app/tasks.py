import base64
from ollama import Client

client = Client(host="http://ollama:11434")


def custom_function(image_path):
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

    return response.message.content
