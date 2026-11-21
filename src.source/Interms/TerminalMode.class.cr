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
