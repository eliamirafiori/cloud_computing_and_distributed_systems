# README

## MODEL

- https://github.com/openbmb/minicpm
- https://github.com/OpenBMB/MiniCPM-V/
- https://ollama.com/library/minicpm-v4.6

## FRAMEWORK

1. https://ollama.com/
   1. https://ollama.com/blog/ollama-is-now-available-as-an-official-docker-image
   2. docker run -d --gpus=all -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama
2. https://llama-cpp.com/

## FASTAPI

docker buildx build -t CONTAINER_NAME .

docker run -d -it --rm --name CONTAINER_ALIAS -p 8080:8080 CONTAINER_NAME --gpus

docker container attach CONTAINER_NAME

docker container stop CONTAINER_NAME

sudo docker compose up -d --build

sudo docker compose down

sudo docker compose ps

sudo docker compose run --rm k6

## REDIS JOB QUEUE

https://redis.io/docs/latest/develop/use-cases/job-queue/

docker run -d --name redis -p 6379:6379 redis

### PYTHON LIBRARIES

- https://python-rq.org/
- https://dramatiq.io/
