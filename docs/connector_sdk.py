"""
Personal Intelligence Engine (PIE) - Connector SDK
This module defines the interfaces and data contracts for ingesting,
parsing, and structuring digital data into the PIE database and vector spaces.
"""

from abc import ABC, abstractmethod
from typing import Any, AsyncGenerator, Dict, List, Optional
from datetime import datetime
from pydantic import BaseModel, Field


class IngestedPayload(BaseModel):
    """
    Standard envelope representing raw connector data retrieved during ingestion.
    """
    external_id: str = Field(
        ..., 
        description="The primary key ID of this resource in the source application/system."
    )
    title: str = Field(
        ..., 
        description="User-readable name/subject of the document, message, or file."
    )
    content: Optional[str] = Field(
        None, 
        description="Raw text content of the entity, if accessible during polling."
    )
    raw_binary: Optional[bytes] = Field(
        None, 
        description="Binary bytes representing images, attachments, or PDFs for parsing."
    )
    mime_type: str = Field(
        ..., 
        description="MIME type classification of the content (e.g., application/pdf, text/html)."
    )
    source_metadata: Dict[str, Any] = Field(
        default_factory=dict,
        description="Arbitrary key-value store mapping origin-specific headers, attributes, or labels."
    )
    retrieved_at: datetime = Field(
        default_factory=datetime.utcnow,
        description="Epoch timestamp when this node was ingested."
    )


class ExtractedEntity(BaseModel):
    """
    Representing nodes detected during NLP / entity extraction.
    """
    name: str = Field(..., description="E.g., 'Alice Smith', 'San Francisco', 'Personal Finance'.")
    entity_type: str = Field(..., description="PERSON, ORGANIZATION, LOCATION, TOPIC, or EVENT.")
    properties: Dict[str, Any] = Field(default_factory=dict)


class ExtractedRelationship(BaseModel):
    """
    Representing semantic associations between nodes in the Knowledge Graph.
    """
    source_entity_name: str
    target_entity_name: str
    relationship_type: str = Field(default="RELATED_TO")
    weight: float = Field(default=1.0)
    properties: Dict[str, Any] = Field(default_factory=dict)


class IngestionResult(BaseModel):
    """
    Structured parser output containing text chunks and entity relationships.
    """
    chunks: List[str] = Field(
        ..., 
        description="Segmented text chunks ready for vector semantic embeddings."
    )
    entities: List[ExtractedEntity] = Field(
        default_factory=list,
        description="Entity nodes extracted from text context."
    )
    relationships: List[ExtractedRelationship] = Field(
        default_factory=list,
        description="Relations connecting extracted entities."
    )


class BaseConnector(ABC):
    """
    Abstract Base Class for all PIE Connectors.
    All custom connectors must implement authentication and synchronization routines.
    """

    def __init__(self, connector_id: str, user_id: str, decrypted_config: Dict[str, Any]):
        self.connector_id = connector_id
        self.user_id = user_id
        self.config = decrypted_config

    @abstractmethod
    async def validate_credentials(self) -> bool:
        """
        Authenticate against the third-party client API or read access configurations.
        Returns:
            bool: True if authorized and validated, False otherwise.
        """
        pass

    @abstractmethod
    async def fetch_updates(
        self, 
        last_synced_at: Optional[datetime] = None
    ) -> AsyncGenerator[IngestedPayload, None]:
        """
        Queries the source service for records modified or created since the last sync.
        Yields:
            IngestedPayload: Envelope containing raw payload data.
        """
        pass


class BaseParser(ABC):
    """
    Interface for converting raw connector binaries into structured text chunks
    and database graph relationships.
    """

    @abstractmethod
    async def parse(self, payload: IngestedPayload) -> IngestionResult:
        """
        Transforms raw payload data or files into vectorized chunks and graph nodes.
        Args:
            payload (IngestedPayload): Ingested metadata and content.
        Returns:
            IngestionResult: Segmented texts and graph definitions.
        """
        pass


# ==============================================================================
# REFERENCE IMPLEMENTATION: PDF File Ingestion
# ==============================================================================

class MockPDFParser(BaseParser):
    """
    Example parser implementing custom chunk splitting and basic entity analysis.
    """

    def _chunk_text(self, text: str, chunk_size: int = 500, overlap: int = 50) -> List[str]:
        words = text.split()
        chunks = []
        for i in range(0, len(words), chunk_size - overlap):
            chunk = " ".join(words[i:i + chunk_size])
            chunks.append(chunk)
            if i + chunk_size >= len(words):
                break
        return chunks

    async def parse(self, payload: IngestedPayload) -> IngestionResult:
        # Assuming payload.content contains text extracted from PDF
        text = payload.content or ""
        
        # 1. Break text into semantic chunks
        chunks = self._chunk_text(text)

        # 2. Extract Mock Entities (In production, this delegates to LayoutLM or SpaCy/LLM)
        entities = []
        relationships = []
        
        # Example simplistic heuristic extraction
        if "Invoice" in payload.title:
            entities.append(ExtractedEntity(name="Invoice Entity", entity_type="TOPIC"))
            
        if "Alice" in text:
            entities.append(ExtractedEntity(name="Alice", entity_type="PERSON"))
            
        if len(entities) >= 2:
            relationships.append(ExtractedRelationship(
                source_entity_name=entities[0].name,
                target_entity_name=entities[1].name,
                relationship_type="MENTIONED_TOGETHER"
            ))

        return IngestionResult(
            chunks=chunks,
            entities=entities,
            relationships=relationships
        )
