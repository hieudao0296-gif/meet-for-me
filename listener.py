#!/usr/bin/env python3
"""
Meet for Me engine (100% local / free).

  Zoom audio -> BlackHole virtual device -> local Whisper (mlx-whisper)
  -> name filter -> LLM (Claude Code CLI on your existing plan, or Ollama)
  -> macOS notification with the question + drafted answer.

Usage:
  python listener.py --list-devices
  python listener.py                      # listen live (device from config.json)
  python listener.py --test-file x.wav    # run the pipeline on an audio file
  python listener.py --test-notify        # check that notifications show up
"""
import argparse
import contextlib
import difflib
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.request
import wave
from collections import deque
from datetime import datetime
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
SR = 16000  # Whisper expects 16 kHz mono float32

# Whisper sometimes "hears" these on near-silence.
HALLUCINATIONS = {
    "", "thank you.", "thanks for watching!", "thank you for watching.",
    "you", ".", "bye.", "thank you so much for watching!",
}
# Phrases Whisper invents on noise/silence (learned from YouTube subtitles). Matched after norm().
HALLUCINATION_PHRASES = [
    "cảm ơn các bạn đã theo dõi", "hẹn gặp lại các bạn", "đăng ký kênh", "subscribe cho kênh",
    "ghiền mì gõ", "like và subscribe", "thanks for watching", "thank you for watching",
    "please subscribe", "subtitles by", "phụ đề",
]


# Single words that are also everyday Vietnamese/English words: unusable as a bare name.
# Compared WITH tone marks, so real names like Minh (vs mình) or Chi (vs chị) stay allowed.
COMMON_WORDS = {
    "anh", "em", "chị", "cô", "chú", "bác", "bạn", "ông", "bà", "thầy", "mình", "tôi", "ok", "test",
}

# ----------------------------------------------------------------- config
def load_config(path: Path) -> dict:
    cfg = {}
    example = HERE / "config.example.json"
    src = path if path.exists() else (example if example.exists() else None)
    if src:  # a fresh clone has only config.example.json; --setup writes config.json
        with open(src, encoding="utf-8") as f:
            cfg = json.load(f)
    cfg["my_names"] = [n for n in cfg.get("my_names", []) if n.strip()]
    cfg.setdefault("audio_device", "BlackHole 2ch")
    # PhoWhisper fine-tuned for Vietnamese with English words mixed in (half the errors of
    # whisper-large-v3-turbo on our tests, far better on English terms).
    cfg.setdefault("whisper_model", "sangdth/phowhisper-large-vien-cs-mlx-8bit")
    cfg.setdefault("language", "vi")
    # Biases Whisper toward the right spelling (with tone marks) of names and jargon.
    cfg.setdefault("whisper_prompt", build_whisper_prompt(cfg.get("name_input") or cfg["my_names"][:2],
                                                          cfg.get("jargon", "")))
    cfg.setdefault("silence_threshold", 0.006)
    cfg.setdefault("llm_backend", "claude")
    cfg.setdefault("claude_model", "sonnet")
    cfg.setdefault("ollama_model", "qwen3:8b")
    cfg.setdefault("context_minutes", 120)  # the whole meeting, so earlier answers are found
    cfg.setdefault("notify_on_mention", True)
    cfg.setdefault("cooldown_seconds", 20)
    cfg.setdefault("notes_file", "context.md")
    cfg.setdefault("silence_warning_seconds", 45)
    cfg.setdefault("question_settle_seconds", 2.5)  # pause that ends a question
    cfg.setdefault("question_wait_seconds", 30)     # how long to wait for the question after the name
    return cfg


def save_config(path: Path, cfg: dict) -> None:
    path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def split_list(s: str) -> list:
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def unaccented(s: str) -> str:
    s = s.replace("đ", "d").replace("Đ", "D")
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")


def build_whisper_prompt(names: list, jargon: str) -> str:
    """A natural sentence (labels like "Thuật ngữ:" get echoed back by Whisper on noise)."""
    p = "Cuộc họp của team"
    if names:
        p += " có " + ", ".join(names)
    p += "."
    if jargon:
        p += " Hôm nay bàn về " + jargon + "."
    return p


def apply_names(cfg: dict, names: list, aliases: list, jargon: str = None) -> dict:
    """names: how people say your name in Vietnamese (with tone marks), e.g. ["Hiếu", "Trung Hiếu"].
    aliases: other names used for you (English name, nickname), matched as typed."""
    result = []
    kept = []
    for n in names:
        if norm(n) in COMMON_WORDS:
            print(f'  ! Skipped "{n}": it is also a common word/pronoun and would trigger on almost '
                  f'every sentence. Use your full given name instead (e.g. "Đức {n}").')
            continue
        kept.append(n)
        for v in (n, unaccented(n)):  # unaccented form only matches English-style transcripts
            if v not in result:
                result.append(v)
    for a in aliases:
        if a not in result:
            result.append(a)
    cfg["my_names"] = result
    cfg["name_input"] = names     # what the user typed, shown back in the app's settings
    cfg["alias_input"] = aliases
    if jargon is None:  # keep the existing jargon
        jargon = cfg.get("jargon")
        if jargon is None:
            m = re.search(r"Thuật ngữ: (.*?)\.?$", cfg.get("whisper_prompt", ""))
            jargon = m.group(1) if m else ""
    cfg["jargon"] = jargon
    cfg["whisper_prompt"] = build_whisper_prompt(kept, jargon)
    return cfg


