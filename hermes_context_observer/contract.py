from __future__ import annotations

from datetime import datetime, timezone
import re
from typing import Any, Mapping

CONTRACT_VERSION = "hermes-context.v1"
SESSION_STATES = frozenset({"working", "needs_attention", "idle"})
TOOL_STATUSES = frozenset({"ok", "error"})
FRESHNESS_STATES = frozenset({"live", "offline"})
CHANNEL_LABEL_MAX = 100  # Discord's own channel-name limit.

_TOP_LEVEL = frozenset({"contract_version", "profile", "generated_at", "freshness", "gateway", "sessions"})
_GATEWAY = frozenset({"heartbeat_at", "offline_after_seconds"})
_SESSION = frozenset({
    "routing_id",
    "profile",
    "platform",
    "session_id",
    "lineage_root_id",
    "previous_session_id",
    "discord_route",
    "display_name",
    "state",
    "model",
    "provider",
    "context",
    "current_tool",
    "timing",
})
_DISCORD_ROUTE = frozenset({"guild_id", "channel_id", "thread_id", "channel_label"})
_CONTEXT = frozenset({"used", "maximum", "percentage", "source", "measured_at"})
_TIMING = frozenset({"turn_started_at", "last_activity_at"})
_EVENT_SHARED = frozenset({
    "contract_version", "kind", "event_id", "sequence", "routing_id", "lineage_root_id",
    "previous_session_id", "session_id", "timestamp", "profile",
})


class ContractError(ValueError):
    """A bridge document is outside the privacy-safe v1 contract."""


def _exact_keys(value: Mapping[str, Any], allowed: frozenset[str], path: str) -> None:
    actual = set(value)
    unknown = actual - allowed
    missing = allowed - actual
    if unknown:
        raise ContractError(f"{path} has unapproved field(s): {', '.join(sorted(unknown))}")
    if missing:
        raise ContractError(f"{path} is missing field(s): {', '.join(sorted(missing))}")


def _nullable_string(value: Any, path: str) -> None:
    if value is not None and not isinstance(value, str):
        raise ContractError(f"{path} must be a string or null")


def _string(value: Any, path: str) -> None:
    if not isinstance(value, str) or not value:
        raise ContractError(f"{path} must be a non-empty string")


def _v1_identity(value: Any, path: str) -> None:
    if not isinstance(value, str) or re.fullmatch(r"hc1:[0-9a-f]{64}", value) is None:
        raise ContractError(f"{path} must be a v1 identity")


def _count(value: Any, path: str, *, nullable: bool = False) -> None:
    if (value is None and nullable) or (type(value) is int and value >= 0):
        return
    raise ContractError(f"{path} must be a non-negative integer{' or null' if nullable else ''}")


def validate_event(event: Mapping[str, Any]) -> None:
    """Only approved request-level and tool-call metadata may cross the durable event boundary."""
    if not isinstance(event, Mapping):
        raise ContractError("event must be an object")
    kind = event.get("kind")
    if not isinstance(kind, str) or kind not in _EVENT_KINDS:
        raise ContractError("event.kind is invalid")
    fields, validate_kind = _EVENT_KINDS[kind]
    _exact_keys(event, _EVENT_SHARED | fields, "event")
    if event["contract_version"] != CONTRACT_VERSION:
        raise ContractError("unsupported event contract_version")
    for field in ("lineage_root_id", "session_id", "timestamp", "profile"):
        _string(event[field], f"event.{field}")
    for field in ("event_id", "routing_id"):
        _v1_identity(event[field], f"event.{field}")
    try:
        moment = datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00"))
        if moment.tzinfo is None:
            raise ValueError("missing timezone")
    except ValueError as error:
        raise ContractError("event.timestamp must be an offset-aware date-time") from error
    if type(event["sequence"]) is not int or event["sequence"] < 1:
        raise ContractError("event.sequence must be a positive integer")
    _nullable_string(event["previous_session_id"], "event.previous_session_id")
    validate_kind(event)


def _validate_model_request(event: Mapping[str, Any]) -> None:
    for field in ("model", "provider"):
        _nullable_string(event[field], f"event.{field}")
    if event["state"] not in SESSION_STATES:
        raise ContractError("event.state is invalid")
    context = event["context"]
    if not isinstance(context, Mapping):
        raise ContractError("event.context must be an object")
    _exact_keys(context, _CONTEXT, "event.context")
    for field in ("used", "maximum"):
        _count(context[field], f"event.context.{field}", nullable=True)
    percentage = context["percentage"]
    if percentage is not None and (type(percentage) not in (int, float) or not 0 <= percentage <= 100):
        raise ContractError("event.context.percentage must be between 0 and 100 or null")
    for field in ("source", "measured_at"):
        _nullable_string(context[field], f"event.context.{field}")


def _validate_tool_call(event: Mapping[str, Any]) -> None:
    """A tool call keeps its name, a loaded skill's name, sizes and outcome; never arguments, results or errors."""
    _string(event["tool_name"], "event.tool_name")
    if event["skill_name"] is not None:
        _string(event["skill_name"], "event.skill_name")
    if event["request_event_id"] is not None:
        _v1_identity(event["request_event_id"], "event.request_event_id")
    for field in ("estimated_tokens", "duration_ms"):
        _count(event[field], f"event.{field}")
    if event["status"] not in TOOL_STATUSES:
        raise ContractError("event.status is invalid")


