defmodule Bilimbi.People.ReferenceData.Web.IndexLive do
  @moduledoc "Operator page for one validated company's references."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.ReferenceData

  @manage_capability "people.references.manage"

  @write_events ~w(create_entry add_alias create_exception)

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "People references")
      |> assign(:company_id, positive_id(Map.get(params, "company_id")))
      |> refresh_access()
      |> attach_hook(:reference_access, :handle_event, fn _event, _params, socket ->
        {:cont, refresh_access(socket)}
      end)

    {:ok, if(socket.assigns.can_manage?, do: load_records(socket), else: socket)}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @write_events,
      do: {:noreply, put_flash(socket, :error, "You cannot change this company's references.")}

  def handle_event("select_company", %{"company_id" => raw_id}, socket) do
    company_id = positive_id(raw_id)

    case Company.authorize_company_target(
           socket.assigns.current_scope.actor,
           company_id,
           @manage_capability
         ) do
      {:ok, _company} ->
        {:noreply, push_navigate(socket, to: ~p"/people/companies/#{company_id}/references")}

      _ ->
        {:noreply, put_flash(socket, :error, "This company is unavailable to you.")}
    end
  end

  def handle_event("create_entry", %{"entry" => attributes}, socket) do
    case ReferenceData.create_entry(scope(socket), socket.assigns.company_id, attributes) do
      {:ok, _entry} ->
        {:noreply, socket |> load_records() |> put_flash(:success, "Reference added.")}

      {:error, :unauthorized} ->
        {:noreply, refused(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Check the reference fields and unique code.")}
    end
  end

  def handle_event("add_alias", %{"alias" => attributes}, socket) do
    entry_id = positive_id(Map.get(attributes, "entry_id"))

    case ReferenceData.add_alias(scope(socket), socket.assigns.company_id, entry_id, attributes) do
      {:ok, _alias} ->
        {:noreply, socket |> load_records() |> put_flash(:success, "Alias added.")}

      {:error, :unauthorized} ->
        {:noreply, refused(socket)}

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
        {:noreply, socket |> load_records() |> put_flash(:success, "Calendar exception added.")}

      {:error, :unauthorized} ->
        {:noreply, refused(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Check the date and label.")}
    end
  end

  # The facade is the authority for a write: `can_manage?` only decides which
  # controls render. A refusal it returns names the permission as its cause
  # and withdraws the controls and private records.
  defp refused(socket) do
    socket
    |> refresh_access()
    |> put_flash(:error, "You no longer have permission to change this company's references.")
  end

  # The hook refreshes both capability and company reach before every event,
  # including events sent from controls rendered before access was revoked.
  defp refresh_access(socket) do
    actor = socket.assigns.current_scope.actor

    companies =
      case Company.list_selectable_companies(actor, @manage_capability) do
        {:ok, companies} -> companies
        _ -> []
      end

    company =
      case Company.authorize_company_target(actor, socket.assigns.company_id, @manage_capability) do
        {:ok, company} -> company
        _ -> nil
      end

    socket =
      socket
      |> assign(:companies, companies)
      |> assign(:company, company)
      |> assign(:can_manage?, not is_nil(company))

    if company do
      socket
    else
      socket |> assign(:entries, []) |> assign(:aliases, %{}) |> assign(:exceptions, [])
    end
  end

  defp load_records(socket) do
    scope = scope(socket)
    company_id = socket.assigns.company_id
    {:ok, entries} = ReferenceData.list_entries(scope, company_id)
    {:ok, aliases} = ReferenceData.list_aliases(scope, company_id)
    {:ok, exceptions} = ReferenceData.list_calendar_exceptions(scope, company_id)

    socket
    |> assign(:entries, entries)
    |> assign(:aliases, Enum.group_by(aliases, & &1.entry_id))
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
