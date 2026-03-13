defmodule A2aRelay.TenantManagerTest do
  use ExUnit.Case, async: false

  alias A2aRelay.TenantManager

  setup do
    # Clean ETS table between tests, but keep default tenant
    if :ets.whereis(:tenants) != :undefined do
      :ets.delete_all_objects(:tenants)

      # Re-register default tenant (normally done in init)
      default = %{
        id: "default",
        name: "Default Tenant",
        jwt_secret: nil,
        created_at: DateTime.utc_now(),
        enabled: true
      }

      :ets.insert(:tenants, {"default", default})
    end

    :ok
  end

  describe "register/2" do
    test "registers a new tenant" do
      assert :ok = TenantManager.register("acme")
      assert {:ok, tenant} = TenantManager.lookup("acme")
      assert tenant.id == "acme"
      assert tenant.name == "acme"
      assert tenant.jwt_secret == nil
      assert tenant.enabled == true
      assert %DateTime{} = tenant.created_at
    end

    test "registers with custom options" do
      assert :ok = TenantManager.register("corp", name: "Corp Inc", jwt_secret: "corp-secret")
      assert {:ok, tenant} = TenantManager.lookup("corp")
      assert tenant.name == "Corp Inc"
      assert tenant.jwt_secret == "corp-secret"
    end

    test "registers disabled tenant" do
      assert :ok = TenantManager.register("disabled-co", enabled: false)
      assert {:ok, tenant} = TenantManager.lookup("disabled-co")
      assert tenant.enabled == false
    end

    test "rejects duplicate registration" do
      assert :ok = TenantManager.register("dup")
      assert {:error, :already_exists} = TenantManager.register("dup")
    end
  end

  describe "lookup/1" do
    test "returns default tenant" do
      assert {:ok, tenant} = TenantManager.lookup("default")
      assert tenant.id == "default"
      assert tenant.name == "Default Tenant"
    end

    test "returns :error for unknown tenant" do
      assert :error = TenantManager.lookup("nonexistent")
    end
  end

  describe "list/0" do
    test "lists all tenants including default" do
      TenantManager.register("t1")
      TenantManager.register("t2")

      tenants = TenantManager.list()
      ids = Enum.map(tenants, & &1.id) |> Enum.sort()
      assert "default" in ids
      assert "t1" in ids
      assert "t2" in ids
    end
  end

  describe "delete/1" do
    test "deletes a tenant" do
      TenantManager.register("doomed")
      assert {:ok, _} = TenantManager.lookup("doomed")

      assert :ok = TenantManager.delete("doomed")
      assert :error = TenantManager.lookup("doomed")
    end

    test "deleting non-existent tenant is a no-op" do
      assert :ok = TenantManager.delete("ghost")
    end
  end

  describe "jwt_secret/1" do
    test "returns nil for tenant without custom secret" do
      TenantManager.register("basic")
      assert nil == TenantManager.jwt_secret("basic")
    end

    test "returns custom secret when set" do
      TenantManager.register("secure", jwt_secret: "my-secret")
      assert "my-secret" == TenantManager.jwt_secret("secure")
    end

    test "returns nil for unknown tenant" do
      assert nil == TenantManager.jwt_secret("unknown")
    end
  end

  describe "enabled?/1" do
    test "returns true for enabled tenant" do
      TenantManager.register("active")
      assert TenantManager.enabled?("active")
    end

    test "returns false for disabled tenant" do
      TenantManager.register("inactive", enabled: false)
      refute TenantManager.enabled?("inactive")
    end

    test "returns false for unknown tenant" do
      refute TenantManager.enabled?("unknown")
    end

    test "default tenant is enabled" do
      assert TenantManager.enabled?("default")
    end
  end
end
