defmodule A2aRelay.AuthTest do
  use ExUnit.Case, async: true

  alias A2aRelay.Auth

  @secret "test-secret"

  describe "validate_token/2" do
    test "validates a valid token" do
      claims = %{"sub" => "test", "role" => "agent"}
      token = Auth.generate_token(claims, @secret)

      assert {:ok, decoded} = Auth.validate_token(token, @secret)
      assert decoded["sub"] == "test"
      assert decoded["role"] == "agent"
    end

    test "rejects token with wrong secret" do
      claims = %{"sub" => "test"}
      token = Auth.generate_token(claims, "other-secret")

      assert {:error, _} = Auth.validate_token(token, @secret)
    end

    test "rejects malformed token" do
      assert {:error, _} = Auth.validate_token("not.a.token", @secret)
    end

    test "rejects empty token" do
      assert {:error, _} = Auth.validate_token("", @secret)
    end
  end

  describe "validate_agent_token/2" do
    test "validates a valid agent token" do
      claims = %{
        "role" => "agent",
        "tenant" => "acme",
        "agent_id" => "helper-bot"
      }

      token = Auth.generate_token(claims, @secret)

      assert {:ok, result} = Auth.validate_agent_token(token, @secret)
      assert result.tenant == "acme"
      assert result.agent_id == "helper-bot"
    end

    test "rejects token with wrong role" do
      claims = %{
        "role" => "client",
        "tenant" => "acme",
        "agent_id" => "helper-bot"
      }

      token = Auth.generate_token(claims, @secret)

      assert {:error, :invalid_role} = Auth.validate_agent_token(token, @secret)
    end

    test "rejects token missing tenant" do
      claims = %{"role" => "agent", "agent_id" => "bot"}
      token = Auth.generate_token(claims, @secret)

      assert {:error, {:missing_claim, "tenant"}} = Auth.validate_agent_token(token, @secret)
    end

    test "rejects token missing agent_id" do
      claims = %{"role" => "agent", "tenant" => "acme"}
      token = Auth.generate_token(claims, @secret)

      assert {:error, {:missing_claim, "agent_id"}} = Auth.validate_agent_token(token, @secret)
    end

    test "rejects token with no role" do
      claims = %{"tenant" => "acme", "agent_id" => "bot"}
      token = Auth.generate_token(claims, @secret)

      assert {:error, :missing_role} = Auth.validate_agent_token(token, @secret)
    end
  end

  describe "validate_client_token/2" do
    test "validates a valid client token" do
      claims = %{
        "role" => "client",
        "tenant" => "acme",
        "user_id" => "user-123"
      }

      token = Auth.generate_token(claims, @secret)

      assert {:ok, result} = Auth.validate_client_token(token, @secret)
      assert result.tenant == "acme"
      assert result.user_id == "user-123"
    end

    test "rejects token with wrong role" do
      claims = %{
        "role" => "agent",
        "tenant" => "acme",
        "user_id" => "user-123"
      }

      token = Auth.generate_token(claims, @secret)

      assert {:error, :invalid_role} = Auth.validate_client_token(token, @secret)
    end

    test "rejects token missing user_id" do
      claims = %{"role" => "client", "tenant" => "acme"}
      token = Auth.generate_token(claims, @secret)

      assert {:error, {:missing_claim, "user_id"}} = Auth.validate_client_token(token, @secret)
    end
  end

  describe "generate_token/2" do
    test "generates a valid JWT string" do
      token = Auth.generate_token(%{"test" => true}, @secret)
      assert is_binary(token)
      assert String.contains?(token, ".")
    end
  end
end
