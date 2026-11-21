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

