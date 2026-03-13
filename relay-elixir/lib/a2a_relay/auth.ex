defmodule A2aRelay.Auth do
  @moduledoc """
  JWT authentication for the A2A Relay.

  Validates HMAC/HS256 tokens for both agents and clients.
  Agent tokens must have `role: "agent"` with `tenant` and `agent_id` claims.
  Client tokens must have `role: "client"` with `tenant` and `user_id` claims.
  """

  use Joken.Config

  @doc """
  Validates a JWT token against the given secret.

  Returns `{:ok, claims}` on success or `{:error, reason}` on failure.
  """
  @spec validate_token(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_token(token, secret) do
    signer = Joken.Signer.create("HS256", secret)

    case Joken.verify(token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates an agent token and extracts tenant + agent_id.

  Returns `{:ok, %{tenant: t, agent_id: a, claims: c}}` or `{:error, reason}`.
  """
  @spec validate_agent_token(String.t(), String.t()) ::
          {:ok, %{tenant: String.t(), agent_id: String.t(), claims: map()}} | {:error, term()}
  def validate_agent_token(token, secret) do
    with {:ok, claims} <- validate_token(token, secret),
         {:ok, _} <- check_role(claims, "agent"),
         {:ok, tenant} <- extract_claim(claims, "tenant"),
         {:ok, agent_id} <- extract_claim(claims, "agent_id") do
      {:ok, %{tenant: tenant, agent_id: agent_id, claims: claims}}
    end
  end

  @doc """
  Validates a client token and extracts tenant + user_id.

  Returns `{:ok, %{tenant: t, user_id: u, claims: c}}` or `{:error, reason}`.
  """
  @spec validate_client_token(String.t(), String.t()) ::
          {:ok, %{tenant: String.t(), user_id: String.t(), claims: map()}} | {:error, term()}
  def validate_client_token(token, secret) do
    with {:ok, claims} <- validate_token(token, secret),
         {:ok, _} <- check_role(claims, "client"),
         {:ok, tenant} <- extract_claim(claims, "tenant"),
         {:ok, user_id} <- extract_claim(claims, "user_id") do
      {:ok, %{tenant: tenant, user_id: user_id, claims: claims}}
    end
  end

  @doc """
  Generates a signed JWT token with the given claims.

  Useful for testing and development.
  """
  @spec generate_token(map(), String.t()) :: String.t()
  def generate_token(claims, secret) do
    signer = Joken.Signer.create("HS256", secret)
    {:ok, token, _claims} = Joken.encode_and_sign(claims, signer)
    token
  end

  # Private helpers

  defp check_role(claims, expected_role) do
    case Map.get(claims, "role") do
      ^expected_role -> {:ok, expected_role}
      nil -> {:error, :missing_role}
      _other -> {:error, :invalid_role}
    end
  end

  defp extract_claim(claims, key) do
    case Map.get(claims, key) do
      nil -> {:error, {:missing_claim, key}}
      value -> {:ok, value}
    end
  end
end
