FROM python:3.14-alpine

WORKDIR /app

COPY ./requirements.txt ./

# RUN curl -fsSL https://ollama.com/install.sh | sh

RUN pip install --no-cache-dir --upgrade -r ./requirements.txt &&\
    pip install "fastapi[standard]" &&\
    pip install sqlmodel &&\
    pip install "psycopg[binary]" &&\
    pip install pgvector &&\
    pip install python-dotenv &&\
    pip install aiofiles &&\
    pip install redis &&\
    pip install rq &&\
    pip install ollama

COPY ./ ./

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
