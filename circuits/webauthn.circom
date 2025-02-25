pragma circom 2.1.6;

include "../node_modules/circomlib/circuits/sha256/sha256.circom";

include "./sha256flex.circom";
include "./ecdsa/ecdsa.circom";
include "./webauthn_json_hardcodes.circom";
include "./utils.circom";
include "./base64.circom";

/// Verifies a Webauthn authentication assertion according to https://www.w3.org/TR/webauthn-2/#sctn-verifying-assertion
/// n - The bitsize of each register for ECC values
/// k - The number of registers representing an ECC value
/// max_auth_data_bytes - The maximum number of bytes that the authData field can have
/// max_client_data_bytes - The maximum number of bytes the clientDataJSON can have
/// size_challenge_bytes - The number of bytes in the signed challenge
///
/// NOTE: For max_auth_data_bytes and max_client_data_bytes, you MUST pad the corresponding
///       input signals to this size
template WebAuthnVerify(n, k, max_auth_data_bytes, max_client_data_bytes, size_challenge_bytes) {
  /// Private Inputs
  signal input r[k];
  signal input s[k];
  signal input auth_data_num_bytes;
  signal input auth_data[max_auth_data_bytes];
  signal input client_data_num_bytes;
  signal input client_data[max_client_data_bytes];

  /// Public Inputs
  signal input pubkey[2][k];
  signal input challenge;   // Hash of transaction data. Of size size_challenge_bytes

  // 13. Verify that the value of C.origin matches the Relying Party's origin.
  // - NOT NEEDED

  // 14. Verify that the value of C.tokenBinding.status matches the state of Token Binding 
  // for the TLS connection over which the attestation was obtained. 
  // If Token Binding was used on that TLS connection, also verify that C.tokenBinding.id 
  // matches the base64url encoding of the Token Binding ID for the connection.
  // - NOT NEEDED

  // 15. Verify that the rpIdHash in authData is the SHA-256 hash of the RP ID expected by the Relying Party.
  // - NOT NEEDED as we must assume client is hostile

  // 16. Verify that the User Present bit of the flags in authData is set.

  // 17. If user verification is required for this assertion, verify that the User Verified bit of the flags 
  // in authData is set.

  // 18. [Paraphrased] Extensions for processing that are irrelevant to us

  // 11. Verify that the value of C.type is the string webauthn.get
  var part1_bytes[36] = get_json_part_1();
  for (var i = 0; i < 36; i++) {
    client_data[i] - part1_bytes[i] === 0;
  }
  // 12. Verify that the value of C.challenge equals the base64url encoding of options.challenge.
  // Convert the challenge to bytes
  component challenge_bytes = Num2Bytes(size_challenge_bytes);
  challenge_bytes.in <== challenge;

  // Verify the challenge is in the client data (which signs the base64 encoding)
  component challenge_encoder = Base64Encode(size_challenge_bytes);
  challenge_encoder.in <== challenge_bytes.out;
  for (var i = 0; i < output_size(size_challenge_bytes); i++) {
    challenge_encoder.out[i] - client_data[36+i] === 0;
  }


  // 19. Let hash be the result of computing a hash over the cData using SHA-256.
  // Serialization: https://w3c.github.io/webauthn/#clientdatajson-serialization
  component client_data_hasher = Sha256FlexibleBytes(max_client_data_bytes);
  client_data_hasher.in <== client_data;
  client_data_hasher.in_num_bytes <== client_data_num_bytes;

  // 20. Using credentialPublicKey, verify that sig is a valid signature over the binary concatenation of authData 
  // and hash.

  // We need to concatenate auth_data (unknown size) and the 256-bit hash of client data, and feed that into the
  // flexible hasher (ECDSA signs the hashed message)
  // Auth data is at least 37 bytes
  var minimum_auth_bits = 37*8;
  var concat_out =  max_auth_data_bytes*8+256;
  component concatenator = concatenate_arrays(minimum_auth_bits, max_auth_data_bytes*8, 256);

  var max_auth_data_bits = max_auth_data_bytes*8;
  var total_message_bits = (((256+max_auth_data_bits)\512)+1)*512;
  component message_hasher = Sha256Flexible(total_message_bits);

  component auth_data_bitify[max_auth_data_bytes];
  for (var i = 0; i < max_auth_data_bytes; i++) {
    auth_data_bitify[i] = Num2Bits(8);
    auth_data_bitify[i].in <== auth_data[i];
    for (var j = 0; j < 8; j++) {
      concatenator.first[i*8 + j] <== auth_data_bitify[i].out[7-j];
    }
  }
  concatenator.second <== client_data_hasher.out;
  concatenator.first_size <== auth_data_num_bytes*8;

  for (var i = 0; i < concat_out; i++) message_hasher.in[i] <== concatenator.out[i];
  for (var i = concat_out; i < total_message_bits; i++) message_hasher.in[i] <== 0;

  message_hasher.in_num_bits <== 256 + auth_data_num_bytes*8;

  signal message_hash[k];
  // With the bigint format, only the last register may not take the full register size from hash
  component numify[k];
  for (var i = 0; i < k-1; i++) {
    numify[i] = Bits2Num(n);
    for (var j = 0; j < n; j++) {
      numify[i].in[j] <== message_hasher.out[255-(i*n + j)];
    }
    message_hash[i] <== numify[i].out;
  }

  // The last register may consume less than n bits of the hash
  // NOTE: With this methodology, we cannot use curves that are not similar size to the hash output
  var hash_leftover_bits = 256-(n*(k-1));
  numify[k-1] = Bits2Num(hash_leftover_bits);
  for (var j = 0; j < hash_leftover_bits; j++) numify[k-1].in[j] <== message_hasher.out[255-(n*(k-1)+j)];
  message_hash[k-1] <== numify[k-1].out;

  // Need to take message hash mod P, since it is an element of the base field
  var ret[100] = get_p256_prime(n, k);
  var p[k];
  for (var i = 0; i < k; i++) p[i] = ret[i];

  var padded_message_hash[2*k];
  for (var i = 0; i < k; i++) padded_message_hash[i] = message_hash[i];
  for (var i = k; i < k*2; i++) padded_message_hash[i] = 0;

  component message_hash_modder = BigMod(n, k);
  message_hash_modder.a <== padded_message_hash;
  message_hash_modder.b <== p;

  signal message_hash_mod_p[k] <== message_hash_modder.mod;

  // Verify the signature
  component ecdsa = ECDSAVerifyNoPubkeyCheck(n, k);
  ecdsa.r <== r;
  ecdsa.s <== s;
  ecdsa.msghash <== message_hash_mod_p;
  ecdsa.pubkey <== pubkey;

  ecdsa.result === 1;
}