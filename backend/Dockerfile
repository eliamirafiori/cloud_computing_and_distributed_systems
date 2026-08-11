FROM python:3.14-alpine

WORKDIR /app

COPY ./requirements.txt ./

# RUN curl -fsSL https://ollama.com/install.sh | sh

RUN pip install --no-cache-dir -r ./requirements.txt


COPY ./ ./

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