def run_setup(path: Path, cfg: dict) -> dict:
    print("Name setup (press Enter to keep the current value)\n")
    cur = cfg.get("my_names", [])
    print("Current names:", ", ".join(cur) if cur else "(none)")
    names = split_list(input(
        "1) Your name as colleagues say it, WITH tone marks, comma-separated\n"
        "   e.g.  Hiếu, Trung Hiếu  : "))
    if not names:
        if not cur:
            sys.exit("A name is required.")
        print("Kept the current names.")
        return cfg
    aliases = split_list(input(
        "2) Other names people call you (English name, nickname), optional\n"
        "   e.g.  Hugh, Henry  : "))
    jargon = input("3) Project words Whisper should spell right (optional)\n"
                   "   e.g.  API, deploy, staging, sprint  : ").strip() or None
    apply_names(cfg, names, aliases, jargon)
    if not cfg["my_names"]:
        sys.exit("No usable name left; run --setup again with your full given name.")
    print("\nWill listen for:", ", ".join(cfg["my_names"]))
    print("Whisper hint:   ", cfg["whisper_prompt"])
    if input("Save? [Y/n] ").strip().lower() in ("", "y", "yes"):
        save_config(path, cfg)
        print(f"Saved to {path}")
    return cfg


def norm(s: str) -> str:
    """Lowercase + punctuation removed, but tone marks KEPT: in Vietnamese
    'Hiếu' (a name) and 'hiểu' (to understand) differ only by the tone mark."""
    s = unicodedata.normalize("NFC", s.lower())
    return " ".join(re.sub(r"[^\w ]+", " ", s).split())


def mentions_me(text: str, names: list) -> bool:
    t = " " + norm(text) + " "
    words = t.split()
    for name in names:
        n = norm(name)
        if not n:
            continue
        if " " in n:
            if f" {n} " in t:
                return True
            continue
        for i, w in enumerate(words):
            # Fuzzy only for long ASCII names; short / accented names must match exactly.
            if w == n or (len(n) >= 5 and n.isascii() and w.isascii()
                          and difflib.SequenceMatcher(None, w, n).ratio() >= 0.85):
                return True
            # Vocative "X ơi" is a direct call: accept the name even with a wrong tone mark
            # (speech-to-text often writes "hiểu ơi" for "Hiếu ơi"; nobody says "hiểu ơi").
            if i + 1 < len(words) and words[i + 1] == "ơi" and unaccented(w) == unaccented(n):
                return True
    return False


# ----------------------------------------------------------------- events
EMIT_EVENTS = False  # set by --events; the Mac app reads these lines from stdout


def emit(kind: str, **data) -> None:
    if EMIT_EVENTS:
        data["kind"] = kind
        data["time"] = datetime.now().strftime("%H:%M:%S")
        print("@@EVENT " + json.dumps(data, ensure_ascii=False), flush=True)


# ----------------------------------------------------------- notification
def _osa_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


NOTIFY_ENABLED = True  # off with --quiet (tests)


def notify(title: str, message: str, subtitle: str = "", open_path: Path = None) -> None:
    if not NOTIFY_ENABLED:
        return
    if shutil.which("terminal-notifier"):
        cmd = ["terminal-notifier", "-title", title, "-message", message[:400],
               "-sound", "Glass", "-group", "zoom-listener-" + str(time.time())]
        if subtitle:
            cmd += ["-subtitle", subtitle[:120]]
        if open_path:
            cmd += ["-open", open_path.as_uri()]
        subprocess.run(cmd, check=False)
        return
    script = 'display notification "{}" with title "{}" subtitle "{}" sound name "Glass"'.format(
        _osa_escape(message[:400]), _osa_escape(title), _osa_escape(subtitle[:120]))
    subprocess.run(["osascript", "-e", script], check=False)


