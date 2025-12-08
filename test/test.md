Build Rust once for Dart side: (cd pushstr_rust && cargo build --release).
JS ↔ JS:
A: NSEC=<alice_nsec> PEER=<bob_npub_or_hex> node scripts/js_dm_test.js send
B: NSEC=<bob_nsec>   PEER=<alice_npub_or_hex> node scripts/js_dm_test.js listen
Dart ↔ Dart:
A: cd mobile && dart run tools/ffi_dm_test.dart --nsec <alice_nsec> --peer <bob_pub> --mode send
B: cd mobile && dart run tools/ffi_dm_test.dart --nsec <bob_nsec> --peer <alice_pub> --mode listen


NSEC=<alice_nsec> PEER=<bob_npub_or_hex> node scripts/js_dm_test.js send

ALICE_NPUB="npub1mjsm9u98qtwlhsazhm2gfx4um6vd5vf0ue8j5fndpcruchw0a56s6k7tn2"
ALICE_NSEC="nsec1vfmhrgevey9y2ffczelsfzr6fynsp4lzde8z6ncvv7ru0p8lk8zq3a5erh"
BOB_NPUB="npub1yqj9qzlj09wdp8q43qmjadaseurt0j5axjne855pgqswuyswnxlsfhwypa"
BOB_NSEC="nsec1gqkvw2kt5n2eaefav9xu2zm7cu8j6rku8nmsanzz7gavx32l70vqq78pae"

## Extension - Extension
pushstr$ NSEC=$BOB_NSEC PEER=$ALICE_NPUB node scripts/js_dm_test.js listen
pushstr$ NSEC=$ALICE_NSEC PEER=$BOB_NPUB node scripts/js_dm_test.js send

## Extension - Flutter
mobile$ dart run tools/ffi_dm_test.dart --nsec $BOB_NSEC --peer $ALICE_NPUB --mode listen
pushstr$ NSEC=$ALICE_NSEC PEER=$BOB_NPUB node scripts/js_dm_test.js send

## Flutter send
mobile$ dart run tools/ffi_dm_test.dart --nsec $ALICE_NSEC --peer $BOB_NPUB --mode send
