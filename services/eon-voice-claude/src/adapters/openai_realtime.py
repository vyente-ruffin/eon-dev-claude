"""Azure OpenAI Realtime API adapter."""

import asyncio
import json
import logging
from typing import Optional

from websockets.asyncio.client import connect as ws_connect
import websockets

from .base import VoiceAdapter, VoiceConfig

logger = logging.getLogger(__name__)


class OpenAIRealtimeAdapter(VoiceAdapter):
    """Adapter for Azure OpenAI Realtime API (all-in-one STT + LLM + TTS)."""

    @classmethod
    def name(cls) -> str:
        return "openai_realtime"

    def __init__(self, config: VoiceConfig):
        super().__init__(config)
        self._ws = None
        self._event_task: Optional[asyncio.Task] = None
        self._connected = False

        # Build WebSocket URL (Azure OpenAI Preview format - supports voice config)
        # Per https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/realtime-audio-websockets
        endpoint = config.endpoint.rstrip('/')
        self._ws_url = f"{endpoint.replace('https://', 'wss://')}/openai/realtime?api-version=2024-10-01-preview&deployment={config.model}"

    async def connect(self) -> None:
        """Establish connection to Azure OpenAI Realtime API."""
        if self._connected:
            return

        # Connect with api-key header (Azure OpenAI requirement)
        headers = [("api-key", self.config.api_key)]

        logger.info(f"Connecting to: {self._ws_url}")
        self._ws = await ws_connect(self._ws_url, additional_headers=headers)
        logger.info("WebSocket connected")

        # Wait for session.created event
        msg = await self._ws.recv()
        data = json.loads(msg)
        if data.get("type") == "session.created":
            logger.info(f"Session created: {data.get('session', {}).get('id', 'unknown')}")
        else:
            logger.warning(f"Unexpected first message: {data.get('type')}")

        # Configure session
        await self._configure_session()
        self._connected = True

        # Send ready status
        if self.on_status:
            await self._call_callback(self.on_status, "ready")

        # Start event processing loop
        self._event_task = asyncio.create_task(self._process_events())

    async def _configure_session(self) -> None:
        """Configure the voice session with tools and instructions."""
        # Convert tools to OpenAI format
        openai_tools = []
        for tool in self.config.tools:
            if tool.get("type") == "function":
                openai_tools.append({
                    "type": "function",
                    "name": tool["name"],
                    "description": tool.get("description", ""),
                    "parameters": tool.get("parameters", {}),
                })

        # Build session config (per Azure OpenAI Realtime API preview reference)
        session_config = {
            "voice": self.config.voice,
            "instructions": self.config.instructions,
            "input_audio_transcription": {
                "model": "whisper-1"
            },
        }

        if openai_tools:
            session_config["tools"] = openai_tools
            session_config["tool_choice"] = "auto"
            logger.info(f"Configured {len(openai_tools)} tools")

        update_msg = {
            "type": "session.update",
            "session": session_config
        }

        logger.info(f"Sending session.update with voice={self.config.voice}: {json.dumps(update_msg)}")
        await self._ws.send(json.dumps(update_msg))

        # Wait for session.updated event
        msg = await self._ws.recv()
        data = json.loads(msg)
        if data.get("type") == "session.updated":
            session = data.get("session", {})
            session_voice = session.get("voice", "unknown")
            logger.info(f"Session configured - voice confirmed: {session_voice}")
            logger.info(f"Full session.updated response: {json.dumps(data)}")
        else:
            logger.warning(f"Unexpected response: {data.get('type')} - {data}")

        # Per Azure OpenAI Realtime API docs: Use conversation.item.create with system
        # message for authoritative instructions, then response.create to trigger.
        # Instructions in response.create are just "guidance" the model "might not follow".

        if self.config.greeting_cue:
            greeting_system_msg = (
                f"IMPORTANT: Your very first message MUST check in about: '{self.config.greeting_cue}'. "
                f"For example, if the cue is 'Check in about the presentation', say something like "
                f"'Hey! How's the presentation prep going?' "
                f"Be warm and natural. Do NOT say generic phrases like 'How can I help you today?'"
            )
        else:
            greeting_system_msg = (
                "IMPORTANT: Greet the user warmly. Be natural and friendly. "
                "Do NOT say generic phrases like 'How can I help you today?' or 'How can I assist you?'"
            )

        # Add system message to conversation context (authoritative per docs)
        system_item = {
            "type": "conversation.item.create",
            "item": {
                "type": "message",
                "role": "system",
                "content": [
                    {
                        "type": "input_text",
                        "text": greeting_system_msg
                    }
                ]
            }
        }
        await self._ws.send(json.dumps(system_item))
        logger.info(f"Added greeting system message: {greeting_system_msg[:80]}...")

        # Wait for conversation.item.created confirmation
        msg = await self._ws.recv()
        data = json.loads(msg)
        if data.get("type") == "conversation.item.created":
            logger.info("Greeting system message added to conversation")
        else:
            logger.warning(f"Unexpected response after system message: {data.get('type')}")

        # Now trigger response generation
        greeting_response = {
            "type": "response.create",
            "response": {
                "modalities": ["text", "audio"]
            }
        }
        await self._ws.send(json.dumps(greeting_response))
        logger.info(f"Triggered initial greeting with cue: {self.config.greeting_cue}")

    async def disconnect(self) -> None:
        """Close the connection."""
        if self._event_task:
            self._event_task.cancel()
            try:
                await self._event_task
            except asyncio.CancelledError:
                pass
            self._event_task = None

        if self._ws:
            await self._ws.close()
            self._ws = None

        self._connected = False

    async def send_audio(self, audio_base64: str) -> None:
        """Send audio data to the API."""
        if not self._ws:
            raise RuntimeError("Not connected. Call connect() first.")

        msg = {
            "type": "input_audio_buffer.append",
            "audio": audio_base64
        }
        await self._ws.send(json.dumps(msg))

    async def send_text(self, text: str) -> None:
        """Send text as user message (same as transcribed speech)."""
        if not self._ws:
            raise RuntimeError("Not connected. Call connect() first.")

        msg = {
            "type": "conversation.item.create",
            "item": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": text}]
            }
        }
        await self._ws.send(json.dumps(msg))
        await self._ws.send(json.dumps({"type": "response.create"}))

    async def send_function_result(self, call_id: str, result: dict) -> None:
        """Send function call result back to the API."""
        if not self._ws:
            raise RuntimeError("Not connected")

        response_msg = {
            "type": "conversation.item.create",
            "item": {
                "type": "function_call_output",
                "call_id": call_id,
                "output": json.dumps(result)
            }
        }
        await self._ws.send(json.dumps(response_msg))
        logger.info(f"Function output sent for call_id={call_id}")

        # Request new response to continue the conversation
        await self._ws.send(json.dumps({"type": "response.create"}))

    async def _process_events(self) -> None:
        """Process events from the API."""
        try:
            async for msg in self._ws:
                data = json.loads(msg)
                await self._handle_event(data)
        except asyncio.CancelledError:
            raise
        except websockets.exceptions.ConnectionClosed:
            logger.info("WebSocket connection closed")
        except Exception as e:
            logger.error(f"Event processing error: {e}")
            if self.on_error:
                await self._call_callback(self.on_error, str(e))

    async def _handle_event(self, event: dict) -> None:
        """Handle individual events."""
        event_type = event.get("type", "unknown")

        if event_type == "input_audio_buffer.speech_started":
            if self.on_speech_started:
                await self._call_callback(self.on_speech_started)
            if self.on_status:
                await self._call_callback(self.on_status, "listening")

        elif event_type == "input_audio_buffer.speech_stopped":
            if self.on_speech_stopped:
                await self._call_callback(self.on_speech_stopped)
            if self.on_status:
                await self._call_callback(self.on_status, "processing")

        elif event_type in ("response.audio.delta", "response.output_audio.delta"):
            if self.on_audio:
                await self._call_callback(self.on_audio, event.get("delta", ""))

        elif event_type in ("response.audio_transcript.delta", "response.output_audio_transcript.delta"):
            if self.on_transcript:
                await self._call_callback(self.on_transcript, event.get("delta", ""))

        elif event_type == "conversation.item.input_audio_transcription.completed":
            # Log user's speech transcription
            transcript = event.get("transcript", "")
            logger.info(f"[{self.config.user_id}] User said: {transcript}")

        elif event_type == "response.done":
            # Log completed response info
            response = event.get("response", {})
            output = response.get("output", [])
            for item in output:
                if item.get("type") == "message":
                    content = item.get("content", [])
                    for c in content:
                        if c.get("type") == "audio" and c.get("transcript"):
                            logger.info(f"[{self.config.user_id}] Eon said: {c.get('transcript')}")
            if self.on_status:
                await self._call_callback(self.on_status, "ready")

        elif event_type == "response.function_call_arguments.done":
            await self._handle_function_call(event)

        elif event_type == "error":
            error_msg = event.get("error", {}).get("message", str(event))
            logger.error(f"API error: {error_msg}")
            if self.on_error:
                await self._call_callback(self.on_error, error_msg)

    async def _handle_function_call(self, event: dict) -> None:
        """Handle function call from the model."""
        function_name = event.get("name", "")
        call_id = event.get("call_id", "")
        arguments_str = event.get("arguments", "")

        logger.info(f"[{self.config.user_id}] Function call: {function_name} (call_id={call_id}) raw_args={arguments_str}")

        # Parse arguments
        try:
            arguments = json.loads(arguments_str) if arguments_str else {}
        except json.JSONDecodeError:
            logger.error(f"[{self.config.user_id}] Failed to parse arguments: {arguments_str}")
            arguments = {}

        # Inject user_id for user-scoped functions
        if function_name in ("search_memory", "add_memory", "get_user_context", "forget_memory") or function_name.startswith("GoogleCalendar_"):
            arguments["user_id"] = self.config.user_id
            logger.info(f"[{self.config.user_id}] Injected user_id into {function_name}")

        # Notify via callback
        if self.on_function_call:
            await self._call_callback(
                self.on_function_call,
                function_name,
                {"call_id": call_id, "arguments": arguments}
            )