# `kind` names the record type and picks its fields beyond the shared ones; both kinds share one sequence.
_EVENT_KINDS = {
    "model_request": (frozenset({"model", "provider", "state", "context"}), _validate_model_request),
    "tool_call": (frozenset({"request_event_id", "tool_name", "skill_name", "estimated_tokens", "duration_ms", "status"}),
                  _validate_tool_call),
}


def effective_freshness(snapshot: Mapping[str, Any], *, at: datetime) -> str:
    """Overlay Offline on the last snapshot once the producer's heartbeat stops."""
    validate_snapshot(snapshot)
    heartbeat = datetime.fromisoformat(snapshot["gateway"]["heartbeat_at"].replace("Z", "+00:00"))
    if heartbeat.tzinfo is None:
        raise ContractError("gateway.heartbeat_at must include a timezone")
    age = (at.astimezone(timezone.utc) - heartbeat).total_seconds()
    return "offline" if age > snapshot["gateway"]["offline_after_seconds"] else "live"


def validate_snapshot(snapshot: Mapping[str, Any]) -> None:
    """Reject every field not explicitly approved by the v1 live contract."""
    if not isinstance(snapshot, Mapping):
        raise ContractError("snapshot must be an object")
    _exact_keys(snapshot, _TOP_LEVEL, "snapshot")
    if snapshot["contract_version"] != CONTRACT_VERSION:
        raise ContractError(f"unsupported contract_version: {snapshot['contract_version']!r}")
    _string(snapshot["profile"], "snapshot.profile")
    _string(snapshot["generated_at"], "snapshot.generated_at")
    if snapshot["freshness"] not in FRESHNESS_STATES:
        raise ContractError("snapshot.freshness is invalid")

    gateway = snapshot["gateway"]
    if not isinstance(gateway, Mapping):
        raise ContractError("snapshot.gateway must be an object")
    _exact_keys(gateway, _GATEWAY, "snapshot.gateway")
    _string(gateway["heartbeat_at"], "snapshot.gateway.heartbeat_at")
    if not isinstance(gateway["offline_after_seconds"], int) or gateway["offline_after_seconds"] <= 0:
        raise ContractError("snapshot.gateway.offline_after_seconds must be a positive integer")

    sessions = snapshot["sessions"]
    if not isinstance(sessions, list):
        raise ContractError("snapshot.sessions must be an array")
    seen_routes: set[str] = set()
    for index, session in enumerate(sessions):
        path = f"snapshot.sessions[{index}]"
        if not isinstance(session, Mapping):
            raise ContractError(f"{path} must be an object")
        _exact_keys(session, _SESSION, path)
        for field in ("routing_id", "profile", "platform", "session_id", "lineage_root_id", "display_name"):
            _string(session[field], f"{path}.{field}")
        if session["routing_id"] in seen_routes:
            raise ContractError(f"{path}.routing_id duplicates a live lane")
        seen_routes.add(session["routing_id"])
        _nullable_string(session["previous_session_id"], f"{path}.previous_session_id")
        _nullable_string(session["model"], f"{path}.model")
        _nullable_string(session["provider"], f"{path}.provider")
        _nullable_string(session["current_tool"], f"{path}.current_tool")
        if session["state"] not in SESSION_STATES:
            raise ContractError(f"{path}.state is invalid")

        discord_route = session["discord_route"]
        if not isinstance(discord_route, Mapping):
            raise ContractError(f"{path}.discord_route must be an object")
        _exact_keys(discord_route, _DISCORD_ROUTE, f"{path}.discord_route")
        for field in _DISCORD_ROUTE:
            _nullable_string(discord_route[field], f"{path}.discord_route.{field}")
        label = discord_route["channel_label"]
        if label is not None and not 0 < len(label) <= CHANNEL_LABEL_MAX:
            raise ContractError(f"{path}.discord_route.channel_label must be 1-{CHANNEL_LABEL_MAX} characters")

        context = session["context"]
        if not isinstance(context, Mapping):
            raise ContractError(f"{path}.context must be an object")
        _exact_keys(context, _CONTEXT, f"{path}.context")
        for field in ("used", "maximum"):
            if context[field] is not None and (not isinstance(context[field], int) or context[field] < 0):
                raise ContractError(f"{path}.context.{field} must be a non-negative integer or null")
        percentage = context["percentage"]
        if percentage is not None and (not isinstance(percentage, (int, float)) or not 0 <= percentage <= 100):
            raise ContractError(f"{path}.context.percentage must be between 0 and 100 or null")
        _nullable_string(context["source"], f"{path}.context.source")
        _nullable_string(context["measured_at"], f"{path}.context.measured_at")

        timing = session["timing"]
        if not isinstance(timing, Mapping):
            raise ContractError(f"{path}.timing must be an object")
        _exact_keys(timing, _TIMING, f"{path}.timing")
        for field in _TIMING:
            _nullable_string(timing[field], f"{path}.timing.{field}")
