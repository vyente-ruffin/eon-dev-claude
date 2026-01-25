/**
 * Eon Voice Interface
 *
 * Browser-based voice assistant with WebSocket connection to backend,
 * audio capture/playback, and hexagonal core visualizations.
 */

// Configuration
const SAMPLE_RATE = 24000;
const CHUNK_MS = 50;
const CHUNK_SIZE = (SAMPLE_RATE * CHUNK_MS) / 1000; // 1200 samples per chunk

// State
let ws = null;
let audioContext = null;
let micStream = null;
let workletNode = null;
let muted = false;
let systemState = 'idle'; // idle, ready, listening, processing, speaking, micError
let hasMicError = false; // Flag to prevent overwriting mic error state

// Audio queue for playback
const audioQueue = [];
let isPlaying = false;

// Visualization intensities
let userIntensity = 0;
let agentIntensity = 0;

// DOM elements
const statusIndicator = document.getElementById('status-indicator');
const statusText = document.getElementById('status-text');
const userCanvas = document.getElementById('user-canvas');
const agentCanvas = document.getElementById('agent-canvas');
const userStatus = document.getElementById('user-status');
const agentStatus = document.getElementById('agent-status');
const systemStateEl = document.getElementById('system-state');
const muteButton = document.getElementById('mute-button');
const muteIcon = document.getElementById('mute-icon');
const transcriptContainer = document.getElementById('transcript-container');
const transcriptText = document.getElementById('transcript-text');
const textInput = document.getElementById('text-input');
const sendButton = document.getElementById('send-button');

// Canvas contexts
const userCtx = userCanvas.getContext('2d');
const agentCtx = agentCanvas.getContext('2d');

/**
 * Calculate RMS (root mean square) for audio intensity
 */
function calculateRMS(samples) {
  let sum = 0;
  for (let i = 0; i < samples.length; i++) {
    sum += samples[i] * samples[i];
  }
  return Math.sqrt(sum / samples.length);
}

/**
 * Convert Float32 samples to PCM16 base64
 */
