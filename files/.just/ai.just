# `os ai::*` — manage the local AI service stack.

# Start the local AI stack (Ollama, LiteLLM, ComfyUI, Langflow, Langfuse, WebUI, n8n).
up:
    sudo systemctl start ollama.service container@litellm.service podman-comfyui.service podman-langflow.service container@langfuse.service container@langfuse-db.service container@open-webui.service container@n8n.service

# Stop the local AI stack.
down:
    sudo systemctl stop ollama.service container@litellm.service podman-comfyui.service podman-langflow.service container@langfuse.service container@langfuse-db.service container@open-webui.service container@n8n.service

# Status snapshot of the local AI stack.
status:
    systemctl status ollama.service container@litellm.service podman-comfyui.service podman-langflow.service container@langfuse.service container@langfuse-db.service container@open-webui.service container@n8n.service

# Follow logs from the local AI stack.
logs:
    journalctl -u ollama.service -u container@litellm.service -u podman-comfyui.service -u podman-langflow.service -u container@langfuse.service -u container@langfuse-db.service -u container@open-webui.service -u container@n8n.service -f
