from contextlib import asynccontextmanager
from fastapi import FastAPI

from .database import init_db


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Lifespan context manager for FastAPI app."""
    # Code to run at startup
    init_db()  # Initialize the database
    yield
    # Code to run at shutdown
