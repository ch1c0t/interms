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