function floatToPCM16Base64(samples) {
  const buffer = new ArrayBuffer(samples.length * 2);
  const view = new DataView(buffer);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

/**
 * Convert PCM16 base64 to Float32 samples
 */
function pcm16ToFloat32(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  const view = new DataView(bytes.buffer);
  const samples = new Float32Array(bytes.length / 2);
  for (let i = 0; i < samples.length; i++) {
    const int16 = view.getInt16(i * 2, true);
    samples[i] = int16 / (int16 < 0 ? 0x8000 : 0x7fff);
  }
  return samples;
}

/**
 * Resample audio from source rate to target rate (24kHz)
 */
function resampleTo24kHz(samples, fromRate) {
  if (fromRate === SAMPLE_RATE) return samples;

  const ratio = fromRate / SAMPLE_RATE;
  const newLength = Math.round(samples.length / ratio);
  const result = new Float32Array(newLength);

  for (let i = 0; i < newLength; i++) {
    const srcIndex = i * ratio;
    const srcIndexFloor = Math.floor(srcIndex);
    const srcIndexCeil = Math.min(srcIndexFloor + 1, samples.length - 1);
    const t = srcIndex - srcIndexFloor;
    result[i] = samples[srcIndexFloor] * (1 - t) + samples[srcIndexCeil] * t;
  }

  return result;
}

/**
 * Update connection status UI
 */
function setConnectionState(state) {
  statusIndicator.className = 'status-indicator ' + state;
  statusText.className = 'status-text ' + state;

  switch (state) {
    case 'connected':
      statusText.textContent = 'Online';
      break;
    case 'connecting':
      statusText.textContent = 'Connecting...';
      break;
    default:
      statusText.textContent = 'Offline';
  }
}

/**
 * Update system state UI
 */
function setSystemState(state) {
  // Don't overwrite mic error state
  if (hasMicError) {
    return;
  }

  systemState = state;
  systemStateEl.className = 'system-state ' + state;

  switch (state) {
    case 'listening':
      systemStateEl.textContent = 'Listening';
      userStatus.className = 'core-status active';
      userStatus.textContent = muted ? 'Muted' : 'Active';
      break;
    case 'processing':
      systemStateEl.textContent = 'Processing';
      userStatus.className = 'core-status';
      userStatus.textContent = 'Active';
      break;
    case 'speaking':
      systemStateEl.textContent = 'Speaking';
      agentStatus.className = 'core-status active';
      agentStatus.textContent = 'Transmitting';
      break;
    case 'ready':
      systemStateEl.textContent = 'Ready';
      userStatus.className = 'core-status';
      userStatus.textContent = muted ? 'Muted' : 'Active';
      agentStatus.className = 'core-status';
      agentStatus.textContent = 'Standby';
      break;
    default:
      systemStateEl.textContent = 'Standby';
      userStatus.className = 'core-status';
      userStatus.textContent = 'Active';
      agentStatus.className = 'core-status';
      agentStatus.textContent = 'Standby';
  }

  // Update mute status visuals
  if (muted) {
    userStatus.className = 'core-status muted';
    userStatus.textContent = 'Muted';
  }
}

/**
 * Play audio from the queue
 */
async function playAudioQueue() {
  if (isPlaying || audioQueue.length === 0) return;
  if (!audioContext) return;

  // Resume AudioContext if suspended (browser autoplay policy)
  if (audioContext.state === 'suspended') {
    console.log('Resuming AudioContext...');
    await audioContext.resume();
  }

  isPlaying = true;
  console.log(`Playing ${audioQueue.length} audio chunks`);

  while (audioQueue.length > 0) {
    const samples = audioQueue.shift();
    console.log(`Playing chunk with ${samples.length} samples`);

    // Update agent intensity
    const rms = calculateRMS(samples);
    agentIntensity = Math.min(1, rms * 5);

    // Create and play buffer
    const buffer = audioContext.createBuffer(1, samples.length, SAMPLE_RATE);
    buffer.getChannelData(0).set(samples);

    const source = audioContext.createBufferSource();
    source.buffer = buffer;
    source.connect(audioContext.destination);
    source.start();

    // Wait for playback to complete
    await new Promise(resolve => setTimeout(resolve, (samples.length / SAMPLE_RATE) * 1000));
  }

  agentIntensity = 0;
  isPlaying = false;

  // Return to ready state after speaking
  if (systemState === 'speaking') {
    setSystemState('ready');
  }
}

/**
 * Clear audio queue (for barge-in)
 */
function clearAudioQueue() {
  audioQueue.length = 0;
  agentIntensity = 0;
  isPlaying = false;
}

/**
 * Handle WebSocket messages
 */
async function handleMessage(event) {
  try {
    const data = JSON.parse(event.data);

    switch (data.type) {
      case 'connected':
        setConnectionState('connected');
        setSystemState('ready');
        break;

      case 'status':
        if (data.state === 'listening') {
          setSystemState('listening');
        } else if (data.state === 'processing') {
          setSystemState('processing');
        } else if (data.state === 'ready') {
          setSystemState('ready');
        }
        break;

      case 'audio':
        console.log('Received audio chunk from server');
        const samples = pcm16ToFloat32(data.data);
        console.log(`Decoded ${samples.length} samples`);
        audioQueue.push(samples);
        setSystemState('speaking');
        playAudioQueue();
        break;

      case 'transcript':
        transcriptContainer.style.display = 'block';
        transcriptText.textContent += data.text;
        break;

      case 'clear_audio':
        // Barge-in: clear playback queue
        clearAudioQueue();
        break;

      case 'mute_status':
        muted = data.muted;
        updateMuteUI();
        break;

      case 'error':
        console.error('Server error:', data.message);
        break;

      case 'auth_required':
        // Start OAuth session by setting cookie with user_id
        console.log('Auth required, setting up OAuth session...');
        try {
          const token = sessionStorage.getItem('eon_access_token');
          await fetch(`${EON_CONFIG.API_URL}/api/arcade/start-auth`, {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${token}`,
              'Content-Type': 'application/json'
            },
            credentials: 'include'  // Important: include cookies
          });
        } catch (e) {
          console.warn('Failed to set OAuth session cookie:', e);
        }

        // Open OAuth popup for Google Calendar authorization
        console.log('Opening popup:', data.auth_url);
        const authPopup = window.open(data.auth_url, 'arcade_auth', 'width=500,height=700,popup=true');
        // Poll for auth completion
        const pollAuth = setInterval(async () => {
          try {
            const resp = await fetch(`${EON_CONFIG.API_URL}/api/arcade/auth/${data.auth_id}`);
            const result = await resp.json();
            if (result.status === 'completed') {
              clearInterval(pollAuth);
              if (authPopup && !authPopup.closed) authPopup.close();
              console.log('Auth completed');
            }
          } catch (e) {
            console.error('Auth poll error:', e);
          }
        }, 2000);
        // Stop polling after 5 minutes
        setTimeout(() => clearInterval(pollAuth), 300000);
        break;
    }
  } catch (e) {
    console.error('Failed to parse message:', e);
  }
}

/**
 * Connect to WebSocket server
 */
function connectWebSocket() {
  if (ws && ws.readyState === WebSocket.OPEN) return;

  setConnectionState('connecting');

  // Use config for WebSocket URL (supports Static Web App deployment)
  const baseUrl = `${EON_CONFIG.WS_URL}/ws/voice`;
  const wsUrl = buildWebSocketUrl(baseUrl);

  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    console.log('WebSocket connected');
  };

  ws.onmessage = handleMessage;

  ws.onerror = (error) => {
    console.error('WebSocket error:', error);
    setConnectionState('disconnected');
  };

  ws.onclose = () => {
    console.log('WebSocket closed');
    setConnectionState('disconnected');
    setSystemState('idle');
    // Reconnect after 2 seconds
    setTimeout(connectWebSocket, 2000);
  };
}

/**
 * Check if we're in a secure context (HTTPS or localhost)
 */
function isSecureContext() {
  // window.isSecureContext is the standard way to check
  if (typeof window.isSecureContext !== 'undefined') {
    return window.isSecureContext;
  }
  // Fallback: check protocol and hostname
  const protocol = window.location.protocol;
  const hostname = window.location.hostname;
  if (protocol === 'https:') return true;
  if (hostname === 'localhost' || hostname === '127.0.0.1') return true;
  return false;
}

/**
 * Show microphone unavailable error in the UI
 */
function showMicrophoneError(message) {
  // Set flag to prevent other code from overwriting error state
  hasMicError = true;
  systemState = 'micError';

  // Update system state to show error
  systemStateEl.className = 'system-state error';
  systemStateEl.textContent = 'Mic Unavailable';

  // Update user status
  userStatus.className = 'core-status error';
  userStatus.textContent = 'No Mic';

  // Show transcript area with error message
  transcriptContainer.style.display = 'block';
  transcriptText.textContent = message;
  transcriptText.style.color = '#ff6b6b';

  console.error('Microphone error:', message);
}

/**
 * Start microphone capture
 */
async function startMicrophone() {
  // Check for secure context first
  if (!isSecureContext()) {
    const hostname = window.location.hostname;
    showMicrophoneError(
      `Microphone requires HTTPS or localhost. ` +
      `You're accessing via "${hostname}" over HTTP. ` +
      `Either use https://${hostname}:8000 with SSL, ` +
      `or access via http://localhost:8000 from the same machine.`
    );
    return;
  }

  // Check if getUserMedia is available
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    showMicrophoneError(
      'Your browser does not support microphone access. ' +
      'Please use a modern browser like Chrome, Firefox, or Edge.'
    );
    return;
  }

  try {
    // Request microphone access
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        sampleRate: SAMPLE_RATE,
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
      }
    });

    micStream = stream;

    // Create AudioContext
    audioContext = new AudioContext({ sampleRate: SAMPLE_RATE });
    const actualSampleRate = audioContext.sampleRate;
    console.log(`AudioContext sample rate: ${actualSampleRate}`);

    // Calculate chunk size based on actual sample rate
    const actualChunkSize = Math.round((actualSampleRate * CHUNK_MS) / 1000);

    // Create AudioWorklet processor
    const workletCode = `
      class AudioProcessor extends AudioWorkletProcessor {
        constructor() {
          super();
          this.buffer = [];
          this.chunkSize = ${actualChunkSize};
        }

        process(inputs) {
          const input = inputs[0];
          if (input.length > 0) {
            const samples = input[0];
            this.buffer.push(...samples);

            while (this.buffer.length >= this.chunkSize) {
              const chunk = this.buffer.splice(0, this.chunkSize);
              this.port.postMessage({ samples: new Float32Array(chunk) });
            }
          }
          return true;
        }
      }

      registerProcessor('audio-processor', AudioProcessor);
    `;

    const blob = new Blob([workletCode], { type: 'application/javascript' });
    const workletUrl = URL.createObjectURL(blob);
    await audioContext.audioWorklet.addModule(workletUrl);

    const source = audioContext.createMediaStreamSource(stream);
    workletNode = new AudioWorkletNode(audioContext, 'audio-processor');

    workletNode.port.onmessage = (event) => {
      let { samples } = event.data;

      // Resample to 24kHz if needed
      if (actualSampleRate !== SAMPLE_RATE) {
        samples = resampleTo24kHz(samples, actualSampleRate);
      }

      // Update user intensity
      const rms = calculateRMS(samples);
      userIntensity = muted ? 0 : Math.min(1, rms * 8);

      // Send to server if connected and not muted
      if (ws && ws.readyState === WebSocket.OPEN && !muted) {
        const base64 = floatToPCM16Base64(samples);
        ws.send(JSON.stringify({ type: 'audio', data: base64 }));
      }
    };

    source.connect(workletNode);
    // Don't connect to destination - we only want to process mic input, not output it

    console.log('Microphone started');
  } catch (error) {
    console.error('Microphone error:', error);
    alert('Could not access microphone. Please grant permission and reload.');
  }
}

