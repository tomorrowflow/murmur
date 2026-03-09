import os

from dotenv import load_dotenv

load_dotenv()


class Config:
    # ComfyUI
    COMFYUI_BASE_URL: str = os.getenv("COMFYUI_BASE_URL", "http://comfyui:8188")
    VIBEVOICE_WORKFLOW: str = os.getenv("VIBEVOICE_WORKFLOW", "vibevoice_podcast.json")

    # Audio — ComfyUI output dir mounted read-only into podcastd
    AUDIO_CACHE_DIR: str = os.getenv("AUDIO_CACHE_DIR", "/comfyui_output")
    # Writable dir for MP3 conversions (AUDIO_CACHE_DIR may be read-only)
    MP3_CACHE_DIR: str = os.getenv("MP3_CACHE_DIR", "/tmp/podcast_mp3")

    # ComfyUI input dir — mounted r/w for uploading voice samples
    COMFYUI_INPUT_DIR: str = os.getenv("COMFYUI_INPUT_DIR", "/comfyui_input")

    # Servers
    WS_HOST: str = os.getenv("WS_HOST", "0.0.0.0")
    WS_PORT: int = int(os.getenv("WS_PORT", "8765"))
    HTTP_HOST: str = os.getenv("HTTP_HOST", "0.0.0.0")
    HTTP_PORT: int = int(os.getenv("HTTP_PORT", "8766"))

    # Voice — calibrate once, never change
    VOICE_SEED_A: int = int(os.getenv("VOICE_SEED_A", "42"))
    VOICE_SEED_B: int = int(os.getenv("VOICE_SEED_B", "137"))
    HOST_A_NAME: str = os.getenv("HOST_A_NAME", "Alex")
    HOST_B_NAME: str = os.getenv("HOST_B_NAME", "Jordan")

    # Voice reference audio files (from ComfyUI input dir)
    VOICE_REF_SPEAKER1: str = os.getenv("VOICE_REF_SPEAKER1", "en-Carter_man.wav")
    VOICE_REF_SPEAKER2: str = os.getenv("VOICE_REF_SPEAKER2", "en-Alice_woman.wav")

    # VibeVoice models
    CHUNK_MODEL: str = os.getenv("CHUNK_MODEL", "VibeVoice-Large-Q8")
    INTERRUPT_MODEL: str = os.getenv("INTERRUPT_MODEL", "VibeVoice7b-low-vram")

    # LLM
    LLM_PROVIDER: str = os.getenv("LLM_PROVIDER", "ollama")
    LLM_MODEL: str = os.getenv("LLM_MODEL", "qwen3:32b")
    LLM_API_KEY: str = os.getenv("LLM_API_KEY", "")
    OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "http://host.docker.internal:11434")

    # Ollama Web Search
    OLLAMA_API_KEY: str = os.getenv("OLLAMA_API_KEY", "")
    WEB_SEARCH_ENABLED: bool = os.getenv("WEB_SEARCH_ENABLED", "true").lower() == "true"
    WEB_SEARCH_MAX_RESULTS: int = int(os.getenv("WEB_SEARCH_MAX_RESULTS", "5"))

    # Tuning
    CHUNK_TARGET_WORDS: int = int(os.getenv("CHUNK_TARGET_WORDS", "210"))
    INTERRUPT_MAX_TURNS: int = int(os.getenv("INTERRUPT_MAX_TURNS", "6"))


cfg = Config()
