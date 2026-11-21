HELP_MESSAGE = <<-S
interms - switch between multiple interactive PTY sessions

Usage:
  interms [--name NAME] [--shell EXECUTABLE] [--cwd DIRECTORY]

Options:
  --name NAME          Name of the initial session (default: shell)
  --shell EXECUTABLE   Interactive shell to start (default: sh)
  --cwd DIRECTORY     Initial working directory

Hotkeys (Ctrl+Space prefix):
  l     List sessions and select with 1–9
  1–9   Select session directly
  n     Next session
  p     Previous session
  a     Add a new shell session
  x     Close the active session
  q     Quit interms
  ?     Show hotkeys
S

def print_help
  puts HELP_MESSAGE
end
