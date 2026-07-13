#!/usr/bin/env python3
"""Fetch Claude + GPT(codex/ChatGPT) usage. Emits one JSON line on stdout.

Claude  : GET https://api.anthropic.com/api/oauth/usage  (OAuth token from macOS keychain) — free.
GPT     : POST codex/responses, read x-codex-* rate-limit headers — costs a tiny request,
          so it is cached to gpt_cache.json and only refreshed every GPT_INTERVAL seconds.
Codex token auto-refreshes via the OpenAI OAuth endpoint when close to expiry.
All errors are logged to fetch.log; stdout always stays valid JSON so the UI never breaks.
"""
import json, os, sys, time, base64, subprocess, urllib.request, urllib.error

HOME = os.path.expanduser("~")
DIR = os.path.join(HOME, "usage-bar")
AUTH = os.path.join(HOME, ".codex", "auth.json")
GPT_CACHE = os.path.join(DIR, "gpt_cache.json")
CLAUDE_CACHE = os.path.join(DIR, "claude_cache.json")
LOG = os.path.join(DIR, "fetch.log")
GPT_INTERVAL = 300          # seconds between real GPT requests (usage-saving)
CLAUDE_INTERVAL = 90        # 무료 GET이지만 429(rate-limit) 방지 — 폴 25s여도 실호출은 90s마다(검증된 안전레이트)
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
CONFIG_TOML = os.path.join(HOME, ".codex", "config.toml")

def codex_model():
    """Read the active codex model from config.toml; fall back to a sane default."""
    try:
        for line in open(CONFIG_TOML):
            line = line.strip()
            if line.startswith("model") and "=" in line and not line.startswith("model_"):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return "gpt-5.6-sol"

def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
        # trim log if big
        if os.path.getsize(LOG) > 200_000:
            data = open(LOG).readlines()[-500:]
            open(LOG, "w").writelines(data)
    except Exception:
        pass

# ---------------- Claude ----------------
def _load_cache():
    try:
        return json.load(open(CLAUDE_CACHE))
    except Exception:
        return {}

def claude_usage():
    """Throttled to CLAUDE_INTERVAL regardless of success/failure so a burst of
    polls (or app restarts) never hammers the /usage endpoint into a 429 storm.
    On any error, serves the last known-good snapshot with stale=True."""
    now = time.time()
    cache = _load_cache()
    # 최근에 이미 시도했으면(성공이든 실패든) API 안 두드리고 캐시로 응답
    if now - cache.get("_last_attempt", 0) < CLAUDE_INTERVAL:
        if cache.get("last_good"):
            g = dict(cache["last_good"])
            if not cache.get("ok"):
                g["stale"] = True
            return g
        return {"ok": False, "err": cache.get("err", "api")}
    # 이제 실제 호출
    out = _claude_usage_live()
    entry = {"_last_attempt": now, "ok": bool(out.get("ok"))}
    if out.get("ok"):
        entry["last_good"] = out
    else:
        entry["err"] = out.get("err", "api")
        if cache.get("last_good"):
            entry["last_good"] = cache["last_good"]   # 마지막 정상값 보존
    try:
        json.dump(entry, open(CLAUDE_CACHE, "w"))
    except Exception:
        pass
    if out.get("ok"):
        return out
    if entry.get("last_good"):
        g = dict(entry["last_good"]); g["stale"] = True
        return g
    return out

def _claude_usage_live():
    try:
        raw = subprocess.check_output(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            stderr=subprocess.DEVNULL, timeout=10).decode()
        oauth = json.loads(raw)["claudeAiOauth"]
        token = oauth["accessToken"]
        sub = oauth.get("subscriptionType", "")
    except Exception as e:
        log(f"claude keychain err: {e}")
        return {"ok": False, "err": "no-keychain"}
    try:
        req = urllib.request.Request(
            "https://api.anthropic.com/api/oauth/usage",
            headers={"Authorization": f"Bearer {token}",
                     "anthropic-beta": "oauth-2025-04-20"})
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read().decode())
        session = weekly = fable = None
        for lim in d.get("limits", []):
            if lim.get("kind") == "session":
                session = lim.get("percent")
            elif lim.get("kind") == "weekly_all":
                weekly = {"pct": lim.get("percent"), "resets_at": lim.get("resets_at")}
            elif lim.get("kind") == "weekly_scoped":
                fable = {"pct": lim.get("percent"),
                         "name": (lim.get("scope") or {}).get("model", {}).get("display_name", "scoped"),
                         "resets_at": lim.get("resets_at")}
        if session is None:
            session = d.get("five_hour", {}).get("utilization")
        return {"ok": True, "plan": sub, "session": session, "weekly": weekly, "fable": fable}
    except Exception as e:
        log(f"claude api err: {e}")
        return {"ok": False, "err": "api"}