# ------------------------------------------------------- transcript quality
def reject_reason(text: str, seg: dict, prompt: str) -> str:
    """Why a Whisper segment looks invented rather than heard ("" = keep it)."""
    if not text or text.lower() in HALLUCINATIONS:
        return "empty"
    t = norm(text)
    if any(p in t for p in HALLUCINATION_PHRASES):
        return "known hallucination"
    if seg.get("avg_logprob", 0) < -1.0:
        return f"low confidence {seg.get('avg_logprob'):.2f}"
    if seg.get("no_speech_prob", 0) > 0.6 and seg.get("avg_logprob", 0) < -0.5:
        return "probably not speech"
    words = t.split()
    if seg.get("compression_ratio", 0) > 2.4 or (len(words) >= 8 and len(set(words)) / len(words) < 0.3):
        return "repetition loop"
    for i in range(len(words) - 2):  # echo of the hint text
        if " ".join(words[i:i + 3]) in norm(prompt) and len(words) <= 12 and \
                len(set(words) - set(norm(prompt).split())) <= 1:
            return "echo of hint"
    if re.search(r"[\u3040-\u30ff\u4e00-\u9fff\uac00-\ud7af]", text):  # Japanese/Chinese/Korean
        return "wrong script"
    return ""


# ------------------------------------------------------------------ LLM
PROMPT = """You are monitoring a live meeting transcript on behalf of {me}.
The meeting is mostly in Vietnamese, often mixed with English technical terms.
The transcript is automatic speech-to-text: it has no speaker labels and may misspell names
or tone marks (possible spellings of {me}'s name: {names}).
Vietnamese notes: people address {me} with a pronoun + name ("anh {me}", "em {me}", "{me} ơi");
a Vietnamese name can look like a common word that differs only by tone mark (e.g. the name
"Hiếu" vs "hiểu" = to understand): only the actual name counts; a question may end with
"không", "chưa", "nhé", "ạ", "nhỉ" or "thế nào" instead of a question mark.
English technical terms are often misheard (e.g. "ATI"/"ây pi ai" for "API"): interpret them
from context.

Today is {today}.

Meeting transcript so far (oldest first):
<transcript>
{transcript}
</transcript>

{notes_block}

The lines around the mention of {me} (">>" marks lines containing the name; the lines before
and after it may hold the actual question):
<trigger>
{trigger}
</trigger>

Step 1. Classify:
  - "question": someone is asking {me} something or requesting something {me} should respond to.
    The name and the question are often on DIFFERENT lines: the name may come first
    ("Anh {me} ơi." then the question on the next line(s)) or after the question
    ("Cái deploy xong chưa nhỉ? {me} nhỉ?"). Combine those lines into one question.
  - "waiting": {me} was called but the actual question has not been said yet
    (e.g. only "Anh {me} ơi", "{me} ơi, cho em hỏi chút"); more speech is probably coming.
  - "not_for_me": {me} is only mentioned, the question is for someone else, or the speaker
    withdrew it ("thôi, để sau").

Step 2. Only for "question": draft a short answer {me} could say out loud (2-4 sentences, first person).
Where the facts come from, in this order:
  1. The meeting transcript: anything already said in this meeting that answers or
     relates to the question (status updates, numbers, dates, decisions, who owns what,
     what {me} said earlier). Prefer the most recent statement if things changed.
  2. {me}'s notes, if provided, for facts the transcript does not cover.
If the transcript says something different from the notes, go with the transcript (it is
newer) and record the conflict in "sources".
The draft is spoken aloud in the meeting, so it must sound natural: never mention "the notes",
"the transcript" or where facts came from inside the draft itself.
Never invent facts. If neither source has the answer, say so honestly in the draft
(e.g. offer to check and follow up) and set confidence to "low".

Language: write "question" and "draft_answer" in the language the question was asked in
(Vietnamese questions get Vietnamese answers). Pick {me}'s self-pronoun from how {me} was
addressed: called "anh" -> {me} says "anh" and calls the asker "em"; called "em" -> {me} says "em";
called "chị" -> "chị"; unclear -> neutral "mình".

"sources": list each fact the answer relies on, as a short quote or paraphrase with its origin,
e.g. "transcript 14:02: QA tìm thấy 2 bug" or "notes: release target Nov 20". Empty list if none.
"confidence": high = the answer is directly supported by the sources; medium = partly
supported; low = not supported.

Reply with ONLY a JSON object, no other text:
{{"status": "question|waiting|not_for_me", "question": "...", "draft_answer": "...", "sources": ["..."], "confidence": "high|medium|low"}}"""

# A line that sounds finished as a question (Vietnamese often has no "?").
QUESTION_END = re.compile(
    r"(\?|\b(không|chưa|nhé|nhỉ|ạ|à|hả|hở|sao|thế nào|ra sao|bao giờ|khi nào|được không|"
    r"đúng không|phải không|gì|ai|đâu|mấy|bao nhiêu))\W*$", re.I)

NOTES_TEMPLATE_MARKER = "Write anything here that helps draft answers for you"


def read_notes(path: Path) -> str:
    """The user's notes, or "" when missing, empty or still the untouched template."""
    if not path.exists():
        return ""
    text = path.read_text(encoding="utf-8").strip()
    if not text or NOTES_TEMPLATE_MARKER in text:
        return ""
    return text


