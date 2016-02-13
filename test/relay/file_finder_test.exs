defmodule Relay.FileFinderTest do

  alias Relay.Util.FileFinder

  use ExUnit.Case

  test "seed with env var;find directory" do
    f = FileFinder.make(env_var: "path")
    assert FileFinder.find(f, "/usr/local/bin", [:dir]) == "/usr/local/bin"
  end

  test "seed with env var;find file" do
    f = FileFinder.make(env_var: "$PATH")
    path = FileFinder.find(f, "ls", [:file, :executable])
    assert path != nil
    assert path == "/bin/ls" or path == "/usr/bin/ls"
  end

  test "seed with dir list;find subdir" do
    f = FileFinder.make(dirs: ["/usr/local"])
    assert FileFinder.find(f, "lib", [:dir]) == "/usr/local/lib"
  end

  test "missing file isn't found" do
    f = FileFinder.make(env_var: "$PATH")
    assert FileFinder.find(f, "should_not_exit") == nil
  end

end
