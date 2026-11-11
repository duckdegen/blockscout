# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.GNS.Name do
  @moduledoc """
  Parses `.gwei` names of the Gwei Name Service (GNS) and computes their token
  ids.

  GNS follows the ENS namehash algorithm (EIP-137) and uses the namehash as the
  ERC-721 token id of a name, so the id of a name is computed here instead of
  spending an `eth_call` on the contract's `computeId` function. The parsing
  mirrors what the `NameNFT` contract does on its own: the `.gwei` suffix is
  optional there and ASCII letters are lowercased, while everything outside of
  ASCII is hashed as given.

  Labels that the contract would never have registered (empty, longer than 255
  bytes, starting or ending with a hyphen, containing a space or a control
  character) are rejected, as no token can exist for them.
  """

  @tld "gwei"
  @tld_suffix "." <> @tld

  # namehash("gwei"), the `GWEI_NODE` constant of the `NameNFT` contract
  @gwei_node Base.decode16!("CCA9C7F2DBE2808AF0DE2982FC84314BFA68A82A6A60AD5CD757F91A233D7D7F")

  @max_label_length 255

  # a top-level name and up to `MAX_SUBDOMAIN_DEPTH` (10) levels of subdomains
  @max_labels 11

  @typedoc """
    * `name` - the full lowercased name, always ending with `.gwei`
    * `token_id` - the ERC-721 token id of the name, i.e. its namehash
  """
  @type t :: %{name: String.t(), token_id: non_neg_integer()}

  @typedoc """
    * `:allow_bare_label?` - when `true`, a single label without the `.gwei`
      suffix (`"alice"`) is read as the top-level name `alice.gwei`. Defaults to
      `false`, in which case the suffix is required.
  """
  @type option :: {:allow_bare_label?, boolean()}

  @doc """
  Returns the top-level domain served by GNS, without the leading dot.
  """
  @spec tld() :: String.t()
  def tld, do: @tld

  @doc """
  Parses a user-supplied string as a `.gwei` name.

  The suffix is matched case-insensitively, and so are the ASCII letters of the
  labels. Returns `:error` for anything that cannot be a registered `.gwei`
  name. See `t:option/0` for the `options`.

  ## Examples

      iex> Explorer.Chain.GNS.Name.parse("GNS.gwei")
      {:ok, %{name: "gns.gwei", token_id: 29558010102677948599324270051375619357276711655655310617651344598630127157602}}

      iex> Explorer.Chain.GNS.Name.parse("gns")
      :error

      iex> {:ok, %{name: name}} = Explorer.Chain.GNS.Name.parse("gns", allow_bare_label?: true)
      iex> name
      "gns.gwei"

      iex> Explorer.Chain.GNS.Name.parse("vitalik.eth")
      :error

      iex> Explorer.Chain.GNS.Name.parse("-gns.gwei")
      :error
  """
  @spec parse(String.t(), [option()]) :: {:ok, t()} | :error
  def parse(string, options \\ []) when is_binary(string) do
    with true <- String.valid?(string),
         {:ok, labels} <- split_labels(String.trim(string), options),
         true <- length(labels) <= @max_labels,
         true <- Enum.all?(labels, &valid_label?/1) do
      labels = Enum.map(labels, &downcase_ascii/1)

      {:ok, %{name: Enum.join(labels ++ [@tld], "."), token_id: token_id(labels)}}
    else
      _ -> :error
    end
  end

  defp split_labels(string, options) do
    size = byte_size(string) - byte_size(@tld_suffix)

    case string do
      <<name::binary-size(^size), suffix::binary>> when size > 0 ->
        if downcase_ascii(suffix) == @tld_suffix do
          {:ok, String.split(name, ".")}
        else
          bare_label(string, options)
        end

      _ ->
        bare_label(string, options)
    end
  end

  defp bare_label(string, options) do
    if Keyword.get(options, :allow_bare_label?, false) and not String.contains?(string, ".") do
      {:ok, [string]}
    else
      :error
    end
  end

  defp valid_label?(label) do
    size = byte_size(label)

    size in 1..@max_label_length and
      not String.starts_with?(label, "-") and
      not String.ends_with?(label, "-") and
      not forbidden_byte?(label)
  end

  # control characters, space and DEL; dots are consumed when splitting labels
  defp forbidden_byte?(label) do
    label
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 <= 0x20 or &1 == 0x7F))
  end

  # The contract lowercases the ASCII range only, so `String.downcase/1`, which
  # also folds the rest of Unicode, would compute a different hash.
  defp downcase_ascii(string) do
    for <<byte <- string>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end

  defp token_id(labels) do
    <<token_id::unsigned-big-integer-size(256)>> =
      labels
      |> Enum.reverse()
      |> Enum.reduce(@gwei_node, fn label, node -> ExKeccak.hash_256(node <> ExKeccak.hash_256(label)) end)

    token_id
  end
end