/**
 * Toggle mute state
 */
function toggleMute() {
  muted = !muted;
  userIntensity = 0;
  updateMuteUI();

  // Notify server
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'mute', muted: muted }));
  }
}

/**
 * Create SVG element with namespace
 */
function createSvgElement(tag) {
  return document.createElementNS('http://www.w3.org/2000/svg', tag);
}

/**
 * Update mute button UI using DOM methods (safe, no innerHTML)
 */
function updateMuteUI() {
  // Clear existing SVG content
  while (muteIcon.firstChild) {
    muteIcon.removeChild(muteIcon.firstChild);
  }

  if (muted) {
    muteButton.classList.add('muted');

    // Muted icon paths
    const path1 = createSvgElement('path');
    path1.setAttribute('d', 'M1 1l22 22M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V4a3 3 0 0 0-5.94-.6');

    const path2 = createSvgElement('path');
    path2.setAttribute('d', 'M17 16.95A7 7 0 0 1 5 12v-2m14 0v2a7 7 0 0 1-.11 1.23');

    const line1 = createSvgElement('line');
    line1.setAttribute('x1', '12');
    line1.setAttribute('y1', '19');
    line1.setAttribute('x2', '12');
    line1.setAttribute('y2', '23');

    const line2 = createSvgElement('line');
    line2.setAttribute('x1', '8');
    line2.setAttribute('y1', '23');
    line2.setAttribute('x2', '16');
    line2.setAttribute('y2', '23');

    muteIcon.appendChild(path1);
    muteIcon.appendChild(path2);
    muteIcon.appendChild(line1);
    muteIcon.appendChild(line2);

    userStatus.className = 'core-status muted';
    userStatus.textContent = 'Muted';
  } else {
    muteButton.classList.remove('muted');

    // Unmuted icon paths
    const path1 = createSvgElement('path');
    path1.setAttribute('d', 'M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z');

    const path2 = createSvgElement('path');
    path2.setAttribute('d', 'M19 10v2a7 7 0 0 1-14 0v-2');

    const line1 = createSvgElement('line');
    line1.setAttribute('x1', '12');
    line1.setAttribute('y1', '19');
    line1.setAttribute('x2', '12');
    line1.setAttribute('y2', '23');

    const line2 = createSvgElement('line');
    line2.setAttribute('x1', '8');
    line2.setAttribute('y1', '23');
    line2.setAttribute('x2', '16');
    line2.setAttribute('y2', '23');

    muteIcon.appendChild(path1);
    muteIcon.appendChild(path2);
    muteIcon.appendChild(line1);
    muteIcon.appendChild(line2);

    userStatus.className = 'core-status';
    userStatus.textContent = 'Active';
  }
}

