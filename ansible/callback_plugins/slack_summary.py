"""
Slack summary callback plugin.

Posts a single Slack message at the end of every play with:
  - Per-host counters (ok / changed / failed / unreachable / skipped)
  - List of changed task names (truncated to 20)
  - List of failed task names with error messages (truncated to 5)

Replaces the older slack-summary.yml task file. Lives here because
counters like "changed=N" aren't accessible to regular tasks during a play.

Config resolution order (first non-empty wins):
  1. Environment variable  (ANSIBLE_SLACK_TOKEN / SLACK_SUMMARY_CHANNEL)
  2. .env at repo root     (parsed in-process; same regex as group_vars/all.yml's
                            `dotenv` fact, so secrets reach the plugin regardless
                            of how ansible-playbook was invoked — interactive,
                            launchd, cron, …)

Quiet-on-no-op (avoid drowning the channel under the GitOps loop):
  When HOMELAB_RECONCILE_TRIGGER=scheduled is set in the process env, this
  plugin suppresses the Slack post if the play had no changes and no failures.
  Both LaunchDaemon plists (com.homelab.{ansible-reconcile,git-pull}) set the
  env var; operator shell runs don't, so they always notify. Force a post
  regardless of the gate with HOMELAB_RECONCILE_NOTIFY=always.

Disable by removing/blanking ANSIBLE_SLACK_TOKEN in both env and .env.

Slack API errors (bad token, missing channel, not_in_channel) and network
errors are reported on stderr so launchd's StandardErrorPath captures them;
the play itself is never failed by Slack issues.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

from ansible.plugins.callback import CallbackBase


# Same pattern used by ansible/group_vars/all.yml's `dotenv` fact.
# Supports KEY=value, KEY="value", KEY='value'. Comments and blank lines ignored.
_DOTENV_RE = re.compile(r'^([A-Z_][A-Z0-9_]*)=["\']?([^"\'\n]*)["\']?$')


def _load_dotenv() -> dict[str, str]:
    """Parse <repo>/.env without sourcing it. Best-effort; returns {} on any error."""
    # Plugin lives at <repo>/ansible/callback_plugins/slack_summary.py.
    plugin_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(plugin_dir, "..", ".."))
    env_path = os.path.join(repo_root, ".env")
    out: dict[str, str] = {}
    try:
        with open(env_path, encoding="utf-8") as fh:
            for raw in fh:
                m = _DOTENV_RE.match(raw.strip())
                if m:
                    out[m.group(1)] = m.group(2)
    except OSError:
        pass
    return out


DOCUMENTATION = """
    name: slack_summary
    type: notification
    short_description: Post per-play summary to Slack
    version_added: "2.16"
    description:
      - Runs after every play, posts ok/changed/failed counts plus changed/failed task names.
