defmodule PlausibleWeb.Live.FunnelSettings do
  @moduledoc """
  LiveView allowing listing, creating and deleting funnels.
  """
  use PlausibleWeb, :live_view
  use Phoenix.HTML

  use Plausible.Funnel

  alias Plausible.{Sites, Goals, Funnels}

  def mount(
        _params,
        %{"site_id" => site_id, "domain" => domain, "current_user_id" => user_id},
        socket
      ) do
    socket =
      socket
      |> assign_new(:site, fn ->
        Sites.get_for_user!(user_id, domain, [:owner, :admin, :super_admin])
      end)
      |> assign_new(:all_funnels, fn %{site: %{id: ^site_id} = site} ->
        Funnels.list(site)
      end)
      |> assign_new(:goal_count, fn %{site: site} ->
        Goals.count(site)
      end)

    {:ok,
     assign(socket,
       domain: domain,
       displayed_funnels: socket.assigns.all_funnels,
       add_funnel?: false,
       filter_text: "",
       current_user_id: user_id
     )}
  end

  # Flash sharing with live views within dead views can be done via re-rendering the flash partial.
  # Normally, we'd have to use live_patch which we can't do with views unmounted at the router it seems.
  def render(assigns) do
    ~H"""
    <div id="funnel-settings-main">
      <.flash_messages flash={@flash} />
      <%= if @add_funnel? do %>
        {live_render(
          @socket,
          PlausibleWeb.Live.FunnelSettings.Form,
          id: "funnels-form",
          session: %{
            "current_user_id" => @current_user_id,
            "domain" => @domain
          }
        )}
      <% else %>
        <div :if={@goal_count >= Funnel.min_steps()}>
          <.live_component
            module={PlausibleWeb.Live.FunnelSettings.List}
            id="funnels-list"
            funnels={@displayed_funnels}
            filter_text={@filter_text}
          />
        </div>

        <div :if={@goal_count < Funnel.min_steps()}>
          <PlausibleWeb.Components.Generic.notice class="mt-4" title="Not enough goals">
            You need to define at least two goals to create a funnel. Go ahead and {link(
              "add goals",
              to: PlausibleWeb.Router.Helpers.site_path(@socket, :settings_goals, @domain),
              class: "text-indigo-500 w-full text-center"
            )} to proceed.
          </PlausibleWeb.Components.Generic.notice>
        </div>
      <% end %>
    </div>
    """
  end

  def handle_event("reset-filter-text", _params, socket) do
    {:noreply, assign(socket, filter_text: "", displayed_funnels: socket.assigns.all_funnels)}
  end

  def handle_event("filter", %{"filter-text" => filter_text}, socket) do
    new_list =
      PlausibleWeb.Live.Components.ComboBox.StaticSearch.suggest(
        filter_text,
        socket.assigns.all_funnels,
        to_string: & &1.name
      )

    {:noreply, assign(socket, displayed_funnels: new_list, filter_text: filter_text)}
  end

  def handle_event("add-funnel", _value, socket) do
    {:noreply, assign(socket, add_funnel?: true)}
  end

  def handle_event("delete-funnel", %{"funnel-id" => id}, socket) do
    site =
      Sites.get_for_user!(socket.assigns.current_user_id, socket.assigns.domain, [:owner, :admin])

    id = String.to_integer(id)
    :ok = Funnels.delete(site, id)
    socket = put_live_flash(socket, :success, "Funnel deleted successfully")

    {:noreply,
     assign(socket,
       all_funnels: Enum.reject(socket.assigns.all_funnels, &(&1.id == id)),
       displayed_funnels: Enum.reject(socket.assigns.displayed_funnels, &(&1.id == id))
     )}
  end

  def handle_info({:funnel_saved, funnel}, socket) do
    socket = put_live_flash(socket, :success, "Funnel saved successfully")

    {:noreply,
     assign(socket,
       add_funnel?: false,
       all_funnels: [funnel | socket.assigns.all_funnels],
       displayed_funnels: [funnel | socket.assigns.displayed_funnels]
     )}
  end

  def handle_info(:cancel_add_funnel, socket) do
    {:noreply, assign(socket, add_funnel?: false)}
  end
end
