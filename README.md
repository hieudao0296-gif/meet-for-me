# Meet for Me (free, local)

*[Hướng dẫn tiếng Việt](README.vi.md)*

Listens to Zoom audio on your Mac, transcribes it locally with Whisper, and when someone
asks *you* something, shows a macOS notification with the question and a drafted answer.

```
Meeting app (Zoom / Meet / Teams) -> app-audio capture -> mlx-whisper (local) -> name filter -> Claude -> alert
```

**Audio source.** By default the app records **only your meeting apps** (Zoom, Teams, Webex,
your browser…) with macOS app-audio capture (macOS 14.4+). YouTube or music in other apps
stays out, and no BlackHole setup is needed. macOS asks once to allow *System Audio
Recording*. A browser is captured as a whole, so play YouTube in a different browser than
your meeting. Switch apps in Settings → Audio source, or pick *BlackHole device* to capture
everything through a virtual device (setup below).

Cost: $0 extra. Answers use your existing Claude Code login (`claude -p`).
For a fully offline setup, use Ollama instead (see below).

## Install

Needs an Apple Silicon Mac, Python 3.9+ and the Claude Code CLI (`claude`) logged in.
```
git clone <this repo> ~/Documents/zoom-listener && cd ~/Documents/zoom-listener
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
app/build.sh            # builds app/build/Meet for Me.app (Command Line Tools only)
```
The first run downloads the speech model (PhoWhisper, ~1.6 GB). Your settings go to `config.json`
and your notes to `context.md`. Both are created locally and git-ignored, as are
`transcripts/`, `answers/` and `logs/`. The defaults come from `config.example.json`.

## One-time setup

The app's setup guide walks you through all of this and checks each step. With the default
*meeting apps* source you only need step 4 (permissions: allow **System Audio Recording**
under Privacy & Security → Screen & System Audio Recording) and step 5. Steps 1–3 are for
the optional *BlackHole device* source.

1. **Install BlackHole** (free virtual audio device; asks for your password):
   ```
   brew install --cask blackhole-2ch
   ```
   Then restart your Mac, or restart Core Audio with `sudo killall coreaudiod`.

2. **Create a Multi-Output Device** so you still hear the meeting:
   open *Audio MIDI Setup* → `+` → *Create Multi-Output Device* → tick your
   speakers/headphones **and** *BlackHole 2ch* (put your speakers first, and tick
   *Drift Correction* for BlackHole).

3. **In Zoom**: Settings → Audio → Speaker → select that *Multi-Output Device*.
   Leave your microphone as it is.

