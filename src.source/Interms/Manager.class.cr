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
  created = Session.new(name, shell: shell, rows: @rows, columns: @columns, cwd: cwd, environment: environment)
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
