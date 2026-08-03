FROM python:3.14-alpine

WORKDIR /app

COPY ./requirements.txt ./

RUN curl -fsSL https://ollama.com/install.sh | sh

RUN pip install --no-cache-dir --upgrade -r ./requirements.txt &&\
    pip install "fastapi[standard]" &&\
    pip install redis &&\
    pip install rq &&\
    pip install ollama

COPY ./ ./

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
