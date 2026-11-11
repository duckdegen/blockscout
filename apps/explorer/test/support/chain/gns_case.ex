# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.GNSCase do
  @moduledoc """
  Helpers for the tests of the Gwei Name Service (GNS) integration.

  `expect_name_nft/2` makes `EthereumJSONRPC.Mox` answer the `eth_call`s the way
  the `NameNFT` contract would for a given set of registered names.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Mox, only: [expect: 4, stub: 3]

  alias ABI.TypeEncoder
  alias Explorer.Chain.GNS
  alias Explorer.Chain.GNS.Name

  @contract_address_hash "0x9d51d507bc7264d4fe8ad1cf7fe191933a0a81d6"

  @typedoc """
    * `name` - the full name
    * `address_hash` - the address the name resolves to
    * `expires_at` - unix timestamp of the expiration, `0` for subdomains.
      Defaults to a date in the future.
    * `primary?` - whether the name is the primary name of its address.
      Defaults to `true`.
  """
  @type name :: %{
          required(:name) => String.t(),
          required(:address_hash) => String.t() | Explorer.Chain.Hash.Address.t(),
          optional(:expires_at) => non_neg_integer(),
          optional(:primary?) => boolean()
        }

  @default_expires_at 1_900_000_000

  @doc """
  Returns the address the tests expect the calls to be sent to.
  """
  @spec contract_address_hash() :: String.t()
  def contract_address_hash, do: @contract_address_hash

  @doc """
  Returns the unix timestamp the names expire at unless `expires_at` is given.
  """
  @spec default_expires_at() :: non_neg_integer()
  def default_expires_at, do: @default_expires_at

  @doc """
  Enables GNS until the end of the test.
  """
  @spec enable_gns(keyword()) :: :ok
  def enable_gns(overrides \\ []) do
    old_env = Application.get_env(:explorer, GNS, [])

    Application.put_env(
      :explorer,
      GNS,
      old_env
      |> Keyword.merge(enabled: true, contract_address_hash: @contract_address_hash)
      |> Keyword.merge(overrides)
    )

    on_exit(fn -> Application.put_env(:explorer, GNS, old_env) end)
  end

  @doc """
  Sets the order of precedence of the domain name services until the end of
  the test.
  """
  @spec set_domain_name_services_order([:ens | :gwei]) :: :ok
  def set_domain_name_services_order(order) do
    old_order = Application.fetch_env(:explorer, :domain_name_services_order)

    Application.put_env(:explorer, :domain_name_services_order, order)

    on_exit(fn ->
      case old_order do
        {:ok, order} -> Application.put_env(:explorer, :domain_name_services_order, order)
        :error -> Application.delete_env(:explorer, :domain_name_services_order)
      end
    end)
  end

  @doc """
  Expects `calls_count` JSON-RPC requests and answers their `eth_call`s as the
  `NameNFT` contract holding `names`.
  """
  @spec expect_name_nft([name()], non_neg_integer()) :: :ok
  def expect_name_nft(names, calls_count \\ 1) do
    expect(EthereumJSONRPC.Mox, :json_rpc, calls_count, fn requests, _options ->
      {:ok, Enum.map(requests, &respond(&1, names))}
    end)

    :ok
  end

  @doc """
  Answers the `eth_call`s to the `NameNFT` contract holding `names` for the
  rest of the test. Any other JSON-RPC request is left without a response.

  Unlike `expect_name_nft/2`, this is meant for the tests where the node is
  also requested for something else, e.g. by the on-demand fetchers of the API.
  """
  @spec stub_name_nft([name()]) :: :ok
  def stub_name_nft(names) do
    stub(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
      {:ok,
       requests
       |> List.wrap()
       |> Enum.filter(&name_nft_call?/1)
       |> Enum.map(&respond(&1, names))}
    end)

    :ok
  end

  defp name_nft_call?(%{method: "eth_call", params: [%{to: to}, _block]}) do
    String.downcase(to) == @contract_address_hash
  end

  defp name_nft_call?(_request), do: false

  defp respond(%{id: id, method: "eth_call", params: [%{data: "0x" <> data, to: to}, "latest"]}, names) do
    if String.downcase(to) != @contract_address_hash do
      raise "unexpected GNS contract address: #{to}"
    end

    <<selector::binary-size(4), argument::unsigned-big-integer-size(256)>> = Base.decode16!(data, case: :mixed)

    %{id: id, jsonrpc: "2.0", result: "0x" <> Base.encode16(call(selector, argument, names), case: :lower)}
  end

  # reverseResolve(address)
  defp call(<<0x9A, 0xF8, 0xB7, 0xAA>>, address, names) do
    names
    |> Enum.find(&(Map.get(&1, :primary?, true) and address(&1) == address))
    |> case do
      nil -> ""
      %{name: name} -> name
    end
    |> encode(:string)
  end

  # getFullName(uint256)
  defp call(<<0x46, 0x54, 0x11, 0xC1>>, token_id, names) do
    case find_by_token_id(names, token_id) do
      nil -> encode("", :string)
      %{name: name} -> encode(name, :string)
    end
  end

  # resolve(uint256)
  defp call(<<0x4F, 0x89, 0x6D, 0x4F>>, token_id, names) do
    case find_by_token_id(names, token_id) do
      nil -> encode(0, {:uint, 256})
      name -> encode(address(name), {:uint, 256})
    end
  end

  # expiresAt(uint256)
  defp call(<<0x17, 0xC9, 0x57, 0x09>>, token_id, names) do
    case find_by_token_id(names, token_id) do
      nil -> encode(0, {:uint, 256})
      name -> encode(Map.get(name, :expires_at, @default_expires_at), {:uint, 256})
    end
  end

  defp find_by_token_id(names, token_id) do
    Enum.find(names, fn %{name: name} ->
      {:ok, %{token_id: name_token_id}} = Name.parse(name)
      name_token_id == token_id
    end)
  end

  defp address(%{address_hash: address_hash}) do
    "0x" <> hex = to_string(address_hash)
    hex |> Base.decode16!(case: :mixed) |> :binary.decode_unsigned()
  end

  defp encode(value, type), do: TypeEncoder.encode_raw([value], [type], :standard)
end
