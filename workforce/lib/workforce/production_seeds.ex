defmodule Bilimbi.People.Workforce.ProductionSeeds do
  @moduledoc """
  Claims every existing Core Employee HR row into People.

  Runs through `mix bilimbi.seeds.run` after the migrations. The claim copies
  values verbatim and is idempotent; rows People cannot claim are listed on
  the workforce settings page, and an operator re-runs the claim there.
  """

  @behaviour Bilimbi.Base.Database.ProductionSeedProvider

  alias Bilimbi.Base.Database
  alias Bilimbi.People.Workforce.Employments

  @impl true
  def production_seeds do
    [
      Database.production_seed!(
        :bilimbi_people_workforce,
        "employment-backfill",
        &__MODULE__.backfill/1
      )
    ]
  end

  @doc false
  def backfill(_repo), do: Employments.backfill()
end