def notes_block(notes: str, me: str) -> str:
    if not notes:
        return f"(No notes from {me} were provided: answer from the transcript only.)"
    return (f"Notes from {me} (secondary source, may be older than the meeting):\n"
            "<notes>\n" + notes + "\n</notes>")


def ask_llm(cfg: dict, prompt: str) -> dict:
    raw = ask_llm_text(cfg, prompt, json_mode=True)
    m = re.search(r"\{.*\}", raw, re.S)
    if not m:
        raise ValueError("LLM did not return JSON: " + raw[:200])
    return json.loads(m.group(0))


def ask_llm_text(cfg: dict, prompt: str, json_mode: bool = False) -> str:
    if cfg["llm_backend"] == "ollama":
        req_body = {"model": cfg["ollama_model"], "prompt": prompt, "stream": False,
                    "think": False, "options": {"num_ctx": 32768}}  # room for a long meeting
        if json_mode:
            req_body["format"] = "json"
        body = json.dumps(req_body).encode()
        req = urllib.request.Request("http://localhost:11434/api/generate", data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = json.loads(r.read())["response"]
    else:
        # Uses your existing Claude Code login. Run in an empty dir so no project files load.
        with tempfile.TemporaryDirectory() as tmp:
            res = subprocess.run(
                ["claude", "-p", "--model", cfg["claude_model"], "--output-format", "text",
                 "--disallowedTools", "Bash,Edit,Write,Read,WebFetch,WebSearch"],
                input=prompt, capture_output=True, text=True, timeout=180, cwd=tmp)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip() or res.stdout.strip())
        raw = res.stdout
    return raw.strip()


# ------------------------------------------------------------------ chat
CHAT_PROMPT = """You are {me}'s assistant for their work meetings. {me} asks you about what
happened in a meeting. Answer from the meeting transcript (main source) and {me}'s notes
(only if provided and relevant).

About the transcript: automatic speech-to-text of what OTHER participants said ({me}'s own
voice is not recorded), mostly Vietnamese mixed with English terms, no speaker labels, and it
may contain recognition errors (misheard names/terms): interpret sensibly and say when
something is unclear. Lines look like "[HH:MM:SS] text"; a line "=== transcript ... ===" starts
a new recording session (the app was restarted).

Rules:
- Only state what the transcript or notes support; if they don't contain the answer, say so.
- Cite the time of the lines you rely on, like (14:37).
- Reply in the language of {me}'s question. Be concise: a few sentences or short bullets,
  plain text, no headings.

Today is {today}.

<transcript>
{transcript}
</transcript>

{notes_block}

Conversation so far:
{history}

{me}: {question}
Assistant:"""


def meeting_text(which: str, max_chars: int = 150_000) -> str:
    """'today' = all of today's transcript files; otherwise one file name in transcripts/."""
    folder = HERE / "transcripts"
    if which in ("", "today"):
        files = sorted(folder.glob(datetime.now().strftime("%Y-%m-%d") + "_*.txt"))
    else:
        files = [folder / Path(which).name]
    parts = []
    for f in files:
        if f.exists():
            body = f.read_text(encoding="utf-8").strip()
            if body:
                parts.append(f"=== transcript {f.stem} ===\n{body}")
    text = "\n\n".join(parts)
    return text[-max_chars:]  # keep the most recent part of a very long day


def chat_answer(cfg: dict, question: str, history: list, which: str = "today") -> str:
    transcript = meeting_text(which)
    if not transcript:
        return ("Chưa có transcript nào cho cuộc họp này. "
                "(No transcript yet for this meeting.)")
    me = cfg["my_names"][0] if cfg["my_names"] else "the user"
    hist = "\n".join(f"{me if h.get('role') == 'user' else 'Assistant'}: {h.get('text', '')}"
                     for h in history[-10:]) or "(none)"
    prompt = CHAT_PROMPT.format(me=me, today=datetime.now().strftime("%A %Y-%m-%d"),
                                transcript=transcript,
                                notes_block=notes_block(read_notes(HERE / cfg["notes_file"]), me),
                                history=hist, question=question)
    return ask_llm_text(cfg, prompt)