"""


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "notification"
    CALLBACK_NAME = "slack_summary"
    CALLBACK_NEEDS_ENABLED = True

    MAX_CHANGED = 20
    MAX_FAILED = 5
    TRUNC_MSG = 400

    def __init__(self):
        super().__init__()
        dotenv = _load_dotenv()
        self.token = (
            os.environ.get("ANSIBLE_SLACK_TOKEN", "").strip()
            or dotenv.get("ANSIBLE_SLACK_TOKEN", "").strip()
        )
        self.channel = (
            os.environ.get("SLACK_SUMMARY_CHANNEL", "").strip()
            or dotenv.get("SLACK_SUMMARY_CHANNEL", "").strip()
            or "deploy"
        )
        # Trigger gating — set to "scheduled" by the LaunchDaemon plists so
        # launchd-driven runs that did nothing interesting stay silent. Any
        # other value (incl. unset) is treated as "manual" → always notify.
        # HOMELAB_RECONCILE_NOTIFY=always forces a post regardless (handy
        # for "is the daemon alive?" sanity checks).
        self.trigger = os.environ.get("HOMELAB_RECONCILE_TRIGGER", "manual").strip() or "manual"
        self.notify_mode = os.environ.get("HOMELAB_RECONCILE_NOTIFY", "").strip().lower()
        self._reset()

    def _reset(self):
        self.changed_tasks: list[str] = []
        self.failed_tasks: list[tuple[str, str]] = []
        self.play_name: str | None = None

    # --- Task-level hooks ----------------------------------------------------
    def v2_runner_on_ok(self, result):
        if result.is_changed():
            name = result.task_name or result._task.get_name()
            if name not in self.changed_tasks:
                self.changed_tasks.append(name)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if ignore_errors:
            return
        name = result.task_name or result._task.get_name()
        msg = self._extract_msg(result._result)
        self.failed_tasks.append((name, msg))

    def v2_playbook_on_play_start(self, play):
        self.play_name = play.get_name().strip() or "(unnamed play)"

    # --- Summary -------------------------------------------------------------
    def v2_playbook_on_stats(self, stats):
        if not self.token:
            return

        hosts = sorted(stats.processed.keys())
        if not hosts:
            return

        # Aggregate per-host counters (we only ever have one host: localhost).
        agg = {"ok": 0, "changed": 0, "failures": 0, "unreachable": 0, "skipped": 0}
        for h in hosts:
            s = stats.summarize(h)
            for k in agg:
                agg[k] += s.get(k, 0)

        failed = agg["failures"] + agg["unreachable"] > 0

        # Quiet-on-no-op: scheduled (launchd) runs that produced no changes
        # and no failures get suppressed. Manual operator runs always post
        # (operator wants confirmation). HOMELAB_RECONCILE_NOTIFY=always
        # overrides the gate.
        interesting = failed or agg["changed"] > 0
        if (
            self.trigger == "scheduled"
            and not interesting
            and self.notify_mode != "always"
        ):
            self._reset()
            return

        color = "danger" if failed else "good"
        result_glyph = "✗ FAILED" if failed else "✓ OK"

        text_lines = [
            f"*Reconcile {result_glyph}* — {self.play_name}",
            f"ok={agg['ok']}  changed={agg['changed']}  "
            f"failed={agg['failures']}  unreachable={agg['unreachable']}  "
            f"skipped={agg['skipped']}",
        ]

        if self.changed_tasks:
            shown = self.changed_tasks[: self.MAX_CHANGED]
            extra = len(self.changed_tasks) - len(shown)
            text_lines.append("")
            text_lines.append(f"*Changed ({len(self.changed_tasks)}):*")
            text_lines.extend(f"• {t}" for t in shown)
            if extra > 0:
                text_lines.append(f"…and {extra} more")

        if self.failed_tasks:
            shown = self.failed_tasks[: self.MAX_FAILED]
            extra = len(self.failed_tasks) - len(shown)
            text_lines.append("")
            text_lines.append(f"*Failed ({len(self.failed_tasks)}):*")
            for name, msg in shown:
                truncated = msg if len(msg) <= self.TRUNC_MSG else msg[: self.TRUNC_MSG] + "…"
                text_lines.append(f"• {name}\n```{truncated}```")
            if extra > 0:
                text_lines.append(f"…and {extra} more")

        payload = {
            "channel": self.channel,
            "attachments": [
                {
                    "color": color,
                    "title": "Homelab Reconcile",
                    "text": "\n".join(text_lines),
                    "mrkdwn_in": ["text"],
                }
            ],
        }

        self._post(payload)
        self._reset()

    # --- Helpers -------------------------------------------------------------
    def _extract_msg(self, result_dict) -> str:
        for k in ("msg", "stderr", "stdout"):
            v = result_dict.get(k)
            if v:
                return str(v).strip()
        return "(no message)"

    def _post(self, payload):
        req = urllib.request.Request(
            url="https://slack.com/api/chat.postMessage",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json; charset=utf-8",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read().decode("utf-8", errors="replace")
            data = json.loads(body) if body else {}
            if not data.get("ok"):
                # Slack returns HTTP 200 even on logical errors; surface them
                # to stderr so launchd's StandardErrorPath catches it without
                # failing the play.
                sys.stderr.write(
                    f"[slack_summary] post failed: {data.get('error', 'unknown')} "
                    f"(channel={self.channel})\n"
                )
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            sys.stderr.write(f"[slack_summary] network error: {exc}\n")