# ---------------- GPT (codex/ChatGPT) ----------------
def _jwt_exp(tok):
    try:
        p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p)).get("exp", 0)
    except Exception:
        return 0

def _account_id(idt):
    try:
        p = idt.split(".")[1]; p += "=" * (-len(p) % 4)
        pl = json.loads(base64.urlsafe_b64decode(p))
        return pl.get("https://api.openai.com/auth", {}).get("chatgpt_account_id"), \
               pl.get("https://api.openai.com/auth", {}).get("chatgpt_plan_type", "")
    except Exception:
        return None, ""

def _refresh_codex(auth):
    rt = auth["tokens"]["refresh_token"]
    body = json.dumps({"client_id": CLIENT_ID, "grant_type": "refresh_token",
                       "refresh_token": rt,
                       "scope": "openid profile email offline_access"}).encode()
    req = urllib.request.Request("https://auth.openai.com/oauth/token", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.loads(r.read().decode())
    auth["tokens"]["access_token"] = d["access_token"]
    auth["tokens"]["id_token"] = d.get("id_token", auth["tokens"]["id_token"])
    if d.get("refresh_token"):
        auth["tokens"]["refresh_token"] = d["refresh_token"]
    auth["last_refresh"] = time.strftime("%Y-%m-%dT%H:%M:%SZ")
    tmp = AUTH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(auth, f, indent=2)
    os.replace(tmp, AUTH)
    log("codex token refreshed")
    return auth

def gpt_usage_live():
    auth = json.load(open(AUTH))
    at = auth["tokens"]["access_token"]
    if _jwt_exp(at) - time.time() < 120:          # refresh if <2 min left
        auth = _refresh_codex(auth)
        at = auth["tokens"]["access_token"]
    acc, plan = _account_id(auth["tokens"]["id_token"])
    acc = acc or auth["tokens"].get("account_id")
    body = json.dumps({
        "model": codex_model(), "instructions": "x",
        "input": [{"type": "message", "role": "user",
                   "content": [{"type": "input_text", "text": "hi"}]}],
        "stream": True, "store": False}).encode()
    req = urllib.request.Request(
        "https://chatgpt.com/backend-api/codex/responses", data=body,
        headers={"Authorization": f"Bearer {at}", "chatgpt-account-id": acc,
                 "OpenAI-Beta": "responses=experimental", "originator": "codex_cli_rs",
                 "User-Agent": "codex_cli_rs/0.0.0", "Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=25)
    h = r.headers
    def num(k):
        v = h.get(k)
        try: return float(v)
        except Exception: return None
    # codex flips which bucket is "primary" vs "secondary", so classify each by its
    # window length instead of trusting the name: ~300min => 5h, ~10080min => weekly.
    raw = []
    for pre in ("primary", "secondary"):
        wm = num(f"x-codex-{pre}-window-minutes")
        pct = num(f"x-codex-{pre}-used-percent")
        if wm and wm > 0 and pct is not None:
            raw.append({"pct": pct, "reset_at": num(f"x-codex-{pre}-reset-at"),
                        "window_min": wm})
    five = min((b for b in raw if b["window_min"] <= 600), key=lambda b: b["window_min"], default=None)
    week = max((b for b in raw if b["window_min"] > 600), key=lambda b: b["window_min"], default=None)
    out = {
        "ok": True,
        "plan": h.get("x-codex-plan-type", plan),
        "fivehour": five,        # {pct,reset_at,window_min} or None
        "weekly": week,          # {pct,reset_at,window_min} or None
    }
    r.close()                                     # abort stream early = minimal generation
    return out

def gpt_usage():
    # serve from cache unless stale
    try:
        if os.path.exists(GPT_CACHE):
            c = json.load(open(GPT_CACHE))
            if time.time() - c.get("_ts", 0) < GPT_INTERVAL and c.get("ok"):
                return c
    except Exception:
        pass
    try:
        out = gpt_usage_live()
        out["_ts"] = time.time()
        json.dump(out, open(GPT_CACHE, "w"))
        return out
    except Exception as e:
        log(f"gpt err: {e}")
        try:                                       # fall back to last good cache
            c = json.load(open(GPT_CACHE))
            c["stale"] = True
            return c
        except Exception:
            return {"ok": False, "err": str(e)[:60]}

if __name__ == "__main__":
    if "--gpt-force" in sys.argv:                  # manual refresh ignores cache
        for cf in (GPT_CACHE, CLAUDE_CACHE):
            try: os.remove(cf)
            except Exception: pass
    result = {"claude": claude_usage(), "gpt": gpt_usage(), "ts": time.time()}
    print(json.dumps(result, ensure_ascii=False))
