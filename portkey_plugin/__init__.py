"""Portkey AI Gateway provider plugin for Hermes Agent."""

import os
from providers import register_provider
from providers.base import ProviderProfile

portkey = ProviderProfile(
    name="portkey",
    aliases=("portkey-ai", "portkey_ai"),
    display_name="Portkey AI Gateway",
    description="Portkey — unified AI gateway with observability and fallbacks",
    signup_url="https://app.portkey.ai/",
    env_vars=("PORTKEY_API_KEY",),
    base_url="https://api.portkey.ai/v1",
    default_headers={
        "x-portkey-api-key": os.environ.get("PORTKEY_API_KEY", ""),
        "x-portkey-config": os.environ.get("PORTKEY_CONFIG", "pc-gemini-85dd0b"),
    },
    fallback_models=("gemini-3.5-flash",),
    default_aux_model="gemini-3.5-flash",
)

register_provider(portkey)
