require "./interms/*"

VERSION = "0.1.0"

case ARGV.size
when 1
  case ARGV[0]
  when "-v", "version", "--version"
    puts VERSION
    exit
  when "-h", "help", "--help"
    print_help
    exit
  end
end

require "../interms"

shell : String | Symbol = :sh
name = "shell"
cwd : String? = nil

arguments = ARGV.dup
until arguments.empty?
  argument = arguments.shift
  case argument
  when "--shell"
    shell = arguments.shift? || raise ArgumentError.new("--shell requires an executable")
  when "--name"
    name = arguments.shift? || raise ArgumentError.new("--name requires a name")
  when "--cwd"
    cwd = arguments.shift? || raise ArgumentError.new("--cwd requires a directory")
  when "--help", "-h", "help"
    print_help
    exit
  when "--version", "-v", "version"
    puts VERSION
    exit
  else
    raise ArgumentError.new("Unknown argument: #{argument}")
  end
end

manager = Interms::Manager.new
begin
  manager.add(name, shell: shell, cwd: cwd)
  Interms::Frontend.new(manager).run
rescue error
  STDERR.puts "interms: #{error.message}"
  exit 1
ensure
  manager.stop
end

