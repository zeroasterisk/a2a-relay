defmodule A2aRelay.TenantManager do
  @moduledoc """
  ETS-backed tenant lifecycle manager.

  Tracks tenants by `tenant_id` with metadata including an optional
  per-tenant JWT secret. A "default" tenant is auto-registered on startup
  for dev/open mode.
  """

  use GenServer

  require Logger

  @table :tenants

  @type tenant :: %{
          id: String.t(),
          name: String.t(),
          jwt_secret: String.t() | nil,
          created_at: DateTime.t(),
          enabled: boolean()
        }

  # Client API

  @doc "Starts the TenantManager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new tenant.

  Options:
  - `:name` — human-readable name (defaults to tenant_id)
  - `:jwt_secret` — per-tenant JWT secret (nil = use global fallback)
  - `:enabled` — whether the tenant is active (default: true)
  """
  @spec register(String.t(), keyword()) :: :ok | {:error, :already_exists}
  def register(tenant_id, opts \\ []) do
    GenServer.call(__MODULE__, {:register, tenant_id, opts})
  end

  @doc """
  Looks up a tenant by ID.

  Returns `{:ok, tenant}` if found, `:error` otherwise.
  """
  @spec lookup(String.t()) :: {:ok, tenant()} | :error
  def lookup(tenant_id) do
    case :ets.lookup(@table, tenant_id) do
      [{_key, tenant}] -> {:ok, tenant}
      [] -> :error
    end
  end

  @doc "Lists all registered tenants."
  @spec list() :: [tenant()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_key, tenant} -> tenant end)
  end

  @doc "Deletes a tenant by ID."
  @spec delete(String.t()) :: :ok
  def delete(tenant_id) do
    GenServer.call(__MODULE__, {:delete, tenant_id})
  end

  @doc """
  Returns the JWT secret for a tenant.

  Returns the tenant's own secret if set, otherwise `nil` (caller should
  fall back to the global secret).
  """
  @spec jwt_secret(String.t()) :: String.t() | nil
  def jwt_secret(tenant_id) do
    case lookup(tenant_id) do
      {:ok, %{jwt_secret: secret}} -> secret
      :error -> nil
    end
  end

  @doc "Returns whether a tenant exists and is enabled."
  @spec enabled?(String.t()) :: boolean()
  def enabled?(tenant_id) do
    case lookup(tenant_id) do
      {:ok, %{enabled: enabled}} -> enabled
      :error -> false
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Register default tenant for dev/open mode
    default_tenant = %{
      id: "default",
      name: "Default Tenant",
      jwt_secret: nil,
      created_at: DateTime.utc_now(),
      enabled: true
    }

    :ets.insert(table, {"default", default_tenant})
    Logger.info("TenantManager started, default tenant registered")

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, tenant_id, opts}, _from, state) do
    case :ets.lookup(@table, tenant_id) do
      [{_key, _existing}] ->
        {:reply, {:error, :already_exists}, state}

      [] ->
        tenant = %{
          id: tenant_id,
          name: Keyword.get(opts, :name, tenant_id),
          jwt_secret: Keyword.get(opts, :jwt_secret, nil),
          created_at: DateTime.utc_now(),
          enabled: Keyword.get(opts, :enabled, true)
        }

        :ets.insert(@table, {tenant_id, tenant})
        Logger.info("Tenant registered: #{tenant_id}")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:delete, tenant_id}, _from, state) do
    :ets.delete(@table, tenant_id)
    Logger.info("Tenant deleted: #{tenant_id}")
    {:reply, :ok, state}
  end
end
