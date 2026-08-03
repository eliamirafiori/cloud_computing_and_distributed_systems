from redis import Redis
from rq import Worker, Queue, Connections

redis_conn = Redis(host="redis", port=6379)

listen = ["default"]

if __name__ == "__main__":
    with Connections(redis_conn):
        worker = Worker(map(Queue, listen))
        worker.work()
