# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.GNS.NameTest do
  use ExUnit.Case, async: true

  alias Explorer.Chain.GNS.Name

  doctest Name

  # computeId("gns.gwei") of the NameNFT contract
  @gns_token_id 0x41593DA8BFD4BCCD6B82A0F4EDD9ADACF5A92212C6238C69B4704FD763BCC162

  describe "parse/2" do
    test "computes the token id as the namehash of the name" do
      assert Name.parse("gns.gwei") == {:ok, %{name: "gns.gwei", token_id: @gns_token_id}}
    end

    test "matches the suffix and the ASCII letters case-insensitively" do
      assert Name.parse(" Gns.GWEI ") == {:ok, %{name: "gns.gwei", token_id: @gns_token_id}}
    end

    test "hashes subdomains from the top-level name down" do
      assert {:ok, %{name: "sub.gns.gwei", token_id: token_id}} = Name.parse("Sub.gns.gwei")

      expected =
        <<@gns_token_id::unsigned-big-integer-size(256)>>
        |> Kernel.<>(ExKeccak.hash_256("sub"))
        |> ExKeccak.hash_256()
        |> :binary.decode_unsigned()

      assert token_id == expected
    end

    test "leaves characters outside of ASCII as they are" do
      # only the ASCII letters are lowercased, as in the contract
      assert {:ok, %{name: "Éa.gwei", token_id: upper}} = Name.parse("ÉA.gwei")
      assert {:ok, %{name: "éa.gwei", token_id: lower}} = Name.parse("éa.gwei")
      refute upper == lower
    end

    test "requires the suffix unless a bare label is allowed" do
      assert Name.parse("gns") == :error
      assert Name.parse("gns", allow_bare_label?: true) == {:ok, %{name: "gns.gwei", token_id: @gns_token_id}}
    end

    test "does not read a name of another top-level domain as a bare label" do
      assert Name.parse("vitalik.eth", allow_bare_label?: true) == :error
      assert Name.parse("sub.gns", allow_bare_label?: true) == :error
    end

    test "rejects names that cannot be registered" do
      for name <- [
            "",
            "gwei",
            ".gwei",
            "a..gwei",
            ".a.gwei",
            "-a.gwei",
            "a-.gwei",
            "a b.gwei",
            "a\tb.gwei",
            "a\u007Fb.gwei",
            String.duplicate("a", 256) <> ".gwei",
            String.duplicate("a.", 12) <> "gwei",
            <<0xFF, 0xFE>> <> ".gwei"
          ] do
        assert Name.parse(name) == :error, "expected #{inspect(name)} to be rejected"
      end
    end

    test "accepts the longest label and the deepest subdomain" do
      assert {:ok, _} = Name.parse(String.duplicate("a", 255) <> ".gwei")
      assert {:ok, _} = Name.parse(String.duplicate("a.", 10) <> "a.gwei")
    end
  end
end
