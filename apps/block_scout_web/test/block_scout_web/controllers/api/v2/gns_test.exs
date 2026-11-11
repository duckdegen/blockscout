# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule BlockScoutWeb.API.V2.GNSTest do
  @moduledoc """
  Tests of the `.gwei` names of the Gwei Name Service (GNS) in the API: the
  names of the addresses and the search by a name.
  """
  use BlockScoutWeb.ConnCase

  import Explorer.Chain.GNSCase
  import Mox

  alias Explorer.Chain.Address
  alias Explorer.MicroserviceInterfaces.BENS

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    enable_gns()
  end

  describe "names of the addresses" do
    test "/addresses/{address_hash} returns the .gwei name of the address", %{conn: conn} do
      address = insert(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      response = conn |> get("/api/v2/addresses/#{address.hash}") |> json_response(200)

      assert response["hash"] == Address.checksum(address.hash)
      assert response["ens_domain_name"] == "alice.gwei"
    end

    test "/addresses/{address_hash} returns no name for an address without a primary name", %{conn: conn} do
      address = insert(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash, primary?: false}])

      response = conn |> get("/api/v2/addresses/#{address.hash}") |> json_response(200)

      assert response["ens_domain_name"] == nil
    end

    test "/transactions returns the .gwei names of the senders and the recipients", %{conn: conn} do
      transaction = :transaction |> insert() |> with_block()

      stub_name_nft([
        %{name: "alice.gwei", address_hash: transaction.from_address_hash},
        %{name: "sub.bob.gwei", address_hash: transaction.to_address_hash, expires_at: 0}
      ])

      assert %{"items" => [item]} = conn |> get("/api/v2/transactions") |> json_response(200)

      assert item["from"]["ens_domain_name"] == "alice.gwei"
      assert item["to"]["ens_domain_name"] == "sub.bob.gwei"
    end

    test "the name BENS returned for an address is kept", %{conn: conn} do
      bypass = Bypass.open()
      bens_env = Application.get_env(:explorer, BENS, [])
      chain_id = Application.get_env(:block_scout_web, :chain_id)

      Application.put_env(:block_scout_web, :chain_id, 1)

      Application.put_env(
        :explorer,
        BENS,
        Keyword.merge(bens_env, service_url: "http://localhost:#{bypass.port}", enabled: true, protocols: [])
      )

      on_exit(fn ->
        Bypass.down(bypass)
        Application.put_env(:explorer, BENS, bens_env)
        Application.put_env(:block_scout_web, :chain_id, chain_id)
      end)

      transaction = :transaction |> insert() |> with_block()

      stub_name_nft([
        %{name: "alice.gwei", address_hash: transaction.from_address_hash},
        %{name: "bob.gwei", address_hash: transaction.to_address_hash}
      ])

      Bypass.expect(bypass, "POST", "/api/v1/1/addresses:batch_resolve_names", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{"names" => %{Address.checksum(transaction.from_address_hash) => "alice.eth"}})
        )
      end)

      assert %{"items" => [item]} = conn |> get("/api/v2/transactions") |> json_response(200)

      assert item["from"]["ens_domain_name"] == "alice.eth"
      assert item["to"]["ens_domain_name"] == "bob.gwei"
    end

    test "no name is requested when GNS is disabled", %{conn: conn} do
      enable_gns(enabled: false)
      address = insert(:address)

      # the names would be returned if they were requested
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      response = conn |> get("/api/v2/addresses/#{address.hash}") |> json_response(200)

      assert response["ens_domain_name"] == nil
    end
  end

  describe "/search" do
    test "finds a .gwei name with the address it resolves to", %{conn: conn} do
      address = insert(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      assert %{"items" => [item], "next_page_params" => nil} =
               conn |> get("/api/v2/search?q=Alice.gwei") |> json_response(200)

      assert item["type"] == "ens_domain"
      assert item["address_hash"] == Address.checksum(address.hash)
      assert item["url"] =~ Address.checksum(address.hash)

      assert item["ens_info"] == %{
               "name" => "alice.gwei",
               "expiry_date" => default_expires_at() |> DateTime.from_unix!() |> DateTime.to_iso8601(),
               "names_count" => 1,
               "address_hash" => Address.checksum(address.hash),
               "protocol" => %{
                 "id" => "gns",
                 "short_name" => "GNS",
                 "title" => "Gwei Name Service",
                 "description" =>
                   "Gwei Name Service (GNS) is an ownerless and non-upgradeable name service on Ethereum that issues .gwei names.",
                 "tld_list" => ["gwei"],
                 "icon_url" => "https://gwei.domains/icon-192.png",
                 "docs_url" => "https://github.com/lucadonnoh/gwei-names"
               },
               "protocol_dapp_url" => "https://gwei.domains/",
               "protocol_dapp_logo" => "https://gwei.domains/icon-192.png"
             }
    end

    test "finds a .gwei name resolving to an address unknown to the explorer", %{conn: conn} do
      address = build(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      assert %{"items" => [item]} = conn |> get("/api/v2/search?q=alice.gwei") |> json_response(200)

      assert item["type"] == "ens_domain"
      assert item["address_hash"] == Address.checksum(address.hash)
      assert item["ens_info"]["name"] == "alice.gwei"
    end

    test "finds a .gwei name by its label", %{conn: conn} do
      address = insert(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      assert %{"items" => [item]} = conn |> get("/api/v2/search?q=alice") |> json_response(200)

      assert item["type"] == "ens_domain"
      assert item["ens_info"]["name"] == "alice.gwei"
    end

    test "finds nothing for a name that is not registered", %{conn: conn} do
      stub_name_nft([])

      assert %{"items" => []} = conn |> get("/api/v2/search?q=alice.gwei") |> json_response(200)
    end

    test "puts the .gwei name to the result found by the address hash", %{conn: conn} do
      address = insert(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      assert %{"items" => [item]} = conn |> get("/api/v2/search?q=#{address.hash}") |> json_response(200)

      assert item["type"] == "address"
      assert item["ens_info"]["name"] == "alice.gwei"
      assert item["ens_info"]["address_hash"] == Address.checksum(address.hash)
      assert item["ens_info"]["names_count"] == 1
    end
  end

  describe "/search/quick" do
    test "finds a .gwei name", %{conn: conn} do
      address = insert(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      assert [item] = conn |> get("/api/v2/search/quick?q=alice.gwei") |> json_response(200)

      assert item["type"] == "ens_domain"
      assert item["address_hash"] == Address.checksum(address.hash)
      assert item["ens_info"]["name"] == "alice.gwei"
    end
  end

  describe "/search/check-redirect" do
    test "redirects a .gwei name to the address it resolves to", %{conn: conn} do
      address = build(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      assert conn |> get("/api/v2/search/check-redirect?q=alice.gwei") |> json_response(200) == %{
               "redirect" => true,
               "type" => "address",
               "parameter" => Address.checksum(address.hash)
             }
    end

    test "does not redirect a label without the .gwei suffix", %{conn: conn} do
      address = build(:address)
      stub_name_nft([%{name: "alice.gwei", address_hash: address.hash}])

      assert conn |> get("/api/v2/search/check-redirect?q=alice") |> json_response(200) == %{
               "redirect" => false,
               "type" => nil,
               "parameter" => nil
             }
    end

    test "does not redirect a name that is not registered", %{conn: conn} do
      stub_name_nft([])

      assert conn |> get("/api/v2/search/check-redirect?q=alice.gwei") |> json_response(200) == %{
               "redirect" => false,
               "type" => nil,
               "parameter" => nil
             }
    end
  end
end
