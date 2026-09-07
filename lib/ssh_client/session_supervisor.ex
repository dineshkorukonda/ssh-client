defmodule SSHClient.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor managing individual SessionWorker processes.
  """

  use DynamicSupervisor

  @name __MODULE__

  def start_link(init_arg \\ []) do
    name = Keyword.get(init_arg, :name, @name)
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: name)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a SessionWorker under the DynamicSupervisor.
  """
  def start_worker(supervisor \\ @name, opts) when is_list(opts) do
    spec = {SSHClient.SessionWorker, opts}
    DynamicSupervisor.start_child(supervisor, spec)
  end

  @doc """
  Stops a SessionWorker by its pid.
  """
  def stop_worker(supervisor \\ @name, pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  end

  @doc """
  Lists all active children.
  """
  def which_workers(supervisor \\ @name) do
    DynamicSupervisor.which_children(supervisor)
  end

  @doc """
  Returns the count of active workers.
  """
  def count_workers(supervisor \\ @name) do
    DynamicSupervisor.count_children(supervisor).active
  end
end
