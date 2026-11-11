# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.GNS.Reader do
  @moduledoc """
  Reads the `NameNFT` contract of the Gwei Name Service (GNS) through `eth_call`.

  `NameNFT` is the ERC-721 token, the registrar and the resolver of `.gwei`
  names at once, so everything is answered by this single contract. None of the
  functions used here revert for unknown, expired or stale names: they return
  an empty string or the zero address instead.
  """

  alias Explorer.SmartContract.Reader

  # 9af8b7aa = keccak256(reverseResolve(address))
  @reverse_resolve_method_id "9af8b7aa"
  # 465411c1 = keccak256(getFullName(uint256))
  @get_full_name_method_id "465411c1"
  # 4f896d4f = keccak256(resolve(uint256))
  @resolve_method_id "4f896d4f"
  # 17c95709 = keccak256(expiresAt(uint256))
  @expires_at_method_id "17c95709"

  @abi [
    %{
      "type" => "function",
      "stateMutability" => "view",
      "name" => "reverseResolve",
      "inputs" => [%{"name" => "addr", "type" => "address", "internalType" => "address"}],
      "outputs" => [%{"name" => "", "type" => "string", "internalType" => "string"}]
    },
    %{
      "type" => "function",
      "stateMutability" => "view",
      "name" => "getFullName",
      "inputs" => [%{"name" => "tokenId", "type" => "uint256", "internalType" => "uint256"}],
      "outputs" => [%{"name" => "", "type" => "string", "internalType" => "string"}]
    },
    %{
      "type" => "function",
      "stateMutability" => "view",
      "name" => "resolve",
      "inputs" => [%{"name" => "tokenId", "type" => "uint256", "internalType" => "uint256"}],
      "outputs" => [%{"name" => "", "type" => "address", "internalType" => "address"}]
    },
    %{
      "type" => "function",
      "stateMutability" => "view",
      "name" => "expiresAt",
      "inputs" => [%{"name" => "tokenId", "type" => "uint256", "internalType" => "uint256"}],
      "outputs" => [%{"name" => "", "type" => "uint256", "internalType" => "uint256"}]
    }
  ]

  @zero_address "0x0000000000000000000000000000000000000000"

  # Number of `eth_call`s sent in one JSON-RPC batch. A page of an API response
  # refers to at most a few hundred distinct addresses, so this bounds the size
  # of a single request without splitting most of them.
  @batch_size 100

  @typedoc """
  A registered and active name:

    * `name` - the full name as stored by the contract, ending with `.gwei`
    * `resolved_address` - the address the name resolves to as a lowercase hex
      string. It is the owner of the name unless an address record is set.
    * `expires_at` - unix timestamp of the expiration. `nil` for subdomains,
      which have no expiration of their own.
  """
  @type name_record :: %{
          name: String.t(),
          resolved_address: String.t(),
          expires_at: non_neg_integer() | nil
        }

  @doc """
  Fetches the primary names of the given addresses with `reverseResolve`.

  The contract only returns a primary name that is active and resolves back to
  the queried address, so the forward check is not repeated here.

  Returns a map with an entry for every address that was answered: the name, or
  `nil` if the address has no primary name. Addresses whose request failed are
  missing from the map.
  """
  @spec reverse_resolve([String.t()], String.t()) :: %{String.t() => String.t() | nil}
  def reverse_resolve(address_hash_strings, contract_address_hash) do
    address_hash_strings
    |> Enum.chunk_every(@batch_size)
    |> Enum.flat_map(fn chunk ->
      chunk
      |> Enum.map(&request(contract_address_hash, @reverse_resolve_method_id, &1))
      |> Reader.query_contracts(@abi)
      |> Enum.zip(chunk)
    end)
    |> Enum.reduce(%{}, fn
      {{:ok, [name]}, address_hash_string}, acc when is_binary(name) ->
        Map.put(acc, address_hash_string, presence(name))

      _error, acc ->
        acc
    end)
  end

  @doc """
  Fetches the name with the given token id.

  Returns `{:ok, nil}` if the name is not registered, is expired, or is a
  subdomain invalidated by a re-registration of its parent: the contract
  resolves all of these to the zero address.
  """
  @spec name_record(non_neg_integer(), String.t()) :: {:ok, name_record() | nil} | :error
  def name_record(token_id, contract_address_hash) do
    [@get_full_name_method_id, @resolve_method_id, @expires_at_method_id]
    |> Enum.map(&request(contract_address_hash, &1, token_id))
    |> Reader.query_contracts(@abi)
    |> case do
      [{:ok, [name]}, {:ok, [resolved_address]}, {:ok, [expires_at]}]
      when is_binary(name) and is_binary(resolved_address) and is_integer(expires_at) ->
        if presence(name) && resolved_address != @zero_address do
          {:ok, %{name: name, resolved_address: resolved_address, expires_at: if(expires_at > 0, do: expires_at)}}
        else
          {:ok, nil}
        end

      _error ->
        :error
    end
  end

  defp request(contract_address_hash, method_id, arg) do
    %{contract_address: contract_address_hash, method_id: method_id, args: [arg]}
  end

  # Names are displayed as is, so anything that is not a printable string is
  # treated as an absent name.
  defp presence(name) do
    if name != "" and String.printable?(name), do: name
  end
end
