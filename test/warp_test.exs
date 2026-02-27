defmodule WarpTest do
  use ExUnit.Case
  doctest Warp

  test "greets the world" do
    assert Warp.hello() == :world
  end
end
