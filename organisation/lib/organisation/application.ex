defmodule Bilimbi.People.Organisation.Application do
  @moduledoc false
  use Application

  alias Bilimbi.People.Workforce

  @impl true
  def start(_type, _args) do
    :ok = Workforce.register_position_reader(Bilimbi.People.Organisation)
    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  @impl true
  def stop(_state) do
    Workforce.unregister_position_reader(Bilimbi.People.Organisation)
    :ok
  end
end