/**
 * Draw hexagonal core with effects
 */
function drawCore(ctx, centerX, centerY, time, options) {
  const { color, glowColor, intensity, isActive } = options;
  const baseRadius = 60;
  const maxExpand = 25;

  // Calculate current radius based on intensity
  const targetRadius = baseRadius + intensity * maxExpand;

  // Breathing effect when idle
  const breathe = isActive ? 0 : Math.sin(time * 2) * 3;
  const radius = targetRadius + breathe;

  ctx.save();

  // Outer glow
  const gradient = ctx.createRadialGradient(
    centerX, centerY, radius * 0.5,
    centerX, centerY, radius * 2
  );
  gradient.addColorStop(0, glowColor);
  gradient.addColorStop(0.5, 'rgba(0,0,0,0)');
  gradient.addColorStop(1, 'rgba(0,0,0,0)');

  ctx.beginPath();
  ctx.arc(centerX, centerY, radius * 2, 0, Math.PI * 2);
  ctx.fillStyle = gradient;
  ctx.fill();

  // Draw hexagonal frame
  ctx.beginPath();
  for (let i = 0; i < 6; i++) {
    const angle = (Math.PI / 3) * i - Math.PI / 2;
    const x = centerX + Math.cos(angle) * radius;
    const y = centerY + Math.sin(angle) * radius;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.closePath();
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.shadowColor = color;
  ctx.shadowBlur = isActive ? 20 + intensity * 15 : 10;
  ctx.stroke();

  // Inner hexagon (rotating)
  const innerRadius = radius * 0.6;
  ctx.beginPath();
  for (let i = 0; i < 6; i++) {
    const angle = (Math.PI / 3) * i - Math.PI / 2 + time * 0.5;
    const x = centerX + Math.cos(angle) * innerRadius;
    const y = centerY + Math.sin(angle) * innerRadius;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.closePath();
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;
  ctx.globalAlpha = 0.5;
  ctx.stroke();
  ctx.globalAlpha = 1;

  // Center core
  const coreRadius = radius * 0.25 + intensity * 8;
  const coreGradient = ctx.createRadialGradient(
    centerX, centerY, 0,
    centerX, centerY, coreRadius
  );
  coreGradient.addColorStop(0, 'white');
  coreGradient.addColorStop(0.3, color);
  coreGradient.addColorStop(1, 'transparent');

  ctx.beginPath();
  ctx.arc(centerX, centerY, coreRadius, 0, Math.PI * 2);
  ctx.fillStyle = coreGradient;
  ctx.fill();

  // Scanning line effect
  if (isActive) {
    const scanY = centerY + Math.sin(time * 3) * radius * 0.8;
    ctx.beginPath();
    ctx.moveTo(centerX - radius, scanY);
    ctx.lineTo(centerX + radius, scanY);
    ctx.strokeStyle = color;
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.6;
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  // Particle effects when active
  if (isActive && intensity > 0.1) {
    const particleCount = Math.floor(intensity * 8);
    for (let i = 0; i < particleCount; i++) {
      const angle = (Math.PI * 2 * i) / particleCount + time;
      const dist = radius + Math.sin(time * 4 + i) * 15 + 10;
      const px = centerX + Math.cos(angle) * dist;
      const py = centerY + Math.sin(angle) * dist;
      const size = 1 + intensity * 2;

      ctx.beginPath();
      ctx.arc(px, py, size, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.globalAlpha = 0.6;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
  }

  // Data readout ring
  ctx.beginPath();
  ctx.arc(centerX, centerY, radius + 15, 0, Math.PI * 2);
  ctx.strokeStyle = color;
  ctx.lineWidth = 0.5;
  ctx.globalAlpha = 0.2;
  ctx.stroke();
  ctx.globalAlpha = 1;

  ctx.restore();
}

/**
 * Animation loop
 */
function animate(timestamp) {
  const t = timestamp / 1000;

  // Clear canvases
  userCtx.clearRect(0, 0, userCanvas.width, userCanvas.height);
  agentCtx.clearRect(0, 0, agentCanvas.width, agentCanvas.height);

  // Draw user core (cyan)
  drawCore(userCtx, userCanvas.width / 2, userCanvas.height / 2, t, {
    color: '#00d4ff',
    glowColor: 'rgba(0, 212, 255, 0.3)',
    intensity: userIntensity,
    isActive: systemState === 'listening' && !muted,
  });

  // Draw agent core (orange)
  drawCore(agentCtx, agentCanvas.width / 2, agentCanvas.height / 2, t, {
    color: '#ff9500',
    glowColor: 'rgba(255, 149, 0, 0.3)',
    intensity: agentIntensity,
    isActive: systemState === 'speaking',
  });

  // Decay intensities
  userIntensity *= 0.92;
  agentIntensity *= 0.95;

  requestAnimationFrame(animate);
}

/**
 * Handle keyboard shortcuts
 */
function handleKeyDown(e) {
  if (e.key.toLowerCase() === 'm' && !e.metaKey && !e.ctrlKey) {
    // Don't toggle mute if typing in text input
    if (document.activeElement === textInput) return;
    toggleMute();
  }
}

/**
 * Send text message (simulates voice input)
 */
function sendTextMessage() {
  const text = textInput.value.trim();
  if (!text) return;

  // Check WebSocket connection
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    console.error('WebSocket not connected');
    return;
  }

  // Send text message to server
  ws.send(JSON.stringify({
    type: 'text',
    text: text
  }));

  // Clear input
  textInput.value = '';

  // Update UI to show processing
  setSystemState('processing');
  console.log('Sent text message:', text);
}

/**
 * Handle text input keypress (Enter to send)
 */
function handleTextInputKeypress(e) {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendTextMessage();
  }
}

/**
 * Handle user logout
 * Clears auth state and keeps the app in anonymous mode.
 */
async function handleLogout() {
  try {
    // Clear local auth state
    clearAuth();
    displayUserIdInElement('user-id-suffix');
    console.log('Anonymous user:', getUserId());
  } catch (error) {
    console.error('Logout error:', error);
    displayUserIdInElement('user-id-suffix');
  }
}

/**
 * Initialize application
 */
async function init() {
  // Wait for config to load before connecting
  await getConfig();

  // Display user info in UI
  if (isAuthenticated()) {
    // Show authenticated user name
    const userNameEl = document.getElementById('user-id-suffix');
    if (userNameEl) {
      userNameEl.textContent = getUserDisplayName();
    }
    console.log('Authenticated user:', getUserId());
  } else {
    // Show anonymous user ID suffix
    displayUserIdInElement('user-id-suffix');
    console.log('Anonymous user:', getUserId());
  }

  // Set up event listeners
  muteButton.addEventListener('click', toggleMute);
  window.addEventListener('keydown', handleKeyDown);

  // Text input event listeners
  sendButton.addEventListener('click', sendTextMessage);
  textInput.addEventListener('keypress', handleTextInputKeypress);

  // Start animation loop
  requestAnimationFrame(animate);

  // Connect to server
  connectWebSocket();

  // Start microphone (requires user gesture in some browsers)
  // Try to start immediately, but also listen for user interaction
  try {
    await startMicrophone();
  } catch (e) {
    console.log('Waiting for user interaction to start microphone...');
    document.body.addEventListener('click', async () => {
      if (!micStream) {
        await startMicrophone();
      }
    }, { once: true });
  }
}

// Start when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
