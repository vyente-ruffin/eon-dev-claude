"""
Eon Voice Service (Claude)

Standalone voice service with swappable adapters for different
all-in-one voice providers (OpenAI Realtime, Gemini Live, etc.)
"""

import os
import json
import logging
from urllib.parse import parse_qs

# Configure logging before importing FastAPI
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configure Azure Monitor OpenTelemetry if connection string is set
APPINSIGHTS_CONNECTION_STRING = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")
if APPINSIGHTS_CONNECTION_STRING:
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
        configure_azure_monitor(
            connection_string=APPINSIGHTS_CONNECTION_STRING,
            enable_live_metrics=True,
        )
        logger.info("Azure Monitor OpenTelemetry configured for eon-voice-claude")
    except Exception as e:
        logger.warning(f"Failed to configure Azure Monitor: {e}")

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from .adapters import get_adapter, VoiceConfig

app = FastAPI(title="Eon Voice Service (Claude)")

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration from environment
VOICE_ADAPTER = os.getenv("VOICE_ADAPTER", "openai_realtime")
VOICE_ENDPOINT = os.getenv("VOICE_ENDPOINT", "")
VOICE_API_KEY = os.getenv("VOICE_API_KEY", "")
VOICE_MODEL = os.getenv("VOICE_MODEL", "gpt-4o-mini-realtime-preview")
VOICE_NAME = os.getenv("VOICE_NAME", "alloy")

DEFAULT_INSTRUCTIONS = """You are a helpful AI assistant with a warm, conversational personality."""


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "adapter": VOICE_ADAPTER,
        "model": VOICE_MODEL
    }


@app.websocket("/ws/voice")
async def websocket_voice(websocket: WebSocket):
    """
    WebSocket endpoint for voice communication.

    Query parameters:
    - user_id: User identifier for tool calls

    Configuration is received via WebSocket message after connection:
    - Send a "configure" message with instructions and tools

    Message types from client:
    - {type: "configure", instructions: "...", tools: [...]}
    - {type: "audio", data: "base64..."} - Audio input
    - {type: "text", text: "..."} - Text input (like typed message)
    - {type: "function_result", call_id: "...", result: {...}}

    Message types to client:
    - {type: "connected"}
    - {type: "audio", data: "base64..."} - Audio response
    - {type: "transcript", text: "..."} - Response transcript
    - {type: "function_call", name: "...", call_id: "...", arguments: {...}}
    - {type: "speech_started"}
    - {type: "speech_stopped"}
    - {type: "status", state: "ready|listening|processing"}
    - {type: "error", message: "..."}
    """
    await websocket.accept()

    # Extract user_id from query string
    query_string = websocket.scope.get("query_string", b"").decode()
    params = parse_qs(query_string)
    user_id = params.get("user_id", ["anonymous"])[0]

    logger.info(f"Voice session starting: user_id={user_id}, adapter={VOICE_ADAPTER}")

    # Wait for configuration message with instructions and tools
    try:
        config_msg = await websocket.receive_json()
        if config_msg.get("type") != "configure":
            await websocket.send_json({
                "type": "error",
                "message": "Expected 'configure' message with instructions and tools"
            })
            await websocket.close()
            return

        instructions = config_msg.get("instructions", DEFAULT_INSTRUCTIONS)
        tools = config_msg.get("tools", [])
        greeting_cue = config_msg.get("greeting_cue")  # Specific greeting to use
        logger.info(f"Received config: {len(instructions)} chars instructions, {len(tools)} tools, greeting_cue={greeting_cue}")
    except Exception as e:
        logger.error(f"Failed to receive config: {e}")
        await websocket.send_json({"type": "error", "message": f"Config error: {e}"})
        await websocket.close()
        return

    logger.info(f"Voice session configured: user_id={user_id}, adapter={VOICE_ADAPTER}")

    # Check configuration
    if not VOICE_ENDPOINT or not VOICE_API_KEY:
        await websocket.send_json({
            "type": "error",
            "message": "Voice service not configured. Set VOICE_ENDPOINT and VOICE_API_KEY."
        })
        await websocket.close()
        return

    # Create adapter
    try:
        AdapterClass = get_adapter(VOICE_ADAPTER)
    except ValueError as e:
        await websocket.send_json({"type": "error", "message": str(e)})
        await websocket.close()
        return

    config = VoiceConfig(
        endpoint=VOICE_ENDPOINT,
        api_key=VOICE_API_KEY,
        model=VOICE_MODEL,
        voice=VOICE_NAME,
        instructions=instructions,
        user_id=user_id,
        tools=tools,
        greeting_cue=greeting_cue,
    )
    adapter = AdapterClass(config)

    # Set up callbacks to forward events to WebSocket client
    async def on_audio(data: str):
        await websocket.send_json({"type": "audio", "data": data})

    async def on_transcript(text: str):
        logger.info(f"[{user_id}] Transcript: {text}")
        await websocket.send_json({"type": "transcript", "text": text})

    async def on_function_call(name: str, data: dict):
        logger.info(f"[{user_id}] Function call: {name} args={data.get('arguments', {})}")
        # Forward to caller (backend handles tool execution)
        await websocket.send_json({
            "type": "function_call",
            "name": name,
            "call_id": data["call_id"],
            "arguments": data["arguments"]
        })

    async def on_speech_started():
        await websocket.send_json({"type": "speech_started"})

    async def on_speech_stopped():
        await websocket.send_json({"type": "speech_stopped"})

    async def on_status(status: str):
        await websocket.send_json({"type": "status", "state": status})

    async def on_error(error: str):
        await websocket.send_json({"type": "error", "message": error})

    adapter.on_audio = on_audio
    adapter.on_transcript = on_transcript
    adapter.on_function_call = on_function_call
    adapter.on_speech_started = on_speech_started
    adapter.on_speech_stopped = on_speech_stopped
    adapter.on_status = on_status
    adapter.on_error = on_error

    try:
        await adapter.connect()
        await websocket.send_json({"type": "connected"})

        while True:
            data = await websocket.receive_json()
            msg_type = data.get("type")

            if msg_type == "audio":
                await adapter.send_audio(data.get("data", ""))

            elif msg_type == "text":
                # Text input - send as user message
                text = data.get("text", "")
                logger.info(f"[{user_id}] Received text input: {text[:50]}...")
                await websocket.send_json({"type": "status", "state": "processing"})
                await adapter.send_text(text)

            elif msg_type == "function_result":
                call_id = data.get("call_id")
                result = data.get("result", {})
                logger.info(f"[{user_id}] Function result: call_id={call_id} result={result}")
                await adapter.send_function_result(call_id, result)

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except Exception as e:
        logger.error(f"Voice session error: {e}")
        try:
            await websocket.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        await adapter.disconnect()
