# interms

A terminal session manager for Crystal. It runs multiple interactive shells
through independent `PTY::Session` instances and lets you switch between them
with keyboard shortcuts.

The same `Interms::Manager` API can be embedded in another Crystal
application, or used through the standalone `interms` executable. The
frontend works in a normal terminal, an SSH terminal, or a Tmux pane.

## Build

```sh
bundle install
shards install
bundle exec rake
```

## Run

```sh
./bin/interms
./bin/interms --shell bash --name builder --cwd /mnt/shared
```

Press **Ctrl+Space** to open the session command menu:

| Key | Action |
| --- | --- |
| Ctrl+Space, l | List sessions and select one with 1–9 |
| Ctrl+Space, 1–9 | Switch directly to a session |
| Ctrl+Space, n | Select the next session |
| Ctrl+Space, p | Select the previous session |
| Ctrl+Space, a | Add a new shell session |
| Ctrl+Space, x | Close the active session |
| Ctrl+Space, q | Exit interms |

Ordinary keys are forwarded to the active PTY session. Sessions that are not
visible continue running and their output is retained. Selecting a session
clears the display and replays its captured terminal byte stream.

## Library

Add the shard to `shard.yml`:

```yaml
dependencies:
  interms:
    github: ch1c0t/interms
    branch: main
```

Then use the library:

```crystal
require "interms"

manager = Interms::Manager.new(rows: 40, columns: 120)

manager.add("shell", shell: :bash, cwd: Dir.current)
manager.add("builder", shell: :bash, cwd: "/mnt/shared/grml-live-build")

manager.on_output do |session, chunk|
  # Receive output from any session.
end

manager.start
manager.select("builder")
manager.write("pwd\n")
manager.next_session
manager.stop
```

`Manager#add` creates a session. `Manager#start` starts all configured
sessions; sessions added afterward start immediately. The manager owns session
lifecycle and forwards input to the active session. `on_output` receives
(`Session, String`) pairs from the corresponding session's PTY reader fiber.
Use `on_switch` to observe active-session changes.

The lower-level `Interms::Session` abstraction is also public when an
application needs to manage a PTY session directly.

## Current rendering model and limitations

Each session owns an independent PTY process and retains its raw output bytes.
The initial frontend is a **pass-through terminal with transcript replay**:
it forwards the active session's bytes to the outer terminal and replays a
session's captured stream when switching back to it. This preserves ordinary
ANSI colour output and commonly used cursor-control sequences when replayed.

This is not yet a full virtual-terminal emulator. Complex full-screen programs
that depend on terminal modes, mouse input, focus events, or exact independent
screen state may not be restored perfectly after switching. A per-session VT
screen model is a planned next layer; the manager and PTY lifecycle API do not
depend on the current renderer.

The output transcript is currently retained in memory for the lifetime of
each session. Long-running sessions with large output can therefore consume
substantial memory.

## Design

- `Interms::Manager` owns a registry of named `Interms::Session` objects.
- Each `Interms::Session` owns one `PTY::Session` and an interactive child
  shell. Input is written to that PTY, and output is captured through the
  PTY session's streaming callback.
- `Interms::Frontend` owns the outer terminal's raw mode, hotkeys, display,
  and resize detection. It does not own the sessions.
- The library can be used without loading or starting the interactive
  frontend.

Run specs with:

```sh
bundle exec rake
crystal spec
bundle exec rspec
```
