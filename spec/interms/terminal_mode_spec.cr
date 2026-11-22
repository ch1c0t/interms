require "../spec_helper"

describe Interms::TerminalMode do
  it "returns usable dimensions or the fallback when stdin is not a TTY" do
    rows, columns = Interms::TerminalMode.dimensions

    rows.should be > 0
    columns.should be > 0

    unless STDIN.tty? && STDOUT.tty?
      {rows, columns}.should eq({24, 80})
    end
  end

  it "rejects entering raw mode without an interactive terminal" do
    unless STDIN.tty? && STDOUT.tty?
      error = expect_raises(Exception) do
        Interms::TerminalMode.new.enter
      end

      error.message.should contain("interms needs a TTY")
    end
  end
end
