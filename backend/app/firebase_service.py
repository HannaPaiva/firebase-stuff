from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

import firebase_admin
from firebase_admin import credentials, messaging


logger = logging.getLogger(__name__)
BACKEND_DIR = Path(__file__).resolve().parents[1]

_firebase_ready = False


def get_service_account_path() -> Path:
    configured_path = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH")
    if configured_path:
        return Path(configured_path)

    default_path = BACKEND_DIR / "firebase-service-account.json"
    if default_path.exists():
        return default_path

    candidates = sorted(BACKEND_DIR.glob("*firebase-adminsdk*.json"))
    if candidates:
        return candidates[0]

    generic_candidates = sorted(BACKEND_DIR.glob("*.json"))
    if generic_candidates:
        return generic_candidates[0]

    return default_path


def init_firebase() -> bool:
    global _firebase_ready

    if firebase_admin._apps:
        _firebase_ready = True
        return True

    service_account_path = get_service_account_path()

    if not service_account_path.exists():
        logger.warning(
            "Firebase service account not found at %s. Push sending is disabled until the file is added.",
            service_account_path,
        )
        _firebase_ready = False
        return False

    try:
        credential = credentials.Certificate(str(service_account_path))
        firebase_admin.initialize_app(credential)
        _firebase_ready = True
        return True
    except Exception as exc:
        logger.warning("Firebase initialization failed: %s", exc)
        _firebase_ready = False
        return False


def is_firebase_ready() -> bool:
    return _firebase_ready or bool(firebase_admin._apps)


def _stringify_data(data: dict[str, Any] | None) -> dict[str, str]:
    if not data:
        return {}

    return {str(key): str(value) for key, value in data.items()}


def send_push_to_token(
    token: str,
    title: str,
    body: str,
    data: dict[str, Any] | None = None,
) -> str:
    if not is_firebase_ready():
        raise RuntimeError(
            "Firebase Admin SDK is not initialized. Add a Firebase service account JSON in backend/ or set FIREBASE_SERVICE_ACCOUNT_PATH."
        )

    message = messaging.Message(
        token=token,
        notification=messaging.Notification(title=title, body=body),
        data=_stringify_data(data),
    )
    return messaging.send(message)
