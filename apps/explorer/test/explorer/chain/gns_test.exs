# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.GNSTest do
  use ExUnit.Case, async: false

  import Explorer.Chain.GNSCase
  import Mox

  alias Explorer.Chain.{Address, GNS}

  @address_hash_string "0x000000000000000000000000000000000000000a"
  @other_address_hash_string "0x000000000000000000000000000000000000000b"

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    enable_gns()
  end

  describe "enabled?/0" do
    test "is false unless GNS is enabled" do
      assert GNS.enabled?()

      enable_gns(enabled: false)

      refute GNS.enabled?()
    end

    test "is false without a valid contract address" do
      enable_gns(contract_address_hash: "0x123")

      refute GNS.enabled?()
    end
  end

  describe "primary_names/1" do
    test "returns the names by the checksummed address" do
      expect_name_nft([%{name: "alice.gwei", address_hash: @address_hash_string}])

      assert GNS.primary_names([@address_hash_string, @other_address_hash_string]) ==
               {:ok, %{Address.checksum(@address_hash_string) => "alice.gwei"}}
    end

    test "requests every address once, whatever the case of its hash" do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
        assert [%{params: [%{to: to, data: "0x9af8b7aa" <> address}, "latest"]}] = requests
        assert to == contract_address_hash()
        assert address == String.pad_leading("a", 64, "0")

        {:ok,
         [%{id: 0, jsonrpc: "2.0", result: "0x" <> String.duplicate("0", 62) <> "20" <> String.duplicate("0", 64)}]}
      end)

      assert GNS.primary_names([@address_hash_string, String.upcase(@address_hash_string, :ascii), "not an address"]) ==
               {:ok, %{}}
    end

    test "does not return a name that is not the primary one" do
      expect_name_nft([%{name: "alice.gwei", address_hash: @address_hash_string, primary?: false}])

      assert GNS.primary_names([@address_hash_string]) == {:ok, %{}}
    end

    test "does not request the node without addresses" do
      assert GNS.primary_names([]) == {:ok, %{}}
    end

    test "returns no names when the node fails" do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn _requests, _options -> {:error, :econnrefused} end)

      assert GNS.primary_names([@address_hash_string]) == {:ok, %{}}
    end

    test "skips the addresses the node returned an error for" do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn [failed, answered], _options ->
        {:ok,
         [
           %{id: failed.id, jsonrpc: "2.0", error: %{code: -32000, message: "execution reverted"}},
           %{
             id: answered.id,
             jsonrpc: "2.0",
             result: "0x" <> Base.encode16(ABI.TypeEncoder.encode_raw(["bob.gwei"], [:string], :standard), case: :lower)
           }
         ]}
      end)

      assert GNS.primary_names([@address_hash_string, @other_address_hash_string]) ==
               {:ok, %{Address.checksum(@other_address_hash_string) => "bob.gwei"}}
    end

    test "is disabled along with GNS" do
      enable_gns(enabled: false)

      assert GNS.primary_names([@address_hash_string]) == {:error, :disabled}
    end
  end

  describe "primary_names/1 with the cache" do
    setup do
      enable_gns(cache_enabled: true, cache_ttl: :timer.minutes(1))

      on_exit(fn -> GNS.cache_name() |> ConCache.ets() |> :ets.delete_all_objects() end)
    end

    test "requests an address once, with or without a name" do
      expect_name_nft([%{name: "alice.gwei", address_hash: @address_hash_string}])

      names = {:ok, %{Address.checksum(@address_hash_string) => "alice.gwei"}}

      assert GNS.primary_names([@address_hash_string, @other_address_hash_string]) == names
      # the second call would fail the single expectation above
      assert GNS.primary_names([@address_hash_string, @other_address_hash_string]) == names
    end

    test "requests only the addresses missing from the cache" do
      names = [
        %{name: "alice.gwei", address_hash: @address_hash_string},
        %{name: "bob.gwei", address_hash: @other_address_hash_string}
      ]

      expect_name_nft(names)

      assert {:ok, %{}} = GNS.primary_names([@address_hash_string])

      expect(EthereumJSONRPC.Mox, :json_rpc, fn [request], _options ->
        assert %{params: [%{data: "0x9af8b7aa" <> address}, "latest"]} = request
        assert address == String.pad_leading("b", 64, "0")

        {:ok,
         [
           %{
             id: request.id,
             jsonrpc: "2.0",
             result: "0x" <> Base.encode16(ABI.TypeEncoder.encode_raw(["bob.gwei"], [:string], :standard), case: :lower)
           }
         ]}
      end)

      assert GNS.primary_names([@address_hash_string, @other_address_hash_string]) ==
               {:ok,
                %{
                  Address.checksum(@address_hash_string) => "alice.gwei",
                  Address.checksum(@other_address_hash_string) => "bob.gwei"
                }}
    end

    test "does not cache a failed request" do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn _requests, _options -> {:error, :econnrefused} end)

      assert GNS.primary_names([@address_hash_string]) == {:ok, %{}}

      expect_name_nft([%{name: "alice.gwei", address_hash: @address_hash_string}])

      assert GNS.primary_names([@address_hash_string]) ==
               {:ok, %{Address.checksum(@address_hash_string) => "alice.gwei"}}
    end
  end

  describe "lookup_name/2" do
    test "resolves an active name" do
      expect_name_nft([%{name: "alice.gwei", address_hash: @address_hash_string}])

      assert GNS.lookup_name("Alice.gwei") == %{
               name: "alice.gwei",
               expiry_date: default_expires_at() |> DateTime.from_unix!() |> DateTime.to_iso8601(),
               names_count: 1,
               address_hash: Address.checksum(@address_hash_string),
               protocol: %{
                 "id" => "gns",
                 "short_name" => "GNS",
                 "title" => "Gwei Name Service",
                 "description" =>
                   "Gwei Name Service (GNS) is an ownerless and non-upgradeable name service on Ethereum that issues .gwei names.",
                 "tld_list" => ["gwei"],
                 "icon_url" => "https://gwei.domains/icon-192.png",
                 "docs_url" => "https://github.com/lucadonnoh/gwei-names"
               },
               protocol_dapp_url: "https://gwei.domains/",
               protocol_dapp_logo: "https://gwei.domains/icon-192.png"
             }
    end

    test "returns the name without expiration for a subdomain" do
      expect_name_nft([%{name: "sub.alice.gwei", address_hash: @address_hash_string, expires_at: 0}])

      assert %{name: "sub.alice.gwei", expiry_date: nil} = GNS.lookup_name("sub.alice.gwei")
    end

    test "returns nil for a name that is not registered or is expired" do
      # the contract resolves both to the zero address
      expect_name_nft([])

      assert GNS.lookup_name("alice.gwei") == nil
    end

    test "reads a bare label as a top-level name only when asked to" do
      expect_name_nft([%{name: "alice.gwei", address_hash: @address_hash_string}])

      # no request is sent for this one
      assert GNS.lookup_name("alice") == nil
      assert %{name: "alice.gwei"} = GNS.lookup_name("alice", allow_bare_label?: true)
    end

    test "does not request the node for names of other services" do
      assert GNS.lookup_name("vitalik.eth", allow_bare_label?: true) == nil
    end

    test "returns nil when the node fails" do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn _requests, _options -> {:error, :econnrefused} end)

      assert GNS.lookup_name("alice.gwei") == nil
    end

    test "returns nil when GNS is disabled" do
      enable_gns(enabled: false)

      assert GNS.lookup_name("alice.gwei") == nil
    end
  end

  describe "address_domain/1" do
    test "returns the primary name of the address with its expiration" do
      # one request for the name of the address and one for the expiration
      expect_name_nft([%{name: "alice.gwei", address_hash: @address_hash_string}], 2)

      assert GNS.address_domain(@address_hash_string) == %{
               name: "alice.gwei",
               expiry_date: default_expires_at() |> DateTime.from_unix!() |> DateTime.to_iso8601(),
               names_count: 1,
               address_hash: Address.checksum(@address_hash_string),
               protocol_dapp_url: "https://gwei.domains/",
               protocol_dapp_logo: "https://gwei.domains/icon-192.png"
             }
    end

    test "returns the name without the expiration that could not be fetched" do
      expect_name_nft([%{name: "alice.gwei", address_hash: @address_hash_string}])
      expect(EthereumJSONRPC.Mox, :json_rpc, fn _requests, _options -> {:error, :econnrefused} end)

      assert %{name: "alice.gwei", expiry_date: nil} = GNS.address_domain(@address_hash_string)
    end

    test "returns nil for an address without a primary name" do
      expect_name_nft([])

      assert GNS.address_domain(@address_hash_string) == nil
    end

    test "returns nil when GNS is disabled" do
      enable_gns(enabled: false)

      assert GNS.address_domain(@address_hash_string) == nil
    end
  end
end
