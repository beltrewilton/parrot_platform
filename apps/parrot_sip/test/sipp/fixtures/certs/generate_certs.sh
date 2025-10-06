#!/bin/bash
# Generate self-signed TLS certificates for SIPp testing

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "Generating TLS certificates for SIPp testing..."

# Generate CA private key
openssl genrsa -out ca-key.pem 2048

# Generate CA certificate
openssl req -x509 -new -nodes -key ca-key.pem -sha256 -days 3650 -out ca-cert.pem \
  -subj "/C=US/ST=Test/L=Test/O=Parrot Platform/OU=Testing/CN=Parrot Test CA"

# Generate server private key
openssl genrsa -out server-key.pem 2048

# Generate server certificate signing request
openssl req -new -key server-key.pem -out server.csr \
  -subj "/C=US/ST=Test/L=Test/O=Parrot Platform/OU=Testing/CN=localhost"

# Create server certificate extensions file
cat > server-ext.cnf << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = 127.0.0.1
IP.1 = 127.0.0.1
EOF

# Sign server certificate with CA
openssl x509 -req -in server.csr -CA ca-cert.pem -CAkey ca-key.pem \
  -CAcreateserial -out server-cert.pem -days 3650 -sha256 -extfile server-ext.cnf

# Generate client private key
openssl genrsa -out client-key.pem 2048

# Generate client certificate signing request
openssl req -new -key client-key.pem -out client.csr \
  -subj "/C=US/ST=Test/L=Test/O=Parrot Platform/OU=Testing/CN=Test Client"

# Create client certificate extensions file
cat > client-ext.cnf << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
EOF

# Sign client certificate with CA
openssl x509 -req -in client.csr -CA ca-cert.pem -CAkey ca-key.pem \
  -CAcreateserial -out client-cert.pem -days 3650 -sha256 -extfile client-ext.cnf

# Clean up temporary files
rm -f server.csr client.csr server-ext.cnf client-ext.cnf

echo "Certificate generation complete!"
echo "Generated files:"
echo "  - ca-cert.pem (CA certificate)"
echo "  - ca-key.pem (CA private key)"
echo "  - server-cert.pem (Server certificate)"
echo "  - server-key.pem (Server private key)"
echo "  - client-cert.pem (Client certificate)"
echo "  - client-key.pem (Client private key)"