4. **Permissions** (macOS asks the first time):
   - Microphone access for your terminal app (needed to read BlackHole).
   - Notifications for *Script Editor* (that's who sends `osascript` notifications).
     Set its style to **Alerts** in System Settings → Notifications if you want them to stay on screen.
   - Optional: `brew install terminal-notifier` → clicking a notification opens the full answer.

5. **Set your name:**
   ```
   .venv/bin/python listener.py --setup
   ```
   It asks for your name *with tone marks* (e.g. `Hiếu, Trung Hiếu`), other names people
   call you (English name, nickname) and project words Whisper should spell right.
   The unaccented forms (`Hieu`) are added automatically for English speakers.
   Non-interactive version:
   ```
   .venv/bin/python listener.py --set-name "Hiếu, Trung Hiếu" --aliases "Hugh"
   ```
   If no name is set, the listener asks on first start. `--show-config` prints the current settings.
   Single words that are also pronouns (`Anh`, `Em`, `Chị`…) are rejected. Use the full
   given name instead (`Đức Anh`).

6. Optional: put your project status in **context.md** (or Settings → Notes in the app).

## When it alerts

The name and the question are often on different lines ("Anh Hiếu ơi." … "Cho em hỏi…"
… "…khi nào xong ạ?"), so after hearing your name it **waits for the speaker to finish**:
it checks once the speaker pauses for `question_settle_seconds` (2.5 s), or as soon as a
line ends like a question ("?", không, chưa, ạ, nhỉ, khi nào…). Claude gets the two lines
before your name and everything after it, so a question asked before your name also counts.

- Question found → notification with the drafted answer.
- Only called so far ("Hiếu ơi, cho em hỏi chút") → it keeps listening and re-checks as
  more lines arrive, for up to `question_wait_seconds` (30 s). If no question comes, you
  get a "Someone called you" notification.
- Only mentioned, asked of someone else, or withdrawn ("thôi, để sau") → no alert.

Test timing with `@wait N` lines (N seconds of silence) in a `--test-transcript` file.

## Where drafted answers come from

1. **The meeting transcript** (the whole meeting, up to `context_minutes`, default 120):
   anything already said that answers the question. If it disagrees with your notes,
   the transcript wins because it's newer.
2. **Your notes** (`context.md`), only for what the meeting didn't cover. Notes are
   skipped if the file is empty or still the example template, and re-read for each
   question, so mid-meeting edits count.
3. Neither has it → an honest "I'll check and follow up" draft with confidence *low*.

Each answer lists what it was **based on** (`transcript 14:02: …`, `notes: …`) in
`answers/*.md` and on the card in the app. The draft itself never mentions sources,
because you say it out loud.

Chat from the terminal:
```
.venv/bin/python listener.py --ask "Có ai hỏi mình gì không?"            # today's meetings
.venv/bin/python listener.py --ask "Tóm tắt" --meeting 2026-11-13_1446.txt
```
Test runs (`--test-file`, `--test-transcript`) don't write to `transcripts/`, so they never
show up in the chat.

Test the answering without audio by feeding a text transcript, one line per utterance:
```
.venv/bin/python listener.py --quiet --test-transcript meeting.txt
```

> **Zoom in the browser?** Then there's no Zoom Speaker setting: set the Mac's
> *System Settings → Sound → Output* to *Multi-Output Device* instead.

## Vietnamese

- `"language": "vi"` is set. Whisper handles Vietnamese mixed with English terms, but may
  mishear terms (it wrote "ATI" for "API" in testing). Add your project's jargon to
  `whisper_prompt` to bias it.
- **Name matching keeps tone marks**, so `Hiếu` (the name) does not match `hiểu` (understand)
  or `hiệu`. Write Vietnamese names with the correct tones in `my_names`. Unaccented entries
  (`Hieu`, `Hugh`) only match English-style transcriptions.
- If someone else in the meeting is also called Hiếu, use the full name (`"Trung Hiếu"`) and
  remove the bare `Hiếu`. Expect some false alerts otherwise.
- Answers come back in the language of the question, using pronouns that match how you were
  addressed (anh / em / chị).
- **Speech model:** the default is **PhoWhisper vien-cs** (`sangdth/phowhisper-large-vien-cs-mlx-8bit`),
  VinAI's Vietnamese Whisper fine-tuned for Vietnamese with English words mixed in. On our
  14-sentence test it made about half the errors of `whisper-large-v3-turbo` (7% vs 13% word
  error rate) and got far more English terms right ("fix", "demo", "frontend", "API"); it's
  about 0.6 s slower per line. Switch in Settings → Transcription → Speech model.
  Each line is decoded once; only a line that would be dropped as low-confidence is retried.
- **"X ơi" calls:** a word followed by "ơi" counts as your name even with a wrong tone mark
  (speech-to-text often writes "hiểu ơi" for "Hiếu ơi"); elsewhere matching stays tone-exact.

## Mac app

`app/build/Meet for Me.app` is a small native front end for `listener.py`:

- **Setup guide** on first launch: your name(s), then a live checklist for BlackHole,
  the Multi-Output Device (it checks BlackHole is actually ticked in it), the Mac sound
  output, Microphone and Notifications access, the engine and the Claude CLI. Each item
  shows **Done**, **Need setup** or **Recommended**, with "How to fix" steps. The
  **Setup** tab re-runs the checks at any time (also on every launch); missing items
  show an orange bar under the status line.
- **Floating alerts:** a card in the top-right corner for each question (with the drafted
  answer and a copy button), "someone called you", name mentions and "no meeting audio".
  It shows even when Focus / Do Not Disturb is on, and it's **hidden from screen sharing
  and recordings**, so participants never see your drafted answers. A regular notification
  from *Meet for Me* is sent too (allow it when macOS asks; Focus can delay that one).
- **Start / Stop** button (also in the menu bar, under the ear icon). Closing the
  window keeps it running in the menu bar.
- **Live** tab: questions for you with drafted answers (copy button), and the live
  transcript with your mentions highlighted.
- **Chat** tab: ask anything about the meeting ("Tóm tắt cuộc họp", "Mình được giao việc gì?").
  Answers come from the transcript (and your notes), with times like (14:37), and follow-up
  questions keep the conversation. Pick *Today (all)* or one recording session.
  Hover a transcript line in the Live tab and click its chat icon to ask about that line
  (answered if it's a question, explained otherwise).
- **Settings** tab: your name(s), other names, audio input, language, project words,
  Claude model (or Ollama) and your notes (`context.md`). Opens automatically on first run.

Drag it to `/Applications` if you like. It still runs the engine from this folder
(changeable in Settings → Engine), so keep the folder where it is.
Rebuild after changing the Swift code with `app/build.sh`.
After a rebuild, macOS asks again for its permissions unless the app is signed with the
local certificate (see "Keep permissions across rebuilds" below).
`open "Meet for Me.app" --args --autostart` starts listening on launch.

Only one listener runs at a time: a second copy (app or terminal) is refused,
because two copies would answer every question twice.

### Keep permissions across rebuilds (optional)

macOS ties permissions (audio recording, Documents) to the app's signature. With the
default one-off ("ad-hoc") signing, every rebuild looks like a new app and asks again.
`app/build.sh` signs with a local certificate named **Meet for Me Local Signing** when one
exists, and then permissions survive rebuilds. To create it once (it stays in your login
keychain; the temporary files are deleted):
```
T=$(mktemp -d) && cd $T && umask 077
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Meet for Me Local Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > c.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 3650 -config c.cnf
PW=$(openssl rand -hex 16); openssl pkcs12 -export -inkey k.pem -in c.pem -name "Meet for Me Local Signing" -out id.p12 -passout pass:$PW
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
cd - && rm -rf $T
```
Then run `app/build.sh` and grant the permissions one last time. The keychain lists the
certificate as "not trusted"; that's expected and doesn't matter for local signing.

## Run from the terminal

```
cd ~/Documents/zoom-listener
.venv/bin/python listener.py
```

Other commands:
- `--list-devices` shows audio inputs (the config matches `audio_device` by substring)
- `--test-notify` sends a sample notification
- `--test-file some.aiff` runs the whole pipeline on a recording

Transcripts go to `transcripts/` and drafted answers to `answers/`.

## Fully offline option (Ollama)

```
brew install ollama && ollama serve &
ollama pull qwen3:8b
```
Then set `"llm_backend": "ollama"` in config.json.

## Troubleshooting

- **Nothing in the transcript (meeting-app capture):** check Privacy & Security → Screen &
  System Audio Recording → *System Audio Recording Only* → Meet for Me is on (after a
  rebuild, turn it off and on again: each local build counts as a new app). Check the meeting
  app is ticked in Settings → Audio source ("playing now" shows next to apps making sound).
  `logs/capture.log` shows what's captured (`peak=0.0` means silence).
- **Nothing in the transcript (BlackHole):** the meeting audio isn't reaching BlackHole. With Zoom in a
  browser, the Mac's *Sound → Output* must be *Multi-Output Device*; with the Zoom app, Zoom's
  *Speaker* must be. The app shows an orange banner when the output is wrong, and a
  notification after 45 s without audio (`silence_warning_seconds`).
- **Junk lines** ("Cảm ơn các bạn đã theo dõi", "Gi Gi Gi…"): Whisper invents text on noise.
  Clips with under 0.5 s of sound are skipped, and invented lines are dropped: low-confidence
  output, repetition loops, known YouTube phrases, echoes of the hint text, and wrong scripts.
  Dropped lines are printed as `(dropped: …)` in the engine log (`logs/engine.log`).
  Add any other phrase you see to `HALLUCINATION_PHRASES` in listener.py.
- **Other sounds get transcribed too (YouTube, music):** with the Mac output set to
  Multi-Output Device, everything the Mac plays is captured. If you use the Zoom/Teams
  app, set only *its* Speaker to Multi-Output Device and leave the Mac output on your
  speakers, so other sounds stay out.
- **Your own voice never appears:** only what Zoom plays (other people) goes through
  BlackHole. To test alone, join from a second device or play audio into the meeting.

## Tuning
- Lines not detected → lower `silence_threshold` (e.g. 0.003). Too many fragments → raise it.
- English-only meeting → set `"language": "en"`; `null` auto-detects per utterance.
- `claude_model` can be `haiku` for faster answers or `opus` for better ones.
- No speaker labels: Whisper doesn't know who spoke, so Claude infers who is asking from context.