# --------------------------------------------------------------- engine
class Listener:
    """Transcript + mention handling.

    When the name is heard, a "pending" check opens. It is sent to the LLM once the speaker
    has paused (or a line ends like a question), with the lines around the name, because the
    name and the question are often on different lines. If the LLM says {me} was only called
    ("waiting"), the check stays open and is re-run when more lines arrive, up to
    question_wait_seconds; if no question ever comes, a "you were called" alert is sent.
    """

    def __init__(self, cfg: dict, save_transcript: bool = True):
        self.cfg = cfg
        self.me = cfg["my_names"][0]
        self.all = []              # every line this meeting: (epoch, text, mentioned)
        stamp = datetime.now().strftime("%Y-%m-%d_%H%M")
        (HERE / "transcripts").mkdir(exist_ok=True)
        (HERE / "answers").mkdir(exist_ok=True)
        # Test runs (--test-file / --test-transcript) must not end up in the real transcripts.
        self.log = (open(HERE / "transcripts" / f"{stamp}.txt", "a", encoding="utf-8")
                    if save_transcript else open(os.devnull, "w"))
        self.pending = None        # dict, see on_text
        self.lock = threading.Lock()
        self.busy = lambda: False  # set by run_live: True while someone is speaking
        self.last_alert = 0.0
        self.workers = []
        self._whisper = None

    # -- transcription
    def transcribe(self, audio: np.ndarray) -> str:
        if self._whisper is None:
            import mlx_whisper
            self._whisper = mlx_whisper

        def run(temperature):
            out = self._whisper.transcribe(
                audio.astype(np.float32),
                path_or_hf_repo=self.cfg["whisper_model"],
                language=self.cfg["language"],
                initial_prompt=self.cfg["whisper_prompt"],
                condition_on_previous_text=False,
                temperature=temperature,
                verbose=None,
            )
            kept, reasons = [], []
            for seg in out.get("segments", []):
                text = seg.get("text", "").strip()
                why = reject_reason(text, seg, self.cfg["whisper_prompt"])
                if why:
                    reasons.append(why)
                    print(f"   (dropped: {why}: {text[:60]!r})", flush=True)
                else:
                    kept.append(text)
            return kept, reasons

        # Decode once (Whisper's default retries up to 5x on unsure audio, which made lines take
        # 10-18 s). Only if the whole line would be thrown away as low-confidence, try once more
        # with some sampling: that usually recovers it, and normal lines stay fast.
        kept, reasons = run((0.0,))
        if not kept and any(r.startswith("low confidence") for r in reasons) and len(audio) > SR:
            print("   (retrying low-confidence line)", flush=True)
            kept, _ = run((0.4,))
        return " ".join(kept).strip()

    # -- per-line handling
    def on_segment(self, audio: np.ndarray) -> None:
        t0 = time.time()
        self.on_text(self.transcribe(audio), t0)

    def on_text(self, text: str, t0: float = None) -> None:
        """Handle one transcribed line (from audio, or from a text file in tests)."""
        t0 = t0 or time.time()
        text = text.strip()
        if text.lower() in HALLUCINATIONS:
            return
        now = time.time()
        mentioned = mentions_me(text, self.cfg["my_names"])
        ts = datetime.now().strftime("%H:%M:%S")
        self.log.write(f"[{ts}] {text}\n")
        self.log.flush()
        print(f"[{ts}] ({time.time() - t0:.1f}s) {text}", flush=True)
        emit("transcript", text=text, mention=mentioned)
        with self.lock:
            self.all.append((now, text, mentioned))
            if self.pending:
                self.pending["last"] = now
            elif mentioned:
                print("   >> mention detected, waiting for the question to finish", flush=True)
                if self.cfg["notify_on_mention"] and now - self.last_alert > self.cfg["cooldown_seconds"]:
                    notify("You were mentioned", text, "Meet for Me")
                self.pending = {
                    "idx": len(self.all) - 1,   # line with the name
                    "start": now,               # when the name was heard
                    "last": now,                # when the latest line arrived
                    "checked": len(self.all) - 1,  # lines already sent to the LLM
                    "inflight": False,
                    "waiting": False,           # LLM said: called, question not asked yet
                }

    def tick(self) -> None:
        """Called about once a second: start a check when the question has had time to finish."""
        with self.lock:
            p = self.pending
            if not p or p["inflight"]:
                return
            now = time.time()
            if now - p["start"] > self.cfg["question_wait_seconds"]:
                self.pending = None
                if p["waiting"]:  # called, but the question never came
                    line = self.all[p["idx"]][1]
                    print("   >> called, no question followed", flush=True)
                    notify("Someone called you", line, "Meet for Me")
                    emit("called", text=line)
                return
            if len(self.all) <= p["checked"]:
                return  # nothing new since the last check
            if self.busy():
                return  # still talking: the question may continue
            last_text = self.all[-1][1]
            if not (QUESTION_END.search(last_text) or now - p["last"] >= self.cfg["question_settle_seconds"]):
                return
            p["inflight"] = True
            p["checked"] = len(self.all)
            trigger = self._trigger_text(p)
            prompt = self._prompt(trigger)
        th = threading.Thread(target=self._analyze, args=(prompt, trigger), daemon=True)
        self.workers.append(th)
        th.start()

    def flush(self) -> None:
        """Tests: treat the speaker as finished now."""
        with self.lock:
            if self.pending:
                self.pending["last"] = 0

    def idle(self) -> bool:
        with self.lock:
            return self.pending is None

    def _trigger_text(self, p: dict) -> str:
        lines = []
        for i in range(max(0, p["idx"] - 2), len(self.all)):
            t, x, m = self.all[i]
            lines.append(f"{'>>' if m else '  '} [{datetime.fromtimestamp(t):%H:%M:%S}] {x}")
        return "\n".join(lines)

    def _prompt(self, trigger: str) -> str:
        cutoff = time.time() - self.cfg["context_minutes"] * 60
        transcript = "\n".join(f"[{datetime.fromtimestamp(t):%H:%M:%S}] {x}"
                               for t, x, _ in self.all if t >= cutoff)
        notes = read_notes(HERE / self.cfg["notes_file"])  # re-read: notes may be edited mid-meeting
        return PROMPT.format(today=datetime.now().strftime("%A %Y-%m-%d"), me=self.me,
                             names=", ".join(self.cfg["my_names"]),
                             notes_block=notes_block(notes, self.me),
                             transcript=transcript, trigger=trigger)

    def _analyze(self, prompt: str, trigger: str) -> None:
        t0 = time.time()
        try:
            r = ask_llm(self.cfg, prompt)
        except Exception as e:  # noqa: BLE001
            print(f"   !! LLM error: {e}", flush=True)
            emit("error", message=f"LLM failed: {e}", trigger=trigger)
            notify("Mentioned (LLM failed)", trigger, "Meet for Me")
            with self.lock:
                self.pending = None
            return
        print(f"   >> LLM ({time.time() - t0:.1f}s): {json.dumps(r, ensure_ascii=False)}", flush=True)
        status = r.get("status") or ("question" if r.get("addressed_to_me") else "not_for_me")
        with self.lock:
            if status == "waiting" and self.pending:
                self.pending["inflight"] = False  # keep listening; re-check on new lines
                self.pending["waiting"] = True
                print("   >> called, waiting for the question", flush=True)
                return
            self.pending = None
        if status != "question":
            emit("ignored", trigger=trigger)
            return
        self.last_alert = time.time()
        q = r.get("question", "").strip() or trigger
        a = r.get("draft_answer", "").strip()
        path = HERE / "answers" / (datetime.now().strftime("%Y-%m-%d_%H%M%S") + ".md")
        sources = [str(x) for x in (r.get("sources") or []) if str(x).strip()]
        src_md = "\n".join(f"- {x}" for x in sources) or "- (none: not covered by transcript or notes)"
        path.write_text(f"# Question\n{q}\n\n# Draft answer\n{a}\n\n# Based on\n{src_md}\n\n"
                        f"# Trigger\n{trigger}\n", encoding="utf-8")
        print(f"   >> ALERT: {q}", flush=True)
        notify(f"Question for you ({r.get('confidence', '?')})", a or q, q, open_path=path)
        emit("answer", question=q, answer=a, confidence=r.get("confidence", ""),
             sources=sources, trigger=trigger, file=str(path))


