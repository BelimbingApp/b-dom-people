defmodule Bilimbi.People.ReferenceData.Web.IndexLive do
  @moduledoc "Operator page for one validated company's references."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.ReferenceData

  @impl true
  def mount(%{"company_id" => raw_company_id}, _session, socket) do
    company_id = positive_id(raw_company_id)
    scope = socket.assigns.current_scope.scope

    case company_id && Company.get_company(scope, company_id) do
      {:ok, company} ->
        {:ok,
         socket
         |> assign(:page_title, "People references")
         |> assign(:company, company)
         |> assign(:company_id, company_id)
         |> load_records()}

      _ ->
        {:ok,
         socket
         |> assign(:page_title, "People references")
         |> assign(:company, nil)
         |> assign(:company_id, nil)
         |> assign(:entries, [])
         |> assign(:aliases, %{})
         |> assign(:exceptions, [])}
    end
  end

  @impl true
  def handle_event("create_entry", %{"entry" => attributes}, socket) do
    case ReferenceData.create_entry(scope(socket), socket.assigns.company_id, attributes) do
      {:ok, _entry} ->
        {:noreply, socket |> load_records() |> put_flash(:info, "Reference added.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Check the reference fields and unique code.")}
    end
  end

  def handle_event("add_alias", %{"alias" => attributes}, socket) do
    entry_id = positive_id(Map.get(attributes, "entry_id"))

    case ReferenceData.add_alias(scope(socket), socket.assigns.company_id, entry_id, attributes) do
      {:ok, _alias} ->
        {:noreply, socket |> load_records() |> put_flash(:info, "Alias added.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Choose a reference and a unique alias.")}
    end
  end

  def handle_event("create_exception", %{"exception" => attributes}, socket) do
    case ReferenceData.create_calendar_exception(
           scope(socket),
           socket.assigns.company_id,
           attributes
         ) do
      {:ok, _exception} ->
        {:noreply, socket |> load_records() |> put_flash(:info, "Calendar exception added.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Check the date and label.")}
    end
  end

  defp load_records(socket) do
    scope = scope(socket)
    company_id = socket.assigns.company_id
    {:ok, entries} = ReferenceData.list_entries(scope, company_id)
    {:ok, exceptions} = ReferenceData.list_calendar_exceptions(scope, company_id)

    aliases =
      Map.new(entries, fn entry ->
        {:ok, values} = ReferenceData.list_aliases(scope, company_id, entry.id)
        {entry.id, values}
      end)

    socket
    |> assign(:entries, entries)
    |> assign(:aliases, aliases)
    |> assign(:exceptions, exceptions)
  end

  defp scope(socket), do: socket.assigns.current_scope.scope

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(_value), do: nil
end
