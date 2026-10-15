# A dedicated keypair lets the load generator reset the target's database between holds without
# ever holding the operator's key: public half on the target, private half only on the loadgen.
resource "tls_private_key" "bench" {
  algorithm = "ED25519"
}
