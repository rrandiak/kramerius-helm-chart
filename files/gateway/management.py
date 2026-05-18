"""
Gateway management — Bottle (vendored) + Redis.
Slack / JSON API: protected by MANAGEMENT_API_SECRET.
"""

from __future__ import annotations

import dataclasses
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import redis as redis_lib
from bottle import Bottle, SimpleTemplate, abort, redirect, request, response

logger = logging.getLogger(__name__)

# ── Paths & config ───────────────────────────────────────────────────────────

_ENDPOINTS_PATH = Path("/app/endpoints.txt")
_WATER_CSS = Path("/app/water.css").read_text(encoding="utf-8")
_dash_css_path = Path("/app/dashboard.css")
_DASHBOARD_CSS = (
    _dash_css_path.read_text(encoding="utf-8")
    if _dash_css_path.is_file()
    else ""
)

# Management UI is served from the root path.
# Slack slash-command endpoint is fixed at /slack/commands.

_ENDPOINT_PATHS: frozenset[str] = frozenset()
_ENDPOINT_GROUPED: list[tuple[str, list[str]]] = []

_SLACK_ALLOWED_TEAMS: frozenset[str] = frozenset(
    t.strip() for t in os.getenv("SLACK_ALLOWED_TEAMS", "").split(",") if t.strip()
)
_SLACK_ALLOWED_USERS: frozenset[str] = frozenset(
    u.strip() for u in os.getenv("SLACK_ALLOWED_USERS", "").split(",") if u.strip()
)


def _load_endpoints() -> None:
    global _ENDPOINT_PATHS, _ENDPOINT_GROUPED
    if not _ENDPOINTS_PATH.exists():
        logger.warning("Endpoints catalog missing at %s", _ENDPOINTS_PATH)
        return
    section, buckets = "General", {}
    for raw in _ENDPOINTS_PATH.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            section = line.lstrip("#").strip() or "General"
        elif line.startswith("/"):
            buckets.setdefault(section, []).append(line)
    _ENDPOINT_GROUPED = list(buckets.items())
    _ENDPOINT_PATHS = frozenset(p for _, ps in _ENDPOINT_GROUPED for p in ps)


_load_endpoints()


# ── Models ───────────────────────────────────────────────────────────────────


@dataclasses.dataclass
class PeakSchedule:
    from_hour: int = 9
    to_hour: int = 17

    def to_dict(self) -> dict:
        return {"from": self.from_hour, "to": self.to_hour}

    @staticmethod
    def from_dict(d: dict) -> "PeakSchedule":
        return PeakSchedule(
            from_hour=int(d.get("from", d.get("from_hour", 9))),
            to_hour=int(d.get("to", d.get("to_hour", 17))),
        )


@dataclasses.dataclass
class User:
    name: str
    ip: Optional[str] = None
    username: Optional[str] = None
    headers: dict[str, str] = dataclasses.field(default_factory=dict)

    def to_dict(self) -> dict:
        return dataclasses.asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "User":
        return User(
            name=d["name"],
            ip=d.get("ip"),
            username=d.get("username"),
            headers=d.get("headers", {}),
        )


@dataclasses.dataclass
class Rule:
    name: str
    endpoints: list[str] = dataclasses.field(default_factory=list)
    user_refs: list[str] = dataclasses.field(default_factory=list)
    rl_window: int = 60
    rl_peak: int = 100
    rl_off: int = 100
    dl_window: int = 3600
    dl_peak: int = 1 << 30  # 1 GiB
    dl_off: int = 1 << 30

    def to_dict(self) -> dict:
        return dataclasses.asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "Rule":
        return Rule(
            name=d["name"],
            endpoints=d.get("endpoints", []),
            user_refs=d.get("user_refs", []),
            rl_window=int(d.get("rl_window", 60)),
            rl_peak=int(d.get("rl_peak", 100)),
            rl_off=int(d.get("rl_off", 100)),
            dl_window=int(d.get("dl_window", 3600)),
            dl_peak=int(d.get("dl_peak", 1 << 30)),
            dl_off=int(d.get("dl_off", 1 << 30)),
        )


