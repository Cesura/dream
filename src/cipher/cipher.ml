(* This file is part of Dream, released under the MIT license. See LICENSE.md
   for details, or visit https://github.com/aantron/dream.

   Copyright 2021 Anton Bachin *)



(* TODO Review all | exception cases in all code and avoid them as much sa
   possible. *)
(* TODO Support mixture of encryption and signing. *)
(* TODO LATER Switch to AEAD_AES_256_GCM_SIV. See
   https://github.com/mirage/mirage-crypto/issues/111. *)

module type Cipher =
sig
  val prefix : char
  val name : string

  val encrypt :
    ?associated_data:string -> secret:string -> string -> string

  val decrypt :
    ?associated_data:string -> secret:string -> string -> string option

  val test_encrypt :
    ?associated_data:string -> secret:string -> nonce:string -> string -> string
end

let encrypt (module Cipher : Cipher) ?associated_data secret plaintext =
  Cipher.encrypt ?associated_data ~secret plaintext

let rec decrypt
    ((module Cipher : Cipher) as cipher) ?associated_data secrets ciphertext =

  match secrets with
  | [] -> None
  | secret::secrets ->
    match Cipher.decrypt ?associated_data ~secret ciphertext with
    | Some _ as plaintext -> plaintext
    | None -> decrypt cipher secrets ciphertext

(* Key is good for ~2.5 years if every request e.g. generates one new signed
   cookie, and the installation is doing 1000 requests per second. *)
module AEAD_AES_256_GCM =
struct
  (* Enciphered messages are prefixed with a version. There is only one right
     now, version 0, in which the rest of the message consists of:

     - a 96-bit nonce, as recommended in RFC 5116.
     - ciphertext generated by AEAD_AES_256_GCM (RFC 5116).

     The 256-bit key is "derived" from the given secret by hashing it with
     SHA-256.

     See https://tools.ietf.org/html/rfc5116. *)

  (* TODO Move this check to the envelope loop. *)
  let prefix =
    '\x00'

  let name =
    "AEAD_AES_256_GCM, " ^
    "mirage-crypto, key: SHA-256, nonce: 96 bits mirage-crypto-rng"

  let derive_key secret =
    secret
    |> Cstruct.of_string
    |> Mirage_crypto.Hash.SHA256.digest
    |> Mirage_crypto.Cipher_block.AES.GCM.of_secret

  (* TODO Memoize keys or otherwise avoid key derivation on every call. *)
  let encrypt_with_nonce secret nonce plaintext associated_data =
    let key = derive_key secret in
    let adata = Option.map Cstruct.of_string associated_data in
    let ciphertext =
      Mirage_crypto.Cipher_block.AES.GCM.authenticate_encrypt
        ~key
        ~nonce
        ?adata
        (Cstruct.of_string plaintext)
      |> Cstruct.to_string
    in

    "\x00" ^ (Cstruct.to_string nonce) ^ ciphertext

  let encrypt ?associated_data ~secret plaintext =
    encrypt_with_nonce
      secret (Random.random_buffer 12) plaintext associated_data

  let test_encrypt ?associated_data ~secret ~nonce plaintext =
    encrypt_with_nonce
      secret (Cstruct.of_string nonce) plaintext associated_data

  let decrypt ?associated_data ~secret ciphertext =
    let key = derive_key secret in
    if String.length ciphertext < 14 then
      None
    else
      if ciphertext.[0] != prefix then
        None
      else
        let adata = Option.map Cstruct.of_string associated_data in
        let plaintext =
          Mirage_crypto.Cipher_block.AES.GCM.authenticate_decrypt
            ~key
            ~nonce:(Cstruct.of_string ~off:1 ~len:12 ciphertext)
            ?adata
            (Cstruct.of_string ciphertext ~off:13)
        in
        match plaintext with
        | None -> None
        | Some plaintext -> Some (Cstruct.to_string plaintext)
end

let encrypt ?associated_data request plaintext =
  encrypt
    (module AEAD_AES_256_GCM)
    ?associated_data
    (Dream_pure.encryption_secret request)
    plaintext

let decrypt ?associated_data request ciphertext =
  decrypt
    (module AEAD_AES_256_GCM)
    ?associated_data
    (Dream_pure.decryption_secrets request)
    ciphertext
