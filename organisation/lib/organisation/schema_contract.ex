defmodule Bilimbi.People.Organisation.SchemaContract do
  @moduledoc "Structural and live invariants for fresh People position data."
  @behaviour Bilimbi.Base.Database.SchemaContract

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Ecto.Adapters.SQL

  @migration_version 20_260_930_060_000
  @table_names ~w(people_positions people_position_revisions people_position_placements)

  # Compatibility verification also runs before pending Bilimbi-only migrations.
  # The structural check belongs after this module's migration is in the ledger.
  @impl true
  def tables, do: []

  @impl true
  def verify_invariants(repo, opts) do
    schema = Keyword.get(opts, :prefix, "public")
    prefix = SchemaVerifier.quote_identifier!(schema)

    if migration_applied?(repo, schema, prefix) do
      case SchemaVerifier.verify(repo, [positions(), versions(), assignments()], opts) do
        :ok -> verify_company_ownership(repo, prefix)
        error -> error
      end
    else
      reject_partial_tables(repo, schema)
    end
  end

  defp migration_applied?(repo, schema, prefix) do
    case SQL.query!(repo, "SELECT to_regclass($1)::text", ["#{schema}.bilimbi_schema_migrations"]).rows do
      [[nil]] ->
        false

      [[_table]] ->
        [[applied?]] =
          SQL.query!(
            repo,
            "SELECT EXISTS(SELECT 1 FROM #{prefix}.bilimbi_schema_migrations WHERE version = $1)",
            [@migration_version]
          ).rows

        applied?
    end
  end

  defp reject_partial_tables(repo, schema) do
    present =
      Enum.filter(@table_names, fn name ->
        SQL.query!(repo, "SELECT to_regclass($1)::text", ["#{schema}.#{name}"]).rows != [[nil]]
      end)

    if present == [],
      do: :ok,
      else:
        {:error,
         [
           "People position tables exist before their Bilimbi migration: #{Enum.join(present, ", ")}"
         ]}
  end

  defp verify_company_ownership(repo, prefix) do
    checks = [
      {"people_position_placements",
       """
       SELECT count(*) FROM #{prefix}.people_position_placements a
       JOIN #{prefix}.people_positions p ON p.id = a.position_id
       JOIN #{prefix}.employees e ON e.id = a.employee_id
       WHERE e.company_id <> p.company_id
       """}
    ]

    errors =
      Enum.flat_map(checks, fn {name, sql} ->
        case SQL.query!(repo, sql, []).rows do
          [[0]] -> []
          [[count]] -> ["#{name}: #{count} invalid company-scoped rows"]
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp positions do
    %{
      name: "people_positions",
      columns: %{
        "id" => column(:bigint, false, {:sequence, "people_positions_id_seq"}),
        "company_id" => column(:bigint, false),
        "code" => column({:varchar, 255}, false),
        "parent_id" => column(:bigint),
        "inserted_at" => column({:timestamp, 6}, false),
        "updated_at" => column({:timestamp, 6}, false)
      },
      indexes: %{
        "people_positions_pkey" => index(["id"], true),
        "people_positions_company_id_code_index" => index(["company_id", "code"], true),
        "people_positions_id_company_id_index" => index(["id", "company_id"], true),
        "people_positions_company_id_parent_id_index" => index(["company_id", "parent_id"]),
        "people_positions_company_id_id_index" => index(["company_id", "id"])
      },
      checks: %{
        "people_positions_not_own_parent" => check("parent_id IS NULL OR parent_id <> id")
      },
      foreign_keys: %{
        "people_positions_company_id_fkey" => foreign_key(["company_id"], "companies", :restrict),
        "people_positions_parent_id_fkey" =>
          foreign_key(["parent_id"], "people_positions", :restrict),
        "people_positions_parent_company_fk" =>
          foreign_key(["parent_id", "company_id"], "people_positions", :restrict, [
            "id",
            "company_id"
          ])
      }
    }
  end

  defp versions do
    %{
      name: "people_position_revisions",
      columns: %{
        "id" => column(:bigint, false, {:sequence, "people_position_revisions_id_seq"}),
        "position_id" => column(:bigint, false),
        "version" => column(:integer, false),
        "title" => column({:varchar, 255}, false),
        "effective_from" => column(:date, false),
        "effective_to" => column(:date),
        "inserted_at" => column({:timestamp, 6}, false)
      },
      indexes: %{
        "people_position_revisions_pkey" => index(["id"], true),
        "people_position_revisions_position_id_version_index" =>
          index(["position_id", "version"], true),
        "people_position_revisions_position_id_effective_from_index" =>
          index(["position_id", "effective_from"]),
        "people_position_revisions_no_overlap" => index(["position_id"])
      },
      checks: %{
        "people_position_revisions_positive_version" => check("version > 0"),
        "people_position_revisions_valid_interval" =>
          check("effective_to IS NULL OR effective_to >= effective_from")
      },
      foreign_keys: %{
        "people_position_revisions_position_id_fkey" =>
          foreign_key(["position_id"], "people_positions", :restrict)
      }
    }
  end

  defp assignments do
    %{
      name: "people_position_placements",
      columns: %{
        "id" => column(:bigint, false, {:sequence, "people_position_placements_id_seq"}),
        "position_id" => column(:bigint, false),
        "employee_id" => column(:bigint, false),
        "kind" => column({:varchar, 255}, false),
        "effective_from" => column(:date, false),
        "effective_to" => column(:date),
        "inserted_at" => column({:timestamp, 6}, false)
      },
      indexes: %{
        "people_position_placements_pkey" => index(["id"], true),
        "people_position_placements_position_id_effective_from_index" =>
          index(["position_id", "effective_from"]),
        "people_position_placements_employee_id_effective_from_index" =>
          index(["employee_id", "effective_from"]),
        "people_position_placements_one_substantive" =>
          index(["position_id"], false, "((kind)::text = 'substantive'::text)")
      },
      checks: %{
        "people_position_placements_kind" =>
          check(
            "kind::text = ANY (ARRAY['substantive'::character varying, 'acting'::character varying, 'concurrent'::character varying]::text[])"
          ),
        "people_position_placements_valid_interval" =>
          check("effective_to IS NULL OR effective_to >= effective_from")
      },
      foreign_keys: %{
        "people_position_placements_position_id_fkey" =>
          foreign_key(["position_id"], "people_positions", :restrict),
        "people_position_placements_employee_id_fkey" =>
          foreign_key(["employee_id"], "employees", :restrict)
      }
    }
  end

  defp column(type, nullable \\ true, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false, where \\ nil),
    do: %{columns: columns, unique: unique, where: where}

  defp check(expression), do: %{expression: expression, validated: true}

  defp foreign_key(columns, table, on_delete, references \\ ["id"]),
    do: %{columns: columns, references: {table, references}, on_delete: on_delete}
end
