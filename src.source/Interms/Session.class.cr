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
  unless @name.matches?(/\\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\\z/)
    raise ArgumentError.new("Invalid session name: #{@name.inspect}")
  end
end


