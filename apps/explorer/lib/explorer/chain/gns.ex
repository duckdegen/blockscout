# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.GNS do
  @moduledoc """
  Gwei Name Service (GNS) integration: resolution of `.gwei` names.

  GNS is an ENS-like name service living in a single ownerless and
  non-upgradeable contract (`NameNFT`) on Ethereum mainnet and Sepolia. Unlike
  ENS names, which are served by the BENS microservice, `.gwei` names are read
  directly from that contract through the JSON-RPC node, so the integration has
  no dependencies besides the node itself.

  This module is the `.gwei` counterpart of
  `Explorer.MicroserviceInterfaces.BENS` and returns data in the same shape:

    * `primary_names/1` - names of a batch of addresses (reverse resolution),
      used to fill `ens_domain_name` of the addresses in API responses
    * `lookup_name/2` - a name with the address it resolves to (forward
      resolution), used by the search
    * `address_domain/1` - the primary name of an address with its details, used
      by the address results of the search

  The integration is enabled with `GNS_ENABLED` and must only be enabled on
  chains where the contract is deployed. See https://github.com/lucadonnoh/gwei-names.

  ## Cache

  Each API response refers to dozens of addresses, and most of them have no
  `.gwei` name, so the answers of the contract, including the negative ones,
  are cached for `GNS_CACHE_TTL`. A name is bound to its address until it
  expires, is transferred, or its records are changed by the owner, so a change
  becomes visible once the cached entry expires.

  ## Timeouts

  Names only decorate the response, so a request for them is not waited on for
  longer than a second: a slow node should cost the response its names, not its
  latency. A request that did not finish in time is not cancelled, though. It
  goes on in the background and fills the cache for the next responses.
  """

  alias Explorer.Chain
  alias Explorer.Chain.Address
  alias Explorer.Chain.GNS.{Name, Reader}

  require Logger

  @cache_name :gns_names

  # Same budget as the BENS batch resolve, see `Explorer.MicroserviceInterfaces.BENS`
  @preload_timeout :timer.seconds(1)
  # The search waits for its tasks for 5 seconds
  @lookup_timeout :timer.seconds(5)

  @protocol_dapp_url "https://gwei.domains/"
  @protocol_dapp_logo "https://gwei.domains/icon-192.png"

  @typedoc """
  Information about a `.gwei` name in the format of the BENS domain lookup.
  """
  @type domain_info :: %{
          name: String.t(),
          expiry_date: String.t() | nil,
          names_count: non_neg_integer(),
          address_hash: String.t(),
          protocol: map(),
          protocol_dapp_url: String.t(),
          protocol_dapp_logo: String.t()
        }

  @doc """
  Returns the name of the cache with the answers of the contract.
  """
  @spec cache_name() :: atom()
  def cache_name, do: @cache_name

  @doc """
  Returns `true` if the GNS integration is enabled and configured.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: !!config()[:enabled] and not is_nil(contract_address_hash())

  @doc """
  Returns the primary `.gwei` names of the given addresses.

  The result is a map from the checksummed address to its name, which is what
  the BENS batch resolve returns in `names`. Addresses without a primary name
  are missing from the map, and so are the ones that could not be answered in
  time or failed.
  """
  @spec primary_names([String.t()]) :: {:ok, %{String.t() => String.t()}} | {:error, :disabled}
  def primary_names(address_hash_strings) do
    if enabled?() do
      {cached, missing} =
        address_hash_strings
        |> Enum.flat_map(&normalize_address_hash_string/1)
        |> Enum.uniq()
        |> take_cached()

      names =
        for {address_hash_string, name} when is_binary(name) <- Map.merge(cached, fetch_missing(missing)), into: %{} do
          {Address.checksum(address_hash_string), name}
        end

      {:ok, names}
    else
      {:error, :disabled}
    end
  end

  @doc """
  Resolves a `.gwei` name to the address it points to.

  Only registered and active names are returned: an expired name does not
  resolve, even during its grace period. See
  `t:Explorer.Chain.GNS.Name.option/0` for the `options`.
  """
  @spec lookup_name(String.t(), [Name.option()]) :: domain_info() | nil
  def lookup_name(string, options \\ []) do
    with true <- enabled?(),
         {:ok, %{token_id: token_id}} <- Name.parse(string, options),
         %{name: name, resolved_address: resolved_address, expires_at: expires_at} <- name_record(token_id),
         {:ok, address_hash} <- Chain.string_to_address_hash(resolved_address) do
      name
      |> domain_details(Address.checksum(address_hash), expires_at)
      |> Map.put(:protocol, protocol())
    else
      _ -> nil
    end
  end

  @doc """
  Returns the primary `.gwei` name of the address with its details in the
  format of `Explorer.MicroserviceInterfaces.BENS.get_address/1`, or `nil` if
  the address has none.
  """
  @spec address_domain(Explorer.Chain.Hash.Address.t() | String.t()) :: map() | nil
  def address_domain(address_hash) do
    with {:ok, names} <- primary_names([to_string(address_hash)]),
         [{checksummed_address_hash, name}] <- Map.to_list(names) do
      domain_details(name, checksummed_address_hash, expires_at(name))
    else
      _ -> nil
    end
  end

  defp domain_details(name, checksummed_address_hash, expires_at) do
    %{
      name: name,
      expiry_date: expires_at && expires_at |> DateTime.from_unix!() |> DateTime.to_iso8601(),
      names_count: 1,
      address_hash: checksummed_address_hash,
      protocol_dapp_url: @protocol_dapp_url,
      protocol_dapp_logo: @protocol_dapp_logo
    }
  end

  # Mirrors the protocol description the BENS microservice attaches to a domain
  defp protocol do
    %{
      "id" => "gns",
      "short_name" => "GNS",
      "title" => "Gwei Name Service",
      "description" =>
        "Gwei Name Service (GNS) is an ownerless and non-upgradeable name service on Ethereum that issues .gwei names.",
      "tld_list" => [Name.tld()],
      "icon_url" => @protocol_dapp_logo,
      "docs_url" => "https://github.com/lucadonnoh/gwei-names"
    }
  end

  # The expiration is a detail of an already resolved name, so the name is
  # still returned if it cannot be fetched.
  defp expires_at(name) do
    with {:ok, %{token_id: token_id}} <- Name.parse(name),
         %{expires_at: expires_at} <- name_record(token_id) do
      expires_at
    else
      _ -> nil
    end
  end

  defp name_record(token_id) do
    key = {:name, token_id}

    case cached(key) do
      {:ok, record} ->
        record

      :error ->
        with_timeout(fn -> fetch_name_record(key, token_id) end, @lookup_timeout, nil)
    end
  end

  defp fetch_name_record(key, token_id) do
    case Reader.name_record(token_id, contract_address_hash()) do
      {:ok, record} ->
        cache(key, record)
        record

      :error ->
        Logger.warning("GNS: failed to fetch the name with token id #{token_id}")
        nil
    end
  end

  defp take_cached(address_hash_strings) do
    {cached, missing} =
      Enum.reduce(address_hash_strings, {%{}, []}, fn address_hash_string, {cached, missing} ->
        case cached({:address, address_hash_string}) do
          {:ok, name} -> {Map.put(cached, address_hash_string, name), missing}
          :error -> {cached, [address_hash_string | missing]}
        end
      end)

    {cached, Enum.reverse(missing)}
  end

  defp fetch_missing([]), do: %{}

  defp fetch_missing(address_hash_strings) do
    with_timeout(fn -> fetch_primary_names(address_hash_strings) end, @preload_timeout, %{})
  end

  defp fetch_primary_names(address_hash_strings) do
    names = Reader.reverse_resolve(address_hash_strings, contract_address_hash())

    Enum.each(names, fn {address_hash_string, name} -> cache({:address, address_hash_string}, name) end)

    failed_count = length(address_hash_strings) - map_size(names)

    if failed_count > 0 do
      Logger.warning("GNS: failed to fetch the primary names of #{failed_count} addresses")
    end

    names
  end

  # Runs `function` in a task and waits for it for `timeout` milliseconds. A
  # task that is not done by then keeps running to fill the cache, but its
  # result is no longer delivered to the caller.
  defp with_timeout(function, timeout, default) do
    task = Task.Supervisor.async_nolink(Explorer.TaskSupervisor, function)

    case Task.yield(task, timeout) || Task.ignore(task) do
      {:ok, result} -> result
      _ -> default
    end
  end

  defp normalize_address_hash_string(address_hash_string) do
    case Chain.string_to_address_hash(address_hash_string) do
      {:ok, address_hash} -> [to_string(address_hash)]
      :error -> []
    end
  end

  # Absent names are cached as well, hence the wrapping: `ConCache.get/2`
  # returns `nil` for a missing key.
  defp cached(key) do
    if cache_enabled?() do
      case ConCache.get(@cache_name, key) do
        {:cached, value} -> {:ok, value}
        nil -> :error
      end
    else
      :error
    end
  end

  defp cache(key, value) do
    if cache_enabled?() do
      ConCache.put(@cache_name, key, %ConCache.Item{value: {:cached, value}, ttl: cache_ttl()})
    end

    :ok
  end

  # A zero `GNS_CACHE_TTL` turns the cache off
  defp cache_enabled?, do: !!config()[:cache_enabled] and cache_ttl() > 0

  defp cache_ttl, do: config()[:cache_ttl] || 0

  defp contract_address_hash do
    case config()[:contract_address_hash] do
      address_hash_string when is_binary(address_hash_string) ->
        case Chain.string_to_address_hash(address_hash_string) do
          {:ok, address_hash} -> to_string(address_hash)
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp config, do: Application.get_env(:explorer, __MODULE__, [])
end
