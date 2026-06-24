from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class UpsertUserDeviceRequest(StrictModel):
    external_user_id: str = Field(min_length=1)
    name: str | None = None
    email: str | None = None
    device_uid: str = Field(min_length=1)
    platform: str = Field(min_length=1)
    fcm_token: str = Field(min_length=1)
    app_version: str | None = None


class UpsertUserDeviceResponse(StrictModel):
    ok: bool = True
    user_id: str
    device_id: str
    external_user_id: str
    device_uid: str


class DeviceRecord(StrictModel):
    device_id: str
    device_uid: str
    platform: str
    fcm_token: str
    app_version: str | None = None
    is_active: bool
    updated_at: str


class UserDevicesResponse(StrictModel):
    ok: bool = True
    external_user_id: str
    devices: list[DeviceRecord]


class NotificationPayload(StrictModel):
    title: str = Field(min_length=1)
    body: str = Field(min_length=1)
    data: dict[str, Any] = Field(default_factory=dict)


class WebhookSendNotificationRequest(StrictModel):
    external_user_id: str = Field(min_length=1)
    notification: NotificationPayload


class ScheduledWebhookSendNotificationRequest(WebhookSendNotificationRequest):
    delay_seconds: int = Field(default=10, ge=0, le=300)


class DeviceSendResponse(StrictModel):
    device_uid: str
    platform: str
    success: bool
    message_id: str | None = None
    error: str | None = None
    device_deactivated: bool = False


class WebhookSendNotificationResponse(StrictModel):
    ok: bool = True
    external_user_id: str
    devices_found: int
    sent_count: int
    failed_count: int
    responses: list[DeviceSendResponse]


class ScheduledWebhookSendNotificationResponse(StrictModel):
    ok: bool = True
    external_user_id: str
    scheduled: bool = True
    delay_seconds: int


class ManualSendNotificationRequest(StrictModel):
    external_user_id: str | None = None
    fcm_token: str | None = None
    title: str = Field(min_length=1)
    body: str = Field(min_length=1)
    data: dict[str, Any] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_target(self) -> "ManualSendNotificationRequest":
        has_user = bool(self.external_user_id and self.external_user_id.strip())
        has_token = bool(self.fcm_token and self.fcm_token.strip())
        if has_user == has_token:
            raise ValueError(
                "Provide exactly one target: external_user_id or fcm_token."
            )
        return self


class ManualSendNotificationResponse(StrictModel):
    ok: bool = True
    target_type: str
    target_value: str
    devices_found: int
    sent_count: int
    failed_count: int
    responses: list[DeviceSendResponse]
