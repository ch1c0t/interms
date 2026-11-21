require_relative 'helper'

describe 'cli' do
  it 'prints a help message' do
    stdout = cli '--help'
    expect(stdout.first).to include 'interms - switch between multiple interactive PTY sessions'
  end

  it 'prints the version' do
    stdout = cli '--version'
    expect(stdout.first.strip).to eq '0.1.0'
  end
end
