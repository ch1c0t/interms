require "pty"
require "sync/mutex"
require "random"

module Interms
  extend self

  VERSION = "0.1.0"


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
      STDOUT.print("\e[?1049h\e[?25l")
      STDOUT.flush
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
          STDOUT.puts " #{marker} #{index + 1}  #{session.name.ljust(20)} #{session.state.to_s.upcase}"
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


  @mutex = Sync::Mutex.new
  @sessions = {} of String => Session
  @order = [] of String
  @active_name : String? = nil
  @rows : Int32
  @columns : Int32
  @started = false
  @stopped = false
  @output_callback : Proc(Session, String, Nil)? = nil
  @switch_callback : Proc(Session, Nil)? = nil

  def initialize(@rows : Int32 = 24, @columns : Int32 = 80)
    raise ArgumentError.new("Rows and columns must be positive") if @rows <= 0 || @columns <= 0
  end

  def on_output(&callback : Session, String -> Nil) : self
    @mutex.synchronize { @output_callback = callback }
    self
  end

  def on_switch(&callback : Session -> Nil) : self
    @mutex.synchronize { @switch_callback = callback }
    self
  end

  def started? : Bool
    @mutex.synchronize { @started }
  end

  def sessions : Array(Session)
    @mutex.synchronize do
      @order.compact_map { |name| @sessions[name]? }
    end
  end

  def session_names : Array(String)
    @mutex.synchronize { @order.dup }
  end

  def session(name : String) : Session?
    @mutex.synchronize { @sessions[name]? }
  end

  def active_session : Session?
    @mutex.synchronize do
      @active_name.try { |name| @sessions[name]? }
    end
  end

  def active_name : String?
    @mutex.synchronize { @active_name }
  end

  def add(
    name : String,
    shell : String | Symbol = :sh,
    cwd : String? = nil,
    environment : Hash(String, String) = {} of String => String
  ) : Session
    add(Session.new(name, shell: shell, rows: @rows, columns: @columns, cwd: cwd, environment: environment))
  end

  # Register an Interms::Session that the application constructed itself.
  def add(created : Session) : Session
    name = created.name
    start_now = false
    became_active = false

    @mutex.synchronize do
      raise "Manager has been stopped" if @stopped
      raise ArgumentError.new("Session already exists: #{name}") if @sessions.has_key?(name)

      @sessions[name] = created
      @order << name
      if @active_name.nil?
        @active_name = name
        became_active = true
      end
      start_now = @started
    end

    begin
      created.start(output_handler) if start_now
      notify_switch(created) if became_active && start_now
      created
    rescue ex
      @mutex.synchronize do
        @sessions.delete(name)
        @order.delete(name)
        @active_name = @order.first? if @active_name == name
      end
      created.stop
      raise ex
    end
  end

  # Convenience overload for adopting an existing PTY::Session.
  def add(
    name : String,
    pty : PTY::Session,
    interactive_shell : String | Symbol = :sh
  ) : Session
    add(Session.new(name, pty, interactive_shell))
  end


  def start : self
    configured = @mutex.synchronize do
      raise "Manager has been stopped" if @stopped
      return self if @started
      @started = true
      @order.compact_map { |name| @sessions[name]? }
    end

    begin
      configured.each { |session| session.start(output_handler) }
      notify_switch(active_session)
      self
    rescue ex
      stop
      raise ex
    end
  end

  def select(name : String) : Session
    selected = @mutex.synchronize do
      @sessions[name]? || raise ArgumentError.new("Unknown session: #{name}")
    end

    changed = @mutex.synchronize do
      previous = @active_name
      @active_name = name
      previous != name
    end
    notify_switch(selected) if changed
    selected
  end

  def next_session : Session?
    select_relative(1)
  end

  def previous_session : Session?
    select_relative(-1)
  end

  def write(data : String) : Nil
    selected = active_session || raise "No active session"
    selected.write(data)
  end

  def resize(rows : Int32, columns : Int32) : Nil
    raise ArgumentError.new("Rows and columns must be positive") if rows <= 0 || columns <= 0
    current = @mutex.synchronize do
      @rows = rows
      @columns = columns
      @order.compact_map { |name| @sessions[name]? }
    end
    current.each { |session| session.resize(rows, columns) }
  end

  def remove(name : String) : Session?
    removed = nil.as(Session?)
    next_active = nil.as(Session?)
    active_changed = false

    @mutex.synchronize do
      removed = @sessions.delete(name)
      return nil unless removed

      index = @order.index(name) || 0
      @order.delete_at(index)
      if @active_name == name
        @active_name = @order.empty? ? nil : @order[index % @order.size]?
        next_active = @active_name.try { |active| @sessions[active]? }
        active_changed = true
      end
    end

    removed.not_nil!.stop
    notify_switch(next_active) if active_changed && next_active
    removed
  end

  def stop : Nil
    configured = @mutex.synchronize do
      return if @stopped
      @stopped = true
      @started = false
      @order.compact_map { |name| @sessions[name]? }
    end

    configured.reverse_each { |session| session.stop }
  end

  private def select_relative(direction : Int32) : Session?
    selected = @mutex.synchronize do
      return nil if @order.empty?
      current_index = @active_name ? (@order.index(@active_name.not_nil!) || 0) : 0
      next_index = (current_index + direction) % @order.size
      @active_name = @order[next_index]
      @sessions[@active_name.not_nil!]
    end

    notify_switch(selected) if selected
    selected
  end

  private def output_handler : Proc(Session, String, Nil)
    ->(session : Session, chunk : String) do
      callback = @mutex.synchronize { @output_callback }
      callback.try &.call(session, chunk)
    end
  end

  private def notify_switch(session : Session?) : Nil
    return unless session
    callback = @mutex.synchronize { @switch_callback }
    callback.try &.call(session)
  end


  getter name : String

  @rows : Int32
  @columns : Int32
  @shell_command : String
  @pty : PTY::Session

  @mutex = Sync::Mutex.new
  @state : Symbol = :created
  @exit_code : Int32? = nil
  @error : String? = nil
  @output = IO::Memory.new
  @pending = ""
  @prompt_marker : String
  @exit_marker : String
  @ready = false
  @shell_finished = false
  @stopping = false

  def initialize(
    @name : String,
    shell : String | Symbol = :sh,
    @rows : Int32 = 24,
    @columns : Int32 = 80,
    cwd : String? = nil,
    environment : Hash(String, String) = {} of String => String
  )
    validate_name
    raise ArgumentError.new("Rows and columns must be positive") if @rows <= 0 || @columns <= 0

    @shell_command = shell.is_a?(Symbol) ? shell.to_s : shell
    pty_environment = environment.dup
    pty_environment["PS1"] = "$ "
    @pty = PTY::Session.new(
      shell,
      rows: @rows,
      columns: @columns,
      name: @name,
      env: pty_environment,
      cwd: cwd
    )
    @prompt_marker = "__INTERMS_PROMPT_#{Process.pid}_#{Random.rand(1_i64..Int64::MAX)}__"
    @exit_marker = "__INTERMS_EXIT_#{Process.pid}_#{Random.rand(1_i64..Int64::MAX)}__"
  end

  # Adopt an existing PTY::Session. The PTY must be a fresh session or an
  # interactive shell session that can accept the Interms startup commands.
  def initialize(
    @name : String,
    @pty : PTY::Session,
    interactive_shell : String | Symbol = :sh
  )
    validate_name
    @rows = @pty.rows
    @columns = @pty.columns
    raise ArgumentError.new("Rows and columns must be positive") if @rows <= 0 || @columns <= 0

    @shell_command = interactive_shell.is_a?(Symbol) ? interactive_shell.to_s : interactive_shell
    @prompt_marker = "__INTERMS_PROMPT_#{Process.pid}_#{Random.rand(1_i64..Int64::MAX)}__"
    @exit_marker = "__INTERMS_EXIT_#{Process.pid}_#{Random.rand(1_i64..Int64::MAX)}__"
  end

  def pty : PTY::Session
    @pty
  end

  private def validate_name : Nil
    unless @name.matches?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/)
      raise ArgumentError.new("Invalid session name: #{@name.inspect}")
    end
  end

  def state : Symbol
    @mutex.synchronize { @state }
  end

  def running? : Bool
    state == :running
  end

  def exit_code : Int32?
    @mutex.synchronize { @exit_code }
  end

  def error : String?
    @mutex.synchronize { @error }
  end

  # A snapshot of the raw terminal byte stream received since the child shell
  # displayed its first prompt.
  def output : String
    @mutex.synchronize { @output.to_s }
  end

  def start(on_output : Proc(Session, String, Nil)? = nil) : self
    current = state
    return self if current == :running
    unless current == :created
      raise "Cannot start session '#{@name}' from state #{current}"
    end

    @mutex.synchronize { @state = :starting }

    begin
      @pty.start

      # Hide the command wrapper that PTY::Session#run writes to the parent
      # shell. The interactive child shell turns echo back on before prompting.
      @pty.write("stty -echo\n")

      callback = on_output || ->(_session : Session, _chunk : String) { }
      spawn do
        run_interactive_shell(callback)
      end

      wait_until_ready
      self
    rescue ex
      @mutex.synchronize do
        @state = :failed
        @error = ex.message || ex.class.name
      end
      @pty.terminate if @pty.started?
      raise ex
    end
  end

  def write(data : String) : Nil
    raise "Session '#{@name}' is not running (state: #{state})" unless running?
    @pty.write(data)
  end

  def resize(rows : Int32, columns : Int32) : Nil
    raise ArgumentError.new("Rows and columns must be positive") if rows <= 0 || columns <= 0
    @rows = rows
    @columns = columns
    @pty.rows = rows
    @pty.columns = columns
    @pty.resize(rows, columns) if @pty.started?
  end

  def stop : Nil
    should_terminate = @mutex.synchronize do
      case @state
      when :stopped
        false
      when :created
        @state = :stopped
        false
      else
        @stopping = true
        @state = :stopping
        true
      end
    end

    return unless should_terminate

    begin
      @pty.terminate if @pty.started?
    ensure
      @mutex.synchronize { @state = :stopped }
    end
  end

  private def interactive_command : String
    executable = shell_quote(@shell_command)
    prompt = @prompt_marker
    exit_marker = @exit_marker
    "stty echo; PS1='#{prompt}'; export PS1; #{executable} -i; shell_status=$?; printf '%s' '#{exit_marker}'; exit \"$shell_status\""
  end

  private def shell_quote(value : String) : String
    "'" + value.gsub("'", "'\\''") + "'"
  end

  private def run_interactive_shell(callback : Proc(Session, String, Nil)) : Nil
    begin
      result = @pty.run(interactive_command) do |chunk|
        receive_output(chunk, callback)
      end

      @mutex.synchronize do
        @exit_code = result.status
        unless @stopping
          @state = @shell_finished ? :exited : :failed
          @error ||= "Interactive shell ended before its exit marker was received" unless @shell_finished
        end
      end
    rescue ex
      @mutex.synchronize do
        unless @stopping
          @state = :failed
          @error = ex.message || ex.class.name
        end
      end
    end
  end

  private def receive_output(chunk : String, callback : Proc(Session, String, Nil)) : Nil
    emitted = ""

    @mutex.synchronize do
      @pending += chunk

      unless @ready
        if index = @pending.index(@prompt_marker)
          emitted = @pending.byte_slice(index, @pending.bytesize - index) || ""
          @pending = ""
          @ready = true
          @state = :running
        else
          keep = @prompt_marker.bytesize - 1
          if keep > 0 && @pending.bytesize > keep
            @pending = @pending.byte_slice(@pending.bytesize - keep, keep) || ""
          end
        end
      else
        if index = @pending.index(@exit_marker)
          emitted = @pending.byte_slice(0, index) || ""
          @pending = ""
          @shell_finished = true
        else
          suffix_bytes = matching_exit_marker_prefix
          safe_bytes = @pending.bytesize - suffix_bytes
          if safe_bytes > 0
            emitted = @pending.byte_slice(0, safe_bytes) || ""
            @pending = @pending.byte_slice(safe_bytes, @pending.bytesize - safe_bytes) || ""
          end
        end
      end

      @output.write(emitted.to_slice) unless emitted.empty?
    end

    callback.call(self, emitted) unless emitted.empty?
  end

  private def wait_until_ready : Nil
    deadline = Time.instant + 10.seconds

    loop do
      current = state
      return if current == :running

      if current == :failed || current == :exited || current == :stopped
        raise "Session '#{@name}' failed to start: #{error || current}"
      end

      if Time.instant >= deadline
        raise "Timed out waiting for the interactive shell prompt in '#{@name}'"
      end

      sleep 10.milliseconds
    end
  end

  private def matching_exit_marker_prefix : Int32
    maximum = {@pending.bytesize, @exit_marker.bytesize - 1}.min
    maximum.downto(1) do |length|
      suffix = @pending.byte_slice(@pending.bytesize - length, length)
      prefix = @exit_marker.byte_slice(0, length)
      return length if suffix == prefix
    end
    0
  end


  @saved_state : String? = nil

  def enter : Nil
    raise "interms needs a TTY on both stdin and stdout" unless STDIN.tty? && STDOUT.tty?

    state = IO::Memory.new
    status = Process.run("stty", ["-g"], output: state, error: STDERR)
    raise "Could not read terminal settings with stty -g" unless status.success?
    @saved_state = state.to_s.strip

    status = Process.run("stty", ["raw", "-echo", "min", "1", "time", "0"], error: STDERR)
    raise "Could not enable raw terminal mode" unless status.success?
  end

  def restore : Nil
    if state = @saved_state
      Process.run("stty", [state], error: STDERR)
      @saved_state = nil
    end
  rescue
    nil
  end

  def self.dimensions : Tuple(Int32, Int32)
    output = IO::Memory.new
    status = Process.run("stty", ["size"], output: output, error: IO::Memory.new)
    if status.success?
      values = output.to_s.split
      if values.size == 2
        rows = values[0].to_i?
        columns = values[1].to_i?
        return {rows, columns} if rows && columns && rows > 0 && columns > 0
      end
    end
    {24, 80}
  rescue
    {24, 80}
  end

end