@dataclasses.dataclass
class Ban:
    target: str
    reason: str
    banned_at: str = dataclasses.field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )

    def to_dict(self) -> dict:
        return dataclasses.asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "Ban":
        return Ban(
            target=d["target"],
            reason=d["reason"],
            banned_at=d.get(
                "banned_at", datetime.now(timezone.utc).isoformat()
            ),
        )


@dataclasses.dataclass
class RemovedBan:
    """
    Soft-deleted ban — stored in Redis under ban-removed:<cidr>."""

    target: str
    reason: str
    banned_at: str
    removed_at: str


@dataclasses.dataclass
class State:
    peak: PeakSchedule = dataclasses.field(default_factory=PeakSchedule)
    rules: list[Rule] = dataclasses.field(default_factory=list)
    users: list[User] = dataclasses.field(default_factory=list)
    bans: list[Ban] = dataclasses.field(default_factory=list)
    removed_bans: list[RemovedBan] = dataclasses.field(default_factory=list)

    def to_dict(self) -> dict:
        # removed_bans are audit-only; excluded from the JSON API.
        return {
            "peak": self.peak.to_dict(),
            "rules": [r.to_dict() for r in self.rules],
            "users": [u.to_dict() for u in self.users],
            "bans": [b.to_dict() for b in self.bans],
        }

    @staticmethod
    def from_dict(d: dict) -> "State":
        if not isinstance(d, dict):
            return State()
        if "user_profiles" in d and "users" not in d:
            d["users"] = d.pop("user_profiles")
        if "peak_schedule" in d and "peak" not in d:
            d["peak"] = d.pop("peak_schedule")
        try:
            return State(
                peak=PeakSchedule.from_dict(d.get("peak", {})),
                rules=[Rule.from_dict(r) for r in d.get("rules", [])],
                users=[User.from_dict(u) for u in d.get("users", [])],
                bans=[Ban.from_dict(b) for b in d.get("bans", [])],
            )
        except Exception as e:
            logger.warning("Invalid state (%s) — starting empty", e)
            return State()


# ── Helpers ──────────────────────────────────────────────────────────────────


def _cidr(v: str) -> str:
    try:
        return str(ipaddress.ip_network(v.strip(), strict=False))
    except ValueError:
        raise ValueError(f"Invalid IP/CIDR: {v!r}") from None


