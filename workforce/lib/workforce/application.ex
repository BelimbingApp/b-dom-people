defmodule Bilimbi.People.Workforce.Application do
  @moduledoc false
  use Application

  alias Bilimbi.People.Workforce.EmploymentOwner

  @impl true
  def start(_type, _args) do
    EmploymentOwner.register()
    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  @impl true
  def stop(_state) do
    EmploymentOwner.unregister()
    :ok
  end
end
