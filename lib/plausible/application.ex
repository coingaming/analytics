defmodule Plausible.Application do
  @moduledoc false

  use Application
  use Plausible

  require Logger

  def start(_type, _args) do
    on_ee(do: Plausible.License.ensure_valid_license())
    on_ce(do: :inet_db.set_tcp_module(:happy_tcp))

    children = [
      Plausible.Cache.Stats,
      Plausible.Repo,
      Plausible.ClickhouseRepo,
      Plausible.IngestRepo,
      Plausible.AsyncInsertRepo,
      Plausible.ImportDeletionRepo,
      {Plausible.RateLimit, clean_period: :timer.minutes(10)},
      Plausible.Ingestion.Counters,
      {Finch, name: Plausible.Finch, pools: finch_pool_config()},
      {Phoenix.PubSub, name: Plausible.PubSub},
      Plausible.Session.Salts,
      Supervisor.child_spec(Plausible.Event.WriteBuffer, id: Plausible.Event.WriteBuffer),
      Supervisor.child_spec(Plausible.Session.WriteBuffer, id: Plausible.Session.WriteBuffer),
      ReferrerBlocklist,
      Plausible.Cache.Adapter.child_spec(:customer_currency, :cache_customer_currency,
        ttl_check_interval: :timer.minutes(5),
        global_ttl: :timer.minutes(60)
      ),
      Plausible.Cache.Adapter.child_spec(:user_agents, :cache_user_agents,
        ttl_check_interval: :timer.seconds(5),
        global_ttl: :timer.minutes(60)
      ),
      Plausible.Cache.Adapter.child_spec(:sessions, :cache_sessions,
        ttl_check_interval: :timer.seconds(1),
        global_ttl: :timer.minutes(30)
      ),
      warmed_cache(Plausible.Site.Cache,
        adapter_opts: [ttl_check_interval: false],
        warmers: [
          refresh_all:
            {Plausible.Site.Cache.All,
             interval: :timer.minutes(15) + Enum.random(1..:timer.seconds(10))},
          refresh_updated_recently:
            {Plausible.Site.Cache.RecentlyUpdated, interval: :timer.seconds(30)}
        ]
      ),
      warmed_cache(Plausible.Shield.IPRuleCache,
        adapter_opts: [ttl_check_interval: false],
        warmers: [
          refresh_all:
            {Plausible.Shield.IPRuleCache.All,
             interval: :timer.minutes(3) + Enum.random(1..:timer.seconds(10))},
          refresh_updated_recently:
            {Plausible.Shield.IPRuleCache.RecentlyUpdated, interval: :timer.seconds(35)}
        ]
      ),
      warmed_cache(Plausible.Shield.CountryRuleCache,
        adapter_opts: [ttl_check_interval: false],
        warmers: [
          refresh_all:
            {Plausible.Shield.CountryRuleCache.All,
             interval: :timer.minutes(3) + Enum.random(1..:timer.seconds(10))},
          refresh_updated_recently:
            {Plausible.Shield.CountryRuleCache.RecentlyUpdated, interval: :timer.seconds(35)}
        ]
      ),
      warmed_cache(Plausible.Shield.PageRuleCache,
        adapter_opts: [ttl_check_interval: false, ets_options: [:bag]],
        warmers: [
          refresh_all:
            {Plausible.Shield.PageRuleCache.All,
             interval: :timer.minutes(3) + Enum.random(1..:timer.seconds(10))},
          refresh_updated_recently:
            {Plausible.Shield.PageRuleCache.RecentlyUpdated, interval: :timer.seconds(35)}
        ]
      ),
      warmed_cache(Plausible.Shield.HostnameRuleCache,
        adapter_opts: [ttl_check_interval: false, ets_options: [:bag]],
        warmers: [
          refresh_all:
            {Plausible.Shield.HostnameRuleCache.All,
             interval: :timer.minutes(3) + Enum.random(1..:timer.seconds(10))},
          refresh_updated_recently:
            {Plausible.Shield.HostnameRuleCache.RecentlyUpdated, interval: :timer.seconds(25)}
        ]
      ),
      {Plausible.Auth.TOTP.Vault, key: totp_vault_key()},
      PlausibleWeb.Endpoint,
      {Oban, Application.get_env(:plausible, Oban)},
      Plausible.PromEx
    ]

    opts = [strategy: :one_for_one, name: Plausible.Supervisor]

    setup_request_logging()
    setup_sentry()
    setup_opentelemetry()

    setup_geolocation()
    Location.load_all()
    Plausible.Geo.await_loader()

    Supervisor.start_link(List.flatten(children), opts)
  end

  def config_change(changed, _new, removed) do
    PlausibleWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp totp_vault_key() do
    :plausible
    |> Application.fetch_env!(Plausible.Auth.TOTP)
    |> Keyword.fetch!(:vault_key)
    |> Base.decode64!()
  end

  defp finch_pool_config() do
    base_config = %{
      "https://icons.duckduckgo.com" => [
        conn_opts: [transport_opts: [timeout: 15_000]]
      ]
    }

    base_config
    |> maybe_add_sentry_pool()
    |> maybe_add_paddle_pool()
    |> maybe_add_google_pools()
  end

  defp maybe_add_sentry_pool(pool_config) do
    case Sentry.Config.dsn() do
      {"http" <> _rest = url, _, _} ->
        Map.put(pool_config, url, size: 50)

      nil ->
        pool_config
    end
  end

  defp maybe_add_paddle_pool(pool_config) do
    paddle_conf = Application.get_env(:plausible, :paddle)

    cond do
      paddle_conf[:vendor_id] && paddle_conf[:vendor_auth_code] ->
        Map.put(pool_config, Plausible.Billing.PaddleApi.vendors_domain(),
          conn_opts: [transport_opts: [timeout: 15_000]]
        )

      true ->
        pool_config
    end
  end

  defp maybe_add_google_pools(pool_config) do
    google_conf = Application.get_env(:plausible, :google)

    cond do
      google_conf[:client_id] && google_conf[:client_secret] ->
        pool_config
        |> Map.put(google_conf[:api_url], conn_opts: [transport_opts: [timeout: 15_000]])
        |> Map.put(google_conf[:reporting_api_url],
          conn_opts: [transport_opts: [timeout: 15_000]]
        )

      true ->
        pool_config
    end
  end

  def setup_request_logging() do
    :telemetry.attach(
      "plausible-request-logging",
      [:phoenix, :endpoint, :stop],
      &Plausible.RequestLogger.log_request/4,
      %{}
    )
  end

  def setup_sentry() do
    Logger.add_backend(Sentry.LoggerBackend)

    :telemetry.attach_many(
      "oban-errors",
      [[:oban, :job, :exception], [:oban, :notifier, :exception], [:oban, :plugin, :exception]],
      &ObanErrorReporter.handle_event/4,
      %{}
    )
  end

  defp setup_opentelemetry() do
    OpentelemetryPhoenix.setup(adapter: :cowboy2)
    OpentelemetryEcto.setup([:plausible, :repo])
    OpentelemetryEcto.setup([:plausible, :clickhouse_repo])
    OpentelemetryOban.setup()
  end

  defp setup_geolocation() do
    opts = Application.fetch_env!(:plausible, Plausible.Geo)
    :ok = Plausible.Geo.load_db(opts)
  end

  defp warmed_cache(impl_mod, opts) when is_atom(impl_mod) and is_list(opts) do
    warmers = Keyword.fetch!(opts, :warmers)

    warmer_specs =
      Enum.map(warmers, fn {warmer_fn, {warmer_id, warmer_opts}} ->
        {Plausible.Cache.Warmer,
         Keyword.merge(
           [
             child_name: warmer_id,
             cache_impl: impl_mod,
             warmer_fn: warmer_fn
           ],
           warmer_opts
         )}
      end)

    [{impl_mod, Keyword.fetch!(opts, :adapter_opts)} | warmer_specs]
  end
end
