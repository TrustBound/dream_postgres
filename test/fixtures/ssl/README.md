# Test certificates for the SSL tests

These files are for the tests only. Never use them for a real server. The private keys are public in this repository, so the certificates protect nothing.

- `ca.crt` and `ca.key`: the test certificate authority (CA), `CN=dream_postgres test CA`.
- `server.crt` and `server.key`: the certificate of the `postgres-ssl` server of `docker-compose.yml`. The test CA signed it. Its only name is `DNS:localhost`, so `localhost` matches it and `127.0.0.1` does not.

Both certificates are valid for 36500 days from 23 November 2026. The commands that made them, run in this folder with OpenSSL 4.1.0:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 36500 \
  -subj "/CN=dream_postgres test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost"
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 36500 -extfile server.ext
rm server.csr server.ext ca.srl
```

The driver tests (`test/driver`) also use:

- `expired.crt` and `expired.key`: a certificate for `localhost` that the test CA signed, valid only from 1 to 2 January 2020, so it has expired. A test server of `test/driver` presents it. It was made in this folder with OpenSSL 4.1.0:

  ```sh
  openssl req -newkey rsa:2048 -nodes -keyout expired.key -out expired.csr -subj "/CN=localhost"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n' > expired.ext
  openssl x509 -req -in expired.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out expired.crt -not_before 20200101000000Z -not_after 20200102000000Z -extfile expired.ext
  rm expired.csr expired.ext ca.srl
  ```

- `no_certificate.pem`: a text file with no certificate in it, for the error of a CA file that holds none.
- `unknown_extension.crt` and `unknown_extension.key`: a certificate for `localhost` that the test CA signed, valid for 36500 days from 26 November 2026, with a critical extension (OID `1.3.6.1.4.1.55555.1`) that no TLS library knows, so a certificate check must refuse it. It was made in this folder with OpenSSL 4.1.0:

  ```sh
  openssl req -newkey rsa:2048 -nodes -keyout unknown_extension.key -out ue.csr -subj "/CN=localhost"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n1.3.6.1.4.1.55555.1=critical,ASN1:UTF8String:dream_postgres test\n' > ue.ext
  openssl x509 -req -in ue.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out unknown_extension.crt -days 36500 -extfile ue.ext
  rm ue.csr ue.ext ca.srl
  ```
