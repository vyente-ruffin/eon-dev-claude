"""Voice adapters for different all-in-one voice providers."""

from .base import VoiceAdapter, VoiceConfig
from .openai_realtime import OpenAIRealtimeAdapter

ADAPTERS = {
    "openai_realtime": OpenAIRealtimeAdapter,
    # Future adapters:
    # "gemini_live": GeminiLiveAdapter,
    # "hume_ai": HumeAIAdapter,
}


def get_adapter(name: str) -> type[VoiceAdapter]:
    """Get adapter class by name."""
    if name not in ADAPTERS:
        available = list(ADAPTERS.keys())
        raise ValueError(f"Unknown adapter: {name}. Available: {available}")
    return ADAPTERS[name]