# ---------------------------------------------------------- audio input
def find_device(name: str) -> int:
    import sounddevice as sd
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0 and name.lower() in d["name"].lower():
            return i
    msg = f"Input device containing '{name}' not found. Is BlackHole installed?"
    emit("error", message=msg)
    sys.exit(msg)


def resample(x: np.ndarray, sr_in: int) -> np.ndarray:
    if sr_in == SR:
        return x
    n = int(len(x) * SR / sr_in)
    return np.interp(np.linspace(0, len(x), n, endpoint=False), np.arange(len(x)), x)


def single_instance_lock():
    """Only one listener at a time, or every question is answered twice."""
    import fcntl
    import os
    f = open(HERE / ".listener.lock", "a+")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.seek(0)
        other = f.read().strip() or "?"
        msg = f"Another listener is already running (process {other}). Stop it first."
        emit("error", message=msg)
        sys.exit(msg)
    f.seek(0)
    f.truncate()
    f.write(str(os.getpid()))
    f.flush()
    return f  # keep the file object alive to hold the lock


def run_live(cfg: dict, audio_stdin: bool = False) -> None:
    """audio_stdin: the Mac app captures the meeting apps' audio itself (Core Audio process
    taps) and pipes it here as raw float32 mono 16 kHz on stdin. Otherwise read a device
    (BlackHole) with sounddevice."""
    _lock = single_instance_lock()  # noqa: F841
    if audio_stdin:
        sd = None
        info = {"name": "meeting apps", "max_input_channels": 1}
        sr_in = SR
    else:
        import sounddevice as sd
        dev = find_device(cfg["audio_device"])
        info = sd.query_devices(dev)
        sr_in = int(info["default_samplerate"])
    print(f"Listening on '{info['name']}' @ {sr_in} Hz. Names: {cfg['my_names']}. Ctrl+C to stop.")

    blocks: "queue.Queue[np.ndarray]" = queue.Queue()
    segments: "queue.Queue[np.ndarray]" = queue.Queue()
    state = {"speaking": False}

    def cb(indata, frames, t, status):  # audio thread: keep it tiny
        blocks.put(indata.mean(axis=1).copy())

    def segmenter():
        """Cut the stream into utterances on ~0.7 s of silence (max 20 s)."""
        thr = cfg["silence_threshold"]
        pre = deque(maxlen=6)  # ~0.6 s pre-roll: without it the first syllable (often a name) gets clipped
        cur, silent, speaking, loud_time = [], 0.0, False, 0.0
        last_sound, warned = time.time(), False
        while True:
            b = resample(blocks.get(), sr_in)
            dur = len(b) / SR
            loud = float(np.sqrt(np.mean(b ** 2))) > thr
            # Warn when nothing has been heard for a while: usually the meeting audio
            # isn't routed to BlackHole (wrong output device).
            if loud:
                last_sound = time.time()
                if warned:
                    warned = False
                    print("Audio is coming in again.", flush=True)
                    emit("audio", ok=True)
            elif not warned and time.time() - last_sound > cfg["silence_warning_seconds"]:
                warned = True
                secs = int(time.time() - last_sound)
                print(f"!! No audio for {secs}s (meeting not started, muted, or not routed).",
                      flush=True)
                emit("audio", ok=False, silent_for=secs)
                notify("No meeting audio", "Set Sound output (or Zoom's speaker) to "
                       "Multi-Output Device so the listener can hear the meeting.", "Meet for Me")
            state["speaking"] = speaking and loud_time >= 0.3
            if not speaking:
                pre.append(b)
                if loud:
                    speaking, cur, silent, loud_time = True, list(pre), 0.0, 0.0
                continue
            cur.append(b)
            silent = 0.0 if loud else silent + dur
            loud_time += dur if loud else 0.0
            length = sum(len(x) for x in cur) / SR
            if silent >= 0.7 or length >= 20:
                if loud_time >= 0.5:  # ignore clicks, coughs, keyboard
                    segments.put(np.concatenate(cur))
                speaking, cur = False, []
                pre.clear()

    threading.Thread(target=segmenter, daemon=True).start()
    lst = Listener(cfg)
    lst.busy = lambda: state["speaking"] or not segments.empty()
    print("Loading Whisper model...", flush=True)
    emit("status", state="loading", device=info["name"])
    lst.transcribe(np.zeros(SR, dtype=np.float32))  # warm-up so the first real line is fast
    print("Ready.", flush=True)
    emit("status", state="listening", device=info["name"], names=cfg["my_names"])
    if audio_stdin:
        def stdin_reader():
            chunk = int(SR * 0.1) * 4  # 0.1 s of float32
            src = sys.stdin.buffer
            while True:
                data = src.read(chunk)
                if not data:
                    print("Audio stream from the app ended.", flush=True)
                    return
                usable = len(data) - len(data) % 4
                blocks.put(np.frombuffer(data[:usable], dtype=np.float32).copy())
        threading.Thread(target=stdin_reader, daemon=True).start()
        stream = contextlib.nullcontext()
    else:
        stream = sd.InputStream(device=dev, channels=min(2, info["max_input_channels"]),
                                samplerate=sr_in, blocksize=int(sr_in * 0.1), callback=cb)
    with stream:
        while True:
            try:
                seg = segments.get(timeout=1)
                lst.on_segment(seg)
            except queue.Empty:
                pass
            lst.tick()


