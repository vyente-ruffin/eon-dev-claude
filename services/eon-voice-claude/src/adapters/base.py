"""Base class for all-in-one voice adapters."""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, Callable, Optional


@dataclass
class VoiceConfig:
    """Configuration for voice adapter."""
    endpoint: str
    api_key: str
    model: str
    voice: str
    instructions: str
    user_id: str
    tools: list[dict]
    greeting_cue: Optional[str] = None  # Specific greeting cue to use


class VoiceAdapter(ABC):
    """
    Abstract base class for all-in-one voice adapters.

    All adapters implement the same interface, allowing swapping
    providers without changing the API contract.
    """

    def __init__(self, config: VoiceConfig):
        self.config = config
        # Callbacks - same for all adapters
        self.on_audio: Optional[Callable[[str], Any]] = None
        self.on_transcript: Optional[Callable[[str], Any]] = None
        self.on_function_call: Optional[Callable[[str, dict], Any]] = None
        self.on_speech_started: Optional[Callable[[], Any]] = None
        self.on_speech_stopped: Optional[Callable[[], Any]] = None
        self.on_status: Optional[Callable[[str], Any]] = None
        self.on_error: Optional[Callable[[str], Any]] = None

    @abstractmethod
    async def connect(self) -> None:
        """Connect to voice service."""
        pass

    @abstractmethod
    async def disconnect(self) -> None:
        """Disconnect from voice service."""
        pass

    @abstractmethod
    async def send_audio(self, audio_base64: str) -> None:
        """Send audio to voice service."""
        pass

    @abstractmethod
    async def send_text(self, text: str) -> None:
        """Send text input to voice service."""
        pass

    @abstractmethod
    async def send_function_result(self, call_id: str, result: dict) -> None:
        """Send tool result back to voice service."""
        pass

    @classmethod
    @abstractmethod
    def name(cls) -> str:
        """Adapter name for config."""
        pass

    async def _call_callback(self, callback: Callable, *args) -> None:
        """Call a callback, handling both sync and async callbacks."""
        import asyncio
        if asyncio.iscoroutinefunction(callback):
            await callback(*args)
        else:
            callback(*args)
