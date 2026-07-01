# Testing this branch — AX-tree wake fix + meeting chat scraping

How to validate this branch (`teams-ax-fix-chat-scrape`) against a real Teams meeting.

## Setup

1. Pull the branch:
   ```bash
   git fetch origin
   git checkout teams-ax-fix-chat-scrape
   ```
2. Build and install:
   ```bash
   ./scripts/bundle.sh --install
   ```
   This builds, installs to `/Applications/Heard.app`, and relaunches — needed so TCC
   permissions (Accessibility, etc.) stay anchored to a stable path.
3. Turn on Developer Mode: Settings → General → "Show Advanced Settings" → Advanced tab
   → Developer Mode. This is what makes `dict-debug.log` write at all.
4. Optional — enable the new chat toggle if you want to test that too: Settings →
   Recording → "Meeting Chat" → "Include Meeting Chat in Transcript". Leave it off if
   you just want to verify the AX-wake fix first (it defaults off).

## Run the test

1. Join a real Teams meeting.
2. Tail the log:
   ```bash
   tail -f ~/Library/Application\ Support/Heard/dict-debug.log
   ```
3. If the chat toggle is on, open Teams' chat panel at some point during the call and
   send/receive at least one message.
4. End the meeting and check the generated `.md` transcript in your configured output
   folder.

## What to look for

- `enableMeetingAppAccessibility: ... setErr=<n> fallbackSetErr=<n>` — `setErr` is
  expected to still be `-25205` (`kAXErrorAttributeUnsupported`, the known-broken
  `AXManualAccessibility` path). `fallbackSetErr=0` means the `AXEnhancedUserInterface`
  fallback succeeded — that's the fix working.
- `roster poll tick=K: ... titleRefreshed=true` — confirms the meeting title actually
  populated (vs. staying empty and falling back to a generic "Meeting" filename).
- If the chat toggle is on and the chat panel was open: `roster poll tick=K: chat
  read=N messages`.
- If title/roster still come back empty after several ticks, the log emits up to 3 AX
  tree dumps (`roster poll tick=K: readRoster empty — AX tree dump (n/3): ...`) — a
  bounded outline (role, identifier, description, truncated value) of Teams' real AX
  tree. **Capture and share these** — they're exactly what's needed to retune
  `RosterReader`'s (and, if chat was on and still empty, `ChatReader`'s) hardcoded
  identifiers against real Teams output, the same way `RosterReader` was originally
  tuned.
- In the final transcript `.md` file:
  - Filename should use the real meeting title, not "Meeting".
  - If chat was on and messages were sent, look for lines like
    `[mm:ss] _**Chat — <Sender>:** ...text..._` interleaved chronologically with the
    speaker segments.

## If something looks wrong

Paste back:
- The full `enableMeetingAppAccessibility` / `roster poll` log lines for that meeting.
- Any AX tree dump lines, if they appeared.
- The relevant portion of the generated transcript (filename + any chat/title lines).