def read_wav(path: Path) -> np.ndarray:
    tmp = Path(tempfile.mkdtemp()) / "a.wav"
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SR}", "-c", "1", str(path), str(tmp)],
                   check=True)
    with wave.open(str(tmp)) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def run_file(cfg: dict, path: Path) -> None:
    lst = Listener(cfg, save_transcript=False)
    lst.on_segment(read_wav(path))
    finish(lst)


def run_transcript(cfg: dict, path: Path) -> None:
    """Feed a text file as if each line had just been transcribed (tests the LLM part).
    Lines may start with "[HH:MM:SS]"; blank lines and lines starting with # are skipped.
    "@wait N" pauses N seconds (silence) with the normal timing rules running."""
    lst = Listener(cfg, save_transcript=False)
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = re.sub(r"^\[[0-9:]+\]\s*", "", raw).strip()
        m = re.match(r"@wait\s+([0-9.]+)", line)
        if m:
            end = time.time() + float(m.group(1))
            while time.time() < end:
                lst.tick()
                time.sleep(0.2)
        elif line and not line.startswith("#"):
            lst.on_text(line)
            lst.tick()
    finish(lst)


def finish(lst: "Listener") -> None:
    """End of a test input: let pending checks run to completion (incl. 'waiting' timeouts)."""
    lst.flush()
    deadline = time.time() + lst.cfg["question_wait_seconds"] + 200
    while not lst.idle() and time.time() < deadline:
        lst.tick()
        time.sleep(0.2)
    for t in lst.workers:
        t.join()


