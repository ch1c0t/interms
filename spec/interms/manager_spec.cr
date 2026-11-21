require "../spec_helper"

describe Interms::Manager do
  it "registers sessions and selects the first one by default" do
    manager = Interms::Manager.new
    first = manager.add("shell")
    second = manager.add("builder", shell: :bash, cwd: "/tmp")

    manager.session_names.should eq(["shell", "builder"])
    manager.active_session.should eq(first)
    manager.session("builder").should eq(second)
  end

  it "switches between sessions in insertion order" do
    manager = Interms::Manager.new
    manager.add("one")
    two = manager.add("two")
    three = manager.add("three")

    manager.next_session.should eq(two)
    manager.next_session.should eq(three)
    manager.next_session.should eq(manager.session("one"))
    manager.previous_session.should eq(three)
  end

  it "selects a session by name" do
    manager = Interms::Manager.new
    manager.add("shell")
    builder = manager.add("builder")

    manager.select("builder").should eq(builder)
    manager.active_name.should eq("builder")
  end

  it "rejects duplicate and invalid session names" do
    manager = Interms::Manager.new
    manager.add("shell")

    expect_raises(ArgumentError) { manager.add("shell") }
    expect_raises(ArgumentError) { manager.add("invalid name") }
    expect_raises(ArgumentError) { manager.select("missing") }
  end

  it "removes a session and selects the next available one" do
    manager = Interms::Manager.new
    manager.add("one")
    two = manager.add("two")
    manager.add("three")

    manager.remove("one").not_nil!.state.should eq(:stopped)
    manager.active_session.should eq(two)
    manager.session_names.should eq(["two", "three"])
  end


  it "adopts a caller-created PTY::Session" do
    pty = PTY::Session.new(:sh, rows: 30, columns: 100)
    manager = Interms::Manager.new
    session = manager.add("adopted", pty)

    session.pty.should be(pty)
    session.name.should eq("adopted")
    manager.active_session.should eq(session)
    session.resize(40, 120)
    pty.rows.should eq(40)
    pty.columns.should eq(120)
  end

  it "registers an Interms::Session created by the application" do
    pty = PTY::Session.new(:bash)
    session = Interms::Session.new("custom", pty, :bash)
    manager = Interms::Manager.new

    manager.add(session).should eq(session)
    manager.session("custom").should eq(session)
  end

  it "supports callbacks for output and session changes" do
    manager = Interms::Manager.new
    selected = [] of String
    manager.on_switch { |session| selected << session.name }

    manager.add("one")
    manager.add("two")
    manager.select("two")

    selected.should eq(["two"])
  end

  it "updates the dimensions of sessions before they are started" do
    manager = Interms::Manager.new
    session = manager.add("shell")
    manager.resize(40, 120)

    session.resize(40, 120)
    session.state.should eq(:created)
  end
end
