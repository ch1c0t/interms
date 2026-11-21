require "../spec_helper"

describe Interms::Session do
  it "starts an interactive shell and streams its output" do
    session = Interms::Session.new("interactive-spec", shell: :sh)
    begin
      session.start
      session.running?.should be_true

      session.write("printf 'INTERMS_SESSION_READY\\n'\n")
      deadline = Time.instant + 5.seconds
      until session.output.includes?("INTERMS_SESSION_READY") || Time.instant >= deadline
        sleep 10.milliseconds
      end

      session.output.should contain("INTERMS_SESSION_READY")
      session.write("exit\n")

      deadline = Time.instant + 5.seconds
      while session.state == :running && Time.instant < deadline
        sleep 10.milliseconds
      end
      session.state.should eq(:exited)
    ensure
      session.stop
    end
  end

  it "loads Bash user configuration while restoring the Interms readiness prompt" do
    home = File.join(Dir.tempdir, "interms-bash-home-#{Process.pid}-#{Random.rand(1_i64..Int64::MAX)}")
    Dir.mkdir(home)
    bashrc = File.join(home, ".bashrc")
    File.write(bashrc, "export INTERMS_BASHRC_VALUE=from-user-rc\\nPS1='user-prompt> ' \\n")

    session = Interms::Session.new(
      "bash-rc-spec",
      shell: :bash,
      environment: {"HOME" => home}
    )

    begin
      session.start
      session.running?.should be_true

      session.write("printf 'BASH_RC_OK=%s\\n' \"$INTERMS_BASHRC_VALUE\"\\n")
      deadline = Time.instant + 5.seconds
      until session.output.includes?("BASH_RC_OK=from-user-rc") || Time.instant >= deadline
        sleep 10.milliseconds
      end

      session.output.should contain("BASH_RC_OK=from-user-rc")
    ensure
      session.stop
      File.delete(bashrc) if File.exists?(bashrc)
      Dir.delete(home) if Dir.exists?(home)
    end
  end

end