class Tee:
    def __init__(self, *streams):
        self.streams = streams

    def write(self, data):
        for st in self.streams:
            st.write(data)
            st.flush()

    def flush(self):
        for st in self.streams:
            st.flush()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(HERE / "config.json"))
    ap.add_argument("--list-devices", action="store_true")
    ap.add_argument("--test-file")
    ap.add_argument("--test-notify", action="store_true")
    ap.add_argument("--test-transcript", metavar="TXT", help="feed a text transcript (no audio)")
    ap.add_argument("--quiet", action="store_true", help="no macOS notifications")
    ap.add_argument("--setup", action="store_true", help="interactively set your name")
    ap.add_argument("--set-name", metavar="NAMES",
                    help='your name(s) with tone marks, comma-separated, e.g. "Hiếu, Trung Hiếu"')
    ap.add_argument("--aliases", metavar="NAMES", default="",
                    help='other names, comma-separated, e.g. "Hugh" (used with --set-name)')
    ap.add_argument("--jargon", metavar="WORDS", default=None,
                    help='project words for Whisper, e.g. "API, deploy" (used with --set-name)')
    ap.add_argument("--show-config", action="store_true")
    ap.add_argument("--list-inputs-json", action="store_true")
    ap.add_argument("--ask", metavar="QUESTION", help='ask about a meeting, e.g. "Tóm tắt cuộc họp"')
    ap.add_argument("--meeting", default="today",
                    help="'today' (default) or a transcript file name, used with --ask")
    ap.add_argument("--ask-stdin", action="store_true",
                    help='(app) read {"question", "history", "meeting"} JSON from stdin')
    ap.add_argument("--events", action="store_true", help="print @@EVENT JSON lines (for the app)")
    ap.add_argument("--audio-stdin", action="store_true",
                    help="(app) read float32 mono 16 kHz audio from stdin instead of a device")
    args = ap.parse_args()
    global EMIT_EVENTS, NOTIFY_ENABLED
    EMIT_EVENTS = args.events
    NOTIFY_ENABLED = not args.quiet
    if args.events:  # started by the app: also keep a readable log in logs/engine.log
        (HERE / "logs").mkdir(exist_ok=True)
        sys.stdout = Tee(sys.stdout, open(HERE / "logs" / "engine.log", "a", encoding="utf-8"))
        print(f"===== engine start {datetime.now():%Y-%m-%d %H:%M:%S} =====", flush=True)
    cfg_path = Path(args.config)
    cfg = load_config(cfg_path)

    if args.setup:
        run_setup(cfg_path, cfg)
        return
    if args.set_name:
        apply_names(cfg, split_list(args.set_name), split_list(args.aliases), args.jargon)
        if not cfg["my_names"]:
            sys.exit("No usable name left; use your full given name.")
        save_config(cfg_path, cfg)
        print("Will listen for:", ", ".join(cfg["my_names"]))
        print("Whisper hint:   ", cfg["whisper_prompt"])
        return
    if args.ask or args.ask_stdin:
        if args.ask_stdin:
            req = json.loads(sys.stdin.read() or "{}")
        else:
            req = {"question": args.ask, "history": [], "meeting": args.meeting}
        try:
            print(chat_answer(cfg, req.get("question", ""), req.get("history") or [],
                              req.get("meeting") or "today"))
        except Exception as e:  # noqa: BLE001
            sys.exit(f"Chat failed: {e}")
        return
    if args.list_inputs_json:
        import sounddevice as sd
        print(json.dumps([d["name"] for d in sd.query_devices() if d["max_input_channels"] > 0],
                         ensure_ascii=False))
        return
    if args.show_config:
        print(json.dumps(cfg, ensure_ascii=False, indent=2))
        return
    if not cfg["my_names"] and not (args.list_devices or args.test_notify):
        if not sys.stdin.isatty():
            emit("error", message="No name configured. Set your name in Settings.")
            sys.exit('No name configured. Run: python listener.py --set-name "Your Name"')
        print("No name configured yet.\n")
        cfg = run_setup(cfg_path, cfg)
        if not cfg["my_names"]:
            sys.exit(1)

    if args.list_devices:
        import sounddevice as sd
        print(sd.query_devices())
    elif args.test_notify:
        notify("Question for you (high)", "This is what a drafted answer will look like.",
               "Can you give us an update on the API?")
    elif args.test_transcript:
        run_transcript(cfg, Path(args.test_transcript))
    elif args.test_file:
        run_file(cfg, Path(args.test_file))
    else:
        try:
            run_live(cfg, audio_stdin=args.audio_stdin)
        except KeyboardInterrupt:
            print("\nStopped.")
            emit("status", state="stopped")


if __name__ == "__main__":
    main()
