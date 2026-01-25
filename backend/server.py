"""
Eon Backend Server (Agnostic)

FastAPI WebSocket server that:
- Accepts text or audio input from frontend
- Forwards to voice service (swappable)
- Returns audio responses to frontend

Backend is agnostic to voice provider - all provider-specific
logic is in the voice service.
"""

import os
import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from websockets.asyncio.client import connect as ws_connect
import websockets.exceptions
from dotenv import load_dotenv

load_dotenv()

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Voice service configuration
VOICE_SERVICE_URL = os.environ.get("VOICE_SERVICE_URL", "ws://localhost:8001/ws/voice")

# Default instructions for the voice assistant
DEFAULT_INSTRUCTIONS = """You are Eon, a helpful and friendly AI assistant. Respond naturally and conversationally."""


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    logger.info("Eon backend starting...")
    logger.info(f"Voice Service URL: {VOICE_SERVICE_URL}")
    yield
    logger.info("Eon backend shutting down...")


app = FastAPI(title="Eon Backend", lifespan=lifespan)

# CORS for frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "ok"}


@app.websocket("/ws/voice")
async def voice_websocket(websocket: WebSocket, user_id: str = "anonymous"):
    """
    WebSocket endpoint for voice/text communication.

    Accepts:
    - {type: "text", text: "..."} - Text input
    - {type: "audio", data: "..."} - Base64 PCM16 audio

    Sends:
    - {type: "audio", data: "..."} - Base64 PCM16 audio response
    - {type: "transcript", text: "..."} - Response transcript
    - {type: "status", state: "..."} - Status updates
    - {type: "function_call", name: "...", call_id: "...", arguments: {...}}
    - {type: "speech_started"}
    - {type: "speech_stopped"}
    """
    await websocket.accept()
    logger.info(f"WebSocket connected: user_id={user_id}")

    # Connect to voice service
    voice_ws_url = f"{VOICE_SERVICE_URL}?user_id={user_id}"
    logger.info(f"Connecting to voice service: {voice_ws_url}")

    try:
        async with ws_connect(voice_ws_url) as voice_ws:
            logger.info("Connected to voice service")

            # Send configuration to voice service
            config_msg = {
                "type": "configure",
                "instructions": DEFAULT_INSTRUCTIONS,
                "tools": []  # Add tools here if needed
            }
            await voice_ws.send(str_to_json_bytes(config_msg))
            logger.info("Sent configuration to voice service")

            # Send connected status to frontend
            await websocket.send_json({"type": "connected"})

            # Run bidirectional forwarding
            await run_bidirectional_forwarding(websocket, voice_ws, user_id)

    except websockets.exceptions.InvalidStatusCode as e:
        error_msg = f"Voice service connection failed: {e.status_code}"
        logger.error(error_msg)
        await websocket.send_json({"type": "error", "message": error_msg})
    except websockets.exceptions.ConnectionClosed as e:
        logger.warning(f"Voice service connection closed: {e}")
    except Exception as e:
        logger.error(f"Error connecting to voice service: {e}")
        await websocket.send_json({"type": "error", "message": str(e)})
    finally:
        logger.info(f"Session ended: user_id={user_id}")


def str_to_json_bytes(data: dict) -> str:
    """Convert dict to JSON string for WebSocket."""
    import json
    return json.dumps(data)


async def run_bidirectional_forwarding(
    frontend_ws: WebSocket,
    voice_ws,
    user_id: str
) -> None:
    """
    Forward messages bidirectionally between frontend and voice service.

    Frontend -> Voice Service:
    - text messages
    - audio messages
    - function_result messages

    Voice Service -> Frontend:
    - audio messages
    - transcript messages
    - status messages
    - function_call messages
    - speech_started/stopped messages
    - error messages
    """
    import json

    async def forward_to_voice_service():
        """Forward messages from frontend to voice service."""
        try:
            while True:
                data = await frontend_ws.receive_json()
                msg_type = data.get("type")

                if msg_type == "text":
                    # Forward text input
                    logger.info(f"[{user_id}] Forwarding text: {data.get('text', '')[:50]}...")
                    await voice_ws.send(json.dumps(data))

                elif msg_type == "audio":
                    # Forward audio input
                    await voice_ws.send(json.dumps(data))

                elif msg_type == "function_result":
                    # Forward function result
                    logger.info(f"[{user_id}] Forwarding function result: {data.get('call_id')}")
                    await voice_ws.send(json.dumps(data))

                elif msg_type == "mute":
                    # Mute toggle - forward to voice service if it supports it
                    await voice_ws.send(json.dumps(data))

                else:
                    logger.debug(f"[{user_id}] Unknown message type from frontend: {msg_type}")

        except WebSocketDisconnect:
            logger.info(f"[{user_id}] Frontend disconnected")
        except Exception as e:
            logger.error(f"[{user_id}] Error forwarding to voice service: {e}")

    async def forward_from_voice_service():
        """Forward messages from voice service to frontend."""
        try:
            import json
            async for msg in voice_ws:
                data = json.loads(msg)
                msg_type = data.get("type")

                # Forward all messages to frontend
                if msg_type == "audio":
                    await frontend_ws.send_json(data)

                elif msg_type == "transcript":
                    logger.info(f"[{user_id}] Transcript: {data.get('text', '')[:50]}...")
                    await frontend_ws.send_json(data)

                elif msg_type == "status":
                    await frontend_ws.send_json(data)

                elif msg_type == "function_call":
                    # Forward function call - frontend or backend can handle it
                    logger.info(f"[{user_id}] Function call: {data.get('name')}")
                    await frontend_ws.send_json(data)

                elif msg_type == "speech_started":
                    await frontend_ws.send_json(data)

                elif msg_type == "speech_stopped":
                    await frontend_ws.send_json(data)

                elif msg_type == "connected":
                    # Voice service ready
                    logger.info(f"[{user_id}] Voice service ready")
                    await frontend_ws.send_json({"type": "status", "state": "ready"})

                elif msg_type == "error":
                    logger.error(f"[{user_id}] Voice service error: {data.get('message')}")
                    await frontend_ws.send_json(data)

                else:
                    logger.debug(f"[{user_id}] Unknown message type from voice service: {msg_type}")

        except websockets.exceptions.ConnectionClosed:
            logger.info(f"[{user_id}] Voice service connection closed")
        except Exception as e:
            logger.error(f"[{user_id}] Error receiving from voice service: {e}")

    # Run both directions concurrently
    forward_task = asyncio.create_task(forward_to_voice_service())
    receive_task = asyncio.create_task(forward_from_voice_service())

    try:
        # Wait for either task to complete (usually due to disconnect)
        done, pending = await asyncio.wait(
            [forward_task, receive_task],
            return_when=asyncio.FIRST_COMPLETED
        )

        # Cancel pending tasks
        for task in pending:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    except Exception as e:
        logger.error(f"[{user_id}] Session error: {e}")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
