# Agent Memory Server
# Built from upstream redis-projects/agent-memory-server
#
# This service provides long-term memory capabilities using Redis
# with vector search for semantic memory operations.

FROM python:3.11-slim

WORKDIR /app

# Install git to clone the upstream repo
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Clone the agent-memory-server repo
RUN git clone --depth 1 https://github.com/redis-projects/agent-memory-server.git .

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Expose the API port
EXPOSE 8000

# Run the server
CMD ["uvicorn", "agent_memory_server.main:app", "--host", "0.0.0.0", "--port", "8000"]
