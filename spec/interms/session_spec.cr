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
end
