from contextlib import contextmanager

from sqlmodel import Session, SQLModel, create_engine
from sqlalchemy import text

from ..commons.constants import (
    PG_DB,
    PG_PASSWORD,
    PG_PORT,
    PG_SERVER,
    PG_USER,
)

# PostgreSQl database URL
# needs Python package: pip install "psycopg[binary]"
postgresql_url = (
    f"postgresql+psycopg://{PG_USER}:{PG_PASSWORD}@{PG_SERVER}:{PG_PORT}/{PG_DB}"
)

connect_args = {"check_same_thread": False}
engine = create_engine(
    postgresql_url,
    pool_pre_ping=True,  # Prevents the reuse of stale connections and avoids this exact error
    pool_recycle=3600,  # Recycle connections after a certain number of seconds (1 hour), regardless of idle status
)


def init_db():
    """Create the database and tables."""
    with Session(engine) as session:
        session.exec(text("CREATE EXTENSION IF NOT EXISTS vector"))
        session.commit()

    SQLModel.metadata.create_all(engine)


def get_session():
    """
    Yields a session, usefull for dependencies in a route.
    """
    with Session(engine) as session:
        yield session


@contextmanager
def get_session_directly():
    """
    Yields a session direcly, usefull for calling directly functions not for handling a request to a route.
    """
    with Session(engine) as session:
        yield session
