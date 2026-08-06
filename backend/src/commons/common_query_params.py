from typing import Annotated

from sqlmodel import Field
from pydantic import BaseModel


class CommonQueryParams(BaseModel):
    offset: int = Field(0, ge=0)
    limit: int = Field(100, le=100)
    q: str | None = Field(None)
