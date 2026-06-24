from __future__ import annotations

import json
import os
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator
from uuid import uuid4

import duckdb


DB_PATH = Path(
    os.getenv(
        "DUCKDB_PATH",
        Path(__file__).resolve().parents[1] / "app.duckdb",
    )
)


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=None).isoformat(
        sep=" ",
        timespec="seconds",
    )


@contextmanager
def get_connection() -> Iterator[duckdb.DuckDBPyConnection]:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect(str(DB_PATH))
    try:
        yield connection
    finally:
        connection.close()


def init_db() -> None:
    with get_connection() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id UUID PRIMARY KEY DEFAULT uuid(),
                external_user_id VARCHAR UNIQUE NOT NULL,
                name VARCHAR,
                email VARCHAR,
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS devices (
                id UUID PRIMARY KEY DEFAULT uuid(),
                device_uid VARCHAR UNIQUE NOT NULL,
                platform VARCHAR NOT NULL,
                fcm_token VARCHAR NOT NULL,
                app_version VARCHAR,
                is_active BOOLEAN NOT NULL DEFAULT true,
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS user_device (
                user_id UUID NOT NULL,
                device_id UUID NOT NULL,
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL,
                PRIMARY KEY (user_id, device_id)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS notification_events (
                id UUID PRIMARY KEY DEFAULT uuid(),
                external_user_id VARCHAR,
                title VARCHAR NOT NULL,
                body VARCHAR NOT NULL,
                data JSON,
                status VARCHAR NOT NULL,
                provider_response JSON,
                created_at TIMESTAMP NOT NULL
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_users_external_user_id ON users (external_user_id)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_devices_device_uid ON devices (device_uid)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_user_device_user_id ON user_device (user_id)"
        )


def upsert_user_device(payload: dict[str, Any]) -> dict[str, str]:
    timestamp = now_iso()

    with get_connection() as conn:
        conn.execute("BEGIN TRANSACTION")
        try:
            user_row = conn.execute(
                "SELECT id FROM users WHERE external_user_id = ?",
                [payload["external_user_id"]],
            ).fetchone()

            if user_row:
                user_id = str(user_row[0])
                conn.execute(
                    """
                    UPDATE users
                    SET name = ?, email = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    [payload.get("name"), payload.get("email"), timestamp, user_id],
                )
            else:
                user_id = str(uuid4())
                conn.execute(
                    """
                    INSERT INTO users (
                        id,
                        external_user_id,
                        name,
                        email,
                        created_at,
                        updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        user_id,
                        payload["external_user_id"],
                        payload.get("name"),
                        payload.get("email"),
                        timestamp,
                        timestamp,
                    ],
                )

            device_row = conn.execute(
                "SELECT id FROM devices WHERE device_uid = ?",
                [payload["device_uid"]],
            ).fetchone()

            if device_row:
                device_id = str(device_row[0])
                conn.execute(
                    """
                    UPDATE devices
                    SET platform = ?,
                        fcm_token = ?,
                        app_version = ?,
                        is_active = true,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    [
                        payload["platform"],
                        payload["fcm_token"],
                        payload.get("app_version"),
                        timestamp,
                        device_id,
                    ],
                )
            else:
                device_id = str(uuid4())
                conn.execute(
                    """
                    INSERT INTO devices (
                        id,
                        device_uid,
                        platform,
                        fcm_token,
                        app_version,
                        is_active,
                        created_at,
                        updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, true, ?, ?)
                    """,
                    [
                        device_id,
                        payload["device_uid"],
                        payload["platform"],
                        payload["fcm_token"],
                        payload.get("app_version"),
                        timestamp,
                        timestamp,
                    ],
                )

            relation_row = conn.execute(
                """
                SELECT 1
                FROM user_device
                WHERE user_id = ? AND device_id = ?
                """,
                [user_id, device_id],
            ).fetchone()

            if relation_row:
                conn.execute(
                    """
                    UPDATE user_device
                    SET updated_at = ?
                    WHERE user_id = ? AND device_id = ?
                    """,
                    [timestamp, user_id, device_id],
                )
            else:
                conn.execute(
                    """
                    INSERT INTO user_device (
                        user_id,
                        device_id,
                        created_at,
                        updated_at
                    )
                    VALUES (?, ?, ?, ?)
                    """,
                    [user_id, device_id, timestamp, timestamp],
                )

            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise

    return {
        "user_id": user_id,
        "device_id": device_id,
        "external_user_id": payload["external_user_id"],
        "device_uid": payload["device_uid"],
    }


def get_active_devices_for_user(external_user_id: str) -> list[dict[str, Any]]:
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT
                d.id,
                d.device_uid,
                d.platform,
                d.fcm_token,
                d.app_version,
                d.is_active,
                d.updated_at
            FROM users u
            INNER JOIN user_device ud ON ud.user_id = u.id
            INNER JOIN devices d ON d.id = ud.device_id
            WHERE u.external_user_id = ?
              AND d.is_active = true
            ORDER BY d.updated_at DESC
            """,
            [external_user_id],
        ).fetchall()

    devices: list[dict[str, Any]] = []
    for row in rows:
        devices.append(
            {
                "device_id": str(row[0]),
                "device_uid": row[1],
                "platform": row[2],
                "fcm_token": row[3],
                "app_version": row[4],
                "is_active": bool(row[5]),
                "updated_at": str(row[6]),
            }
        )
    return devices


def deactivate_device_by_token(token: str) -> None:
    with get_connection() as conn:
        conn.execute(
            """
            UPDATE devices
            SET is_active = false,
                updated_at = ?
            WHERE fcm_token = ?
            """,
            [now_iso(), token],
        )


def insert_notification_event(
    *,
    external_user_id: str | None,
    title: str,
    body: str,
    data: dict[str, Any] | None,
    status: str,
    provider_response: dict[str, Any] | None,
) -> str:
    event_id = str(uuid4())
    timestamp = now_iso()

    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO notification_events (
                id,
                external_user_id,
                title,
                body,
                data,
                status,
                provider_response,
                created_at
            )
            VALUES (?, ?, ?, ?, CAST(? AS JSON), ?, CAST(? AS JSON), ?)
            """,
            [
                event_id,
                external_user_id,
                title,
                body,
                json.dumps(data) if data is not None else None,
                status,
                json.dumps(provider_response) if provider_response is not None else None,
                timestamp,
            ],
        )

    return event_id

