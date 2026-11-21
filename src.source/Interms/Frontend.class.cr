@manager : Manager
@display_mutex = Sync::Mutex.new
@menu_open = false
@running = Atomic(Bool).new(false)

def initialize(@manager : Manager)
end

def run : Nil
  mode = TerminalMode.new
  configure_callbacks

  begin
    mode.enter
    @running.set(true)
    rows, columns = TerminalMode.dimensions
    @manager.resize(rows, columns)
    @manager.start unless @manager.started?
    @display_mutex.synchronize { render_active }

    spawn_resize_monitor

    while @running.get
      byte = STDIN.read_byte
      break unless byte

      if byte == 0
        handle_prefix
      else
        begin
          @manager.write(String.new(Bytes[byte]))
        rescue error
          show_message("Input not sent: #{error.message}")
        end
      end
    end
  ensure
    @running.set(false)
    @manager.stop
    mode.restore
    STDOUT.print("\e[0m\e[?25h\e[?1049l\e[?2004l")
    STDOUT.flush
  end
end

private def configure_callbacks : Nil
  @manager.on_output do |session, chunk|
    @display_mutex.synchronize do
      if !@menu_open && @manager.active_session == session
        STDOUT.print(chunk)
        STDOUT.flush
      end
    end
  end

  @manager.on_switch do |_session|
    @display_mutex.synchronize { render_active unless @menu_open }
  end
end

private def spawn_resize_monitor : Nil
  spawn do
    previous = TerminalMode.dimensions
    while @running.get
      sleep 250.milliseconds
      current = TerminalMode.dimensions
      if current != previous
        previous = current
        @manager.resize(current[0], current[1])
        @display_mutex.synchronize { render_active unless @menu_open }
      end
    end
  end
end

private def handle_prefix : Nil
  key = STDIN.read_byte
  return unless key

  case key
  when 'l'.ord
    show_session_list
  when 'n'.ord
    @manager.next_session
  when 'p'.ord
    @manager.previous_session
  when 'a'.ord
    add_shell
  when 'x'.ord
    close_active
  when 'q'.ord
    @running.set(false)
  when '?'.ord
    show_help
  when '1'.ord..'9'.ord
    index = key - '1'.ord
    if session = @manager.sessions[index]?
      @manager.select(session.name)
    end
  end
end

private def show_session_list : Nil
  @display_mutex.synchronize do
    @menu_open = true
    clear_screen
    STDOUT.puts "AVAILABLE SESSIONS"
    STDOUT.puts ""
    sessions = @manager.sessions
    if sessions.empty?
      STDOUT.puts "  (no sessions)"
    else
      sessions.each_with_index do |session, index|
        marker = session.name == @manager.active_name ? "*" : " "
        STDOUT.puts " #{marker} #{index + 1}  #{session.name.ljust(20)} #{session.state.upcase}"
      end
    end
    STDOUT.puts ""
    STDOUT.puts "Press 1–9 to select, or Escape to return."
    STDOUT.flush
  end

  loop do
    byte = STDIN.read_byte
    break unless byte
    break if byte == 27 || byte == 'q'.ord

    if byte >= '1'.ord && byte <= '9'.ord
      if session = @manager.sessions[byte - '1'.ord]?
        @manager.select(session.name)
      end
      break
    end
  end
ensure
  @display_mutex.synchronize do
    @menu_open = false
    render_active
  end
end

private def show_help : Nil
  @display_mutex.synchronize do
    @menu_open = true
    clear_screen
    STDOUT.puts "INTERMS HOTKEYS"
    STDOUT.puts ""
    STDOUT.puts "  Ctrl+Space, l     List sessions"
    STDOUT.puts "  Ctrl+Space, 1–9   Select session"
    STDOUT.puts "  Ctrl+Space, n     Next session"
    STDOUT.puts "  Ctrl+Space, p     Previous session"
    STDOUT.puts "  Ctrl+Space, a     Add shell"
    STDOUT.puts "  Ctrl+Space, x     Close active session"
    STDOUT.puts "  Ctrl+Space, q     Quit"
    STDOUT.puts ""
    STDOUT.puts "Press any key to return."
    STDOUT.flush
  end
  STDIN.read_byte
ensure
  @display_mutex.synchronize do
    @menu_open = false
    render_active
  end
end

private def add_shell : Nil
  index = 2
  names = @manager.session_names
  loop do
    break unless names.includes?("shell-#{index}")
    index += 1
  end
  @manager.add("shell-#{index}", shell: :sh, cwd: Dir.current)
end

private def close_active : Nil
  if name = @manager.active_name
    @manager.remove(name)
  end
  @display_mutex.synchronize { render_active }
end

private def render_active : Nil
  clear_screen
  if session = @manager.active_session
    STDOUT.print(session.output)
  else
    STDOUT.puts "No active sessions. Press Ctrl+Space, a to add a shell or Ctrl+Space, q to quit."
  end
  STDOUT.flush
end

private def show_message(message : String) : Nil
  @display_mutex.synchronize do
    STDOUT.print("\r\n#{message}\r\n")
    STDOUT.flush
  end
end

private def clear_screen : Nil
  STDOUT.print("\e[0m\e[?25h\e[?1049l\e[?2004l\e[2J\e[H")
end
