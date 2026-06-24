from __future__ import annotations

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException, status

from .db import (
    deactivate_device_by_token,
    get_active_devices_for_user,
    init_db,
    insert_notification_event,
    upsert_user_device,
)
from .firebase_service import init_firebase, send_push_to_token
from .schemas import (
    DeviceSendResponse,
    ManualSendNotificationRequest,
    ManualSendNotificationResponse,
    ScheduledWebhookSendNotificationRequest,
    ScheduledWebhookSendNotificationResponse,
    UpsertUserDeviceRequest,
    UpsertUserDeviceResponse,
    UserDevicesResponse,
    WebhookSendNotificationRequest,
    WebhookSendNotificationResponse,
)


load_dotenv(Path(__file__).resolve().parents[1] / ".env")
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    init_firebase()
    yield


app = FastAPI(
    title="FCM Push Backend",
    version="1.0.0",
    lifespan=lifespan,
)


def _reload_enabled() -> bool:
    return os.getenv("RELOAD", "true").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def _is_token_invalid(exc: Exception) -> bool:
    message = str(exc).lower()
    invalid_markers = (
        "registration token is not valid",
        "requested entity was not found",
        "registration-token-not-registered",
        "not a valid fcm registration token",
    )
    invalid_exception_names = {
        "UnregisteredError",
        "SenderIdMismatchError",
        "InvalidArgumentError",
    }
    return (
        exc.__class__.__name__ in invalid_exception_names
        or any(marker in message for marker in invalid_markers)
    )


def _validate_webhook_api_key(x_api_key: str | None) -> None:
    expected_api_key = os.getenv("WEBHOOK_API_KEY")
    if expected_api_key and x_api_key != expected_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key.",
        )


def _send_to_token(
    *,
    token: str,
    title: str,
    body: str,
    data: dict[str, object] | None = None,
    device_uid: str = "direct_token",
    platform: str = "unknown",
) -> DeviceSendResponse:
    device_deactivated = False
    try:
        message_id = send_push_to_token(
            token=token,
            title=title,
            body=body,
            data=data,
        )
        return DeviceSendResponse(
            device_uid=device_uid,
            platform=platform,
            success=True,
            message_id=message_id,
        )
    except Exception as exc:
        if _is_token_invalid(exc):
            deactivate_device_by_token(token)
            device_deactivated = True

        return DeviceSendResponse(
            device_uid=device_uid,
            platform=platform,
            success=False,
            error=str(exc),
            device_deactivated=device_deactivated,
        )


def _send_notification_to_active_devices(
    payload: WebhookSendNotificationRequest,
) -> WebhookSendNotificationResponse:
    devices = get_active_devices_for_user(payload.external_user_id)
    responses: list[DeviceSendResponse] = []
    sent_count = 0
    failed_count = 0

    if not devices:
        insert_notification_event(
            external_user_id=payload.external_user_id,
            title=payload.notification.title,
            body=payload.notification.body,
            data=payload.notification.data,
            status="no_devices",
            provider_response={"reason": "No active devices found for user."},
        )
        return WebhookSendNotificationResponse(
            ok=True,
            external_user_id=payload.external_user_id,
            devices_found=0,
            sent_count=0,
            failed_count=0,
            responses=[],
        )

    for device in devices:
        response = _send_to_token(
            token=device["fcm_token"],
            title=payload.notification.title,
            body=payload.notification.body,
            data=payload.notification.data,
            device_uid=device["device_uid"],
            platform=device["platform"],
        )
        if response.success:
            sent_count += 1
            event_status = "sent"
        else:
            failed_count += 1
            event_status = "failed"

        insert_notification_event(
            external_user_id=payload.external_user_id,
            title=payload.notification.title,
            body=payload.notification.body,
            data=payload.notification.data,
            status=event_status,
            provider_response=response.model_dump(),
        )

        responses.append(response)

    return WebhookSendNotificationResponse(
        ok=True,
        external_user_id=payload.external_user_id,
        devices_found=len(devices),
        sent_count=sent_count,
        failed_count=failed_count,
        responses=responses,
    )


async def _send_notification_after_delay(
    payload: ScheduledWebhookSendNotificationRequest,
) -> None:
    await asyncio.sleep(payload.delay_seconds)
    result = _send_notification_to_active_devices(
        WebhookSendNotificationRequest(
            external_user_id=payload.external_user_id,
            notification=payload.notification,
        )
    )
    logger.info(
        "Scheduled notification processed for %s: sent=%s failed=%s",
        payload.external_user_id,
        result.sent_count,
        result.failed_count,
    )


@app.get("/health")
async def health() -> dict[str, bool]:
    return {"ok": True}


@app.post("/users/upsert-device", response_model=UpsertUserDeviceResponse)
async def users_upsert_device(
    payload: UpsertUserDeviceRequest,
) -> UpsertUserDeviceResponse:
    result = upsert_user_device(payload.model_dump())
    return UpsertUserDeviceResponse(ok=True, **result)


@app.get("/users/{external_user_id}/devices", response_model=UserDevicesResponse)
async def list_user_devices(external_user_id: str) -> UserDevicesResponse:
    devices = get_active_devices_for_user(external_user_id)
    return UserDevicesResponse(
        ok=True,
        external_user_id=external_user_id,
        devices=devices,
    )


@app.post(
    "/webhooks/send-notification",
    response_model=WebhookSendNotificationResponse,
)
async def send_notification_webhook(
    payload: WebhookSendNotificationRequest,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> WebhookSendNotificationResponse:
    _validate_webhook_api_key(x_api_key)
    return _send_notification_to_active_devices(payload)


@app.post(
    "/webhooks/send-notification-scheduled",
    response_model=ScheduledWebhookSendNotificationResponse,
)
async def send_notification_webhook_scheduled(
    payload: ScheduledWebhookSendNotificationRequest,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> ScheduledWebhookSendNotificationResponse:
    _validate_webhook_api_key(x_api_key)
    asyncio.create_task(_send_notification_after_delay(payload.model_copy(deep=True)))
    return ScheduledWebhookSendNotificationResponse(
        ok=True,
        external_user_id=payload.external_user_id,
        scheduled=True,
        delay_seconds=payload.delay_seconds,
    )


@app.post(
    "/push/send",
    response_model=ManualSendNotificationResponse,
)
async def send_notification_manual(
    payload: ManualSendNotificationRequest,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> ManualSendNotificationResponse:
    _validate_webhook_api_key(x_api_key)

    if payload.fcm_token:
        response = _send_to_token(
            token=payload.fcm_token,
            title=payload.title,
            body=payload.body,
            data=payload.data,
        )
        return ManualSendNotificationResponse(
            ok=True,
            target_type="fcm_token",
            target_value=payload.fcm_token,
            devices_found=1,
            sent_count=1 if response.success else 0,
            failed_count=0 if response.success else 1,
            responses=[response],
        )

    webhook_payload = WebhookSendNotificationRequest(
        external_user_id=payload.external_user_id or "",
        notification={
            "title": payload.title,
            "body": payload.body,
            "data": payload.data,
        },
    )
    result = _send_notification_to_active_devices(webhook_payload)
    return ManualSendNotificationResponse(
        ok=True,
        target_type="external_user_id",
        target_value=payload.external_user_id or "",
        devices_found=result.devices_found,
        sent_count=result.sent_count,
        failed_count=result.failed_count,
        responses=result.responses,
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "8000")),
        reload=_reload_enabled(),
    )