def _parse_headers(raw: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        k, v = k.strip(), v.strip()
        if k:
            out[k] = v
    return out


def _headers_text(headers: dict[str, str]) -> str:
    return "\n".join(f"{k}: {v}" for k, v in headers.items())


def _fmt_bytes(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n //= 1024
    return f"{n:.1f} TiB"


def _next_name(items: list, prefix: str) -> str:
    pat = re.compile(rf"{re.escape(prefix)}-(\d+)")
    ns = [int(m.group(1)) for x in items if (m := pat.fullmatch(x.name))]
    return f"{prefix}-{(max(ns) if ns else 0) + 1}"


def _get_idx(forms, tab: str, count: int) -> int:
    """Parse and validate 'index' from a form; redirects on invalid value."""
    try:
        idx = int(forms.get("index") or "")
    except ValueError:
        _home(tab, error="Invalid index.")
    if not (0 <= idx < count):
        _home(tab, error="Invalid index.")
    return idx


# ── Redis ─────────────────────────────────────────────────────────────────────
#
# Keys:
#   gw:state        → State.to_dict() JSON (peak, rules, users, active bans)
#   gw:version      → integer, incremented on every save_state() call
#   gw:removed_bans → JSON list of RemovedBan records (audit only)
#
# Written as a pipeline (SET + INCR + SET) on every save_state() call.


def _redis() -> redis_lib.Redis:
    return redis_lib.Redis(
        host=os.getenv("REDIS_HOST", "localhost"),
        port=int(os.getenv("REDIS_PORT", 6379)),
        password=os.getenv("REDIS_PASSWORD") or None,
        decode_responses=True,
    )


def load_state() -> State:
    try:
        r = _redis()
        raw = r.get("gw:state")
        rb = r.get("gw:removed_bans")
        r.close()
        st = State.from_dict(json.loads(raw)) if raw else State()
        if rb:
            st.removed_bans = [RemovedBan(**x) for x in json.loads(rb)]
        return st
    except Exception as e:
        logger.warning("Redis read: %s", e)
        return State()


def save_state(st: State) -> None:
    r = _redis()
    pipe = r.pipeline()
    pipe.set("gw:state", json.dumps(st.to_dict()))
    pipe.incr("gw:version")
    rb = [dataclasses.asdict(b) for b in st.removed_bans]
    pipe.set("gw:removed_bans", json.dumps(rb))
    pipe.execute()
    r.close()


# ── Authentication model ─────────────────────────────────────────────────────
#
# Internal auth is intentionally disabled here. Access control is expected
# to be enforced by upstream oauth2-proxy / ingress policy.


# ── Bottle app ───────────────────────────────────────────────────────────────

app = Bottle()


def _render(**ctx) -> str:
    return SimpleTemplate(
        Path("/app/dashboard.html").read_text(encoding="utf-8")
    ).render(**ctx)


def _ctx() -> dict:
    st = load_state()
    tab = request.query.get("tab", "rules")
    open_index = int(request.query.get("open", "-1") or -1)
    show_new_rule = request.query.get("new") == "1"
    return dict(
        state=st,
        water_css=_WATER_CSS,
        dashboard_css=_DASHBOARD_CSS,
        endpoint_grouped=_ENDPOINT_GROUPED,
        headers_text=_headers_text,
        fmt_bytes=_fmt_bytes,
        active_tab=tab,
        flash_error=request.query.get("error", ""),
        flash_ok=request.query.get("ok", ""),
        open_index=open_index,
        show_new_rule=show_new_rule,
        # Empty root avoids generating scheme-relative URLs like //ui/...
        # when templates concatenate "{{browser_root}}/ui/...".
        browser_root="",
    )


def _home(
    tab: str = "rules",
    error: str = "",
    ok: str = "",
    open_index: Optional[int] = None,
) -> None:
    q = f"?tab={tab}"
    if open_index is not None and open_index >= 0:
        q += f"&open={open_index}"
    if error:
        q += "&error=" + urllib.parse.quote(error[:800])
    if ok:
        q += "&ok=" + urllib.parse.quote(ok[:200])
    redirect(f"/{q}")


# ── Dashboard ────────────────────────────────────────────────────────────────


@app.get("/")
def dashboard():
    return _render(**_ctx())


# ── Peak ─────────────────────────────────────────────────────────────────────


@app.post("/ui/peak/save")
def ui_peak_save():
    f = request.forms
    try:
        ps = PeakSchedule(
            from_hour=max(0, min(23, int(f.get("peak_from") or 9))),
            to_hour=max(0, min(23, int(f.get("peak_to") or 17))),
        )
        if ps.from_hour == ps.to_hour:
            raise ValueError("Peak 'from' and 'to' hours must differ.")
    except ValueError as e:
        return _home("rules", error=str(e))
    st = load_state()
    st.peak = ps
    save_state(st)
    return _home("rules", ok="Peak schedule saved.")


# ── Users ────────────────────────────────────────────────────────────────────


@app.post("/ui/user/add")
def ui_user_add():
    st = load_state()
    st.users.append(User(name=_next_name(st.users, "user"), ip="127.0.0.1/32"))
    save_state(st)
    return _home("users", ok="Profile added.", open_index=len(st.users) - 1)


@app.post("/ui/user/save")
def ui_user_save():
    f = request.forms
    st = load_state()
    idx = _get_idx(f, "users", len(st.users))
    try:
        ip = (f.get("profile_ip") or "").strip()
        u = User(
            name=(f.get("profile_name") or "").strip(),
            ip=_cidr(ip) if ip else None,
            username=(f.get("profile_username") or "").strip() or None,
            headers=_parse_headers(f.get("headers") or ""),
        )
        if not u.name:
            raise ValueError("Name is required.")
        if not (u.ip or u.username or u.headers):
            raise ValueError(
                "Set at least one of: IP/CIDR, username, or an HTTP header."
            )
    except ValueError as e:
        return _home("users", error=str(e))
    old_name = st.users[idx].name
    if u.name != old_name:
        if any(x.name == u.name for i, x in enumerate(st.users) if i != idx):
            return _home("users", error=f"Name {u.name!r} already in use.")
        for r in st.rules:
            r.user_refs = [
                u.name if ref == old_name else ref for ref in r.user_refs
            ]
    st.users[idx] = u
    save_state(st)
    return _home("users", ok="Profile saved.")


@app.post("/ui/user/remove")
def ui_user_remove():
    st = load_state()
    idx = _get_idx(request.forms, "users", len(st.users))
    removed = st.users.pop(idx).name
    for r in st.rules:
        r.user_refs = [x for x in r.user_refs if x != removed]
    save_state(st)
    return _home("users")


# ── Rules ────────────────────────────────────────────────────────────────────


@app.post("/ui/rule/add")
def ui_rule_add():
    redirect("/?tab=rules&new=1")


@app.post("/ui/rule/create")
def ui_rule_create():
    f = request.forms
    st = load_state()
    try:
        rule = Rule(
            name=(f.get("rule_name") or "").strip(),
            endpoints=f.getall("endpoints"),
            user_refs=[x for x in f.getall("user_refs") if x.strip()],
            rl_window=int(f.get("rl_window") or 60),
            rl_peak=int(f.get("rl_peak") or 100),
            rl_off=int(f.get("rl_off") or 100),
            dl_window=int(f.get("dl_window") or 3600),
            dl_peak=int(f.get("dl_peak") or 1 << 30),
            dl_off=int(f.get("dl_off") or 1 << 30),
        )
        if not rule.name:
            raise ValueError("Name is required.")
        if any(r.name == rule.name for r in st.rules):
            raise ValueError(f"Name {rule.name!r} already in use.")
        if _ENDPOINT_PATHS:
            bad = [ep for ep in rule.endpoints if ep not in _ENDPOINT_PATHS]
            if bad:
                raise ValueError(f"Unknown endpoints: {bad}")
    except ValueError as e:
        return _home("rules", error=str(e))
    st.rules.append(rule)
    save_state(st)
    return _home("rules", ok="Rule created.")


@app.post("/ui/rule/save")
def ui_rule_save():
    f = request.forms
    st = load_state()
    idx = _get_idx(f, "rules", len(st.rules))
    try:
        rule = Rule(
            name=(f.get("rule_name") or "").strip(),
            endpoints=f.getall("endpoints"),
            user_refs=[x for x in f.getall("user_refs") if x.strip()],
            rl_window=int(f.get("rl_window") or 60),
            rl_peak=int(f.get("rl_peak") or 100),
            rl_off=int(f.get("rl_off") or 100),
            dl_window=int(f.get("dl_window") or 3600),
            dl_peak=int(f.get("dl_peak") or 1 << 30),
            dl_off=int(f.get("dl_off") or 1 << 30),
        )
        if not rule.name:
            raise ValueError("Name is required.")
        if _ENDPOINT_PATHS:
            bad = [ep for ep in rule.endpoints if ep not in _ENDPOINT_PATHS]
            if bad:
                raise ValueError(f"Unknown endpoints: {bad}")
    except ValueError as e:
        return _home("rules", error=str(e))
    st.rules[idx] = rule
    save_state(st)
    return _home("rules", ok="Rule saved.")


@app.post("/ui/rule/remove")
def ui_rule_remove():
    st = load_state()
    idx = _get_idx(request.forms, "rules", len(st.rules))
    st.rules.pop(idx)
    save_state(st)
    return _home("rules")


# ── Bans UI ──────────────────────────────────────────────────────────────────


@app.post("/ui/bans/add")
def ui_bans_add():
    f = request.forms
    try:
        b = Ban(
            target=_cidr(f.get("target") or ""),
            reason=(f.get("reason") or "").strip(),
        )
        if len(b.reason) < 4:
            raise ValueError("Reason must be at least 4 characters.")
    except ValueError as e:
        return _home("bans", error=str(e))
    st = load_state()
    if any(x.target == b.target for x in st.bans):
        return _home("bans", error=f"{b.target} is already banned.")
    st.bans.append(b)
    save_state(st)
    return _home("bans", ok="Ban added.")


@app.post("/ui/bans/delete")
def ui_bans_delete():
    try:
        canon = _cidr(request.forms.get("target") or "")
    except ValueError as e:
        return _home("bans", error=str(e))
    st = load_state()
    st.bans = [b for b in st.bans if b.target != canon]
    save_state(st)
    return _home("bans", ok="Ban removed.")


# ── Slack ────────────────────────────────────────────────────────────────────


def _slack_verify(signing: str, ts: str, body: bytes, sig: str) -> bool:
    if not all([signing, ts, sig]):
        return False
    try:
        if abs(int(time.time()) - int(ts)) > 300:
            return False
    except ValueError:
        return False
    expected = (
        "v0="
        + hmac.new(
            signing.encode(),
            f"v0:{ts}:{body.decode()}".encode(),
            hashlib.sha256,
        ).hexdigest()
    )
    return hmac.compare_digest(expected, sig)


@app.post("/slack/commands")
def slack_commands():
    signing = os.getenv("SLACK_SIGNING_SECRET", "").strip()
    if not signing:
        abort(503, "SLACK_SIGNING_SECRET not set")
    ts = request.headers.get("x-slack-request-timestamp", "")
    try:
        if abs(time.time() - int(ts)) > 60 * 5:
            abort(401, "stale request")
    except ValueError:
        abort(401, "bad timestamp")
    body = request.body.read()
    if not _slack_verify(signing, ts, body, request.headers.get("x-slack-signature", "")):
        abort(401, "invalid signature")

    data = urllib.parse.parse_qs(body.decode())
    if _SLACK_ALLOWED_TEAMS and data.get("team_id", [""])[0] not in _SLACK_ALLOWED_TEAMS:
        abort(403, "team not allowed")

    def ok(msg: str, ephemeral: bool = False) -> dict:
        response.content_type = "application/json"
        return json.dumps(
            {
                "response_type": "ephemeral" if ephemeral else "in_channel",
                "text": msg,
            }
        )

    user_id = data.get("user_id", [""])[0]
    if _SLACK_ALLOWED_USERS and user_id not in _SLACK_ALLOWED_USERS:
        return ok("Unauthorized", ephemeral=True)

    parts = ((data.get("text") or [""])[0].strip()).split(None, 2)
    sub = parts[0].lower() if parts else "help"
    st = load_state()

    if sub in ("", "help"):
        return ok(
            "Commands:\n• `ban <ip> <reason>` • `unban <ip>` • `bans` • "
            "`limits` • `peak`"
        )
    if sub == "bans":
        lines = [f"• `{b.target}` — {b.reason}" for b in st.bans]
        return ok("\n".join(lines) if lines else "No active bans.")
    if sub == "peak":
        return ok(f"Peak {st.peak.from_hour}:00–{st.peak.to_hour}:00")
    if sub == "limits":
        header = f"Peak {st.peak.from_hour}:00–{st.peak.to_hour}:00\n"
        lines = [
            f"• *{r.name}* rl peak={r.rl_peak} off={r.rl_off}/{r.rl_window}s "
            f"dl peak={_fmt_bytes(r.dl_peak)} off={_fmt_bytes(r.dl_off)}/"
            f"{r.dl_window}s"
            for r in st.rules
        ]
        return ok(header + ("\n".join(lines) or "No rules."))
    if sub == "unban" and len(parts) >= 2:
        try:
            target = _cidr(parts[1])
        except ValueError:
            return ok(f"Invalid: `{parts[1]}`", ephemeral=True)
        before = len(st.bans)
        st.bans = [b for b in st.bans if b.target != target]
        if len(st.bans) == before:
            return ok(f"No ban for `{target}`", ephemeral=True)
        save_state(st)
        return ok(f"Unbanned `{target}`")
    if sub == "ban" and len(parts) >= 2:
        reason = parts[2] if len(parts) >= 3 else "banned via Slack"
        try:
            entry = Ban(target=_cidr(parts[1]), reason=reason)
        except ValueError as e:
            return ok(str(e), ephemeral=True)
        if any(b.target == entry.target for b in st.bans):
            return ok(f"`{entry.target}` already banned", ephemeral=True)
        st.bans.append(entry)
        save_state(st)
        return ok(f"Banned `{entry.target}` — {reason}")
    return ok("Unknown command. Try `help`.", ephemeral=True)


# ── Health ───────────────────────────────────────────────────────────────────


@app.get("/healthz")
def healthz():
    response.content_type = "application/json"
    return '{"status":"ok"}'


# ── Run ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    logging.basicConfig(level=logging.INFO)
    app.run(host="0.0.0.0", port=port, server="wsgiref")
