defmodule MockSSHClient do
  @moduledoc false

  @spec exec(any(), binary()) :: {:ok, binary(), non_neg_integer()} | {:error, term()}
  def exec(_session, _cmd) do
    # Return a successful dummy response for any command
    {:ok, "mock output", 0}
  end
end
