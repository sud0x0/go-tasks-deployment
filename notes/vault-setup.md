# go-tasks Vault Setup

Vault 1.15.4 on `vault.home.local` (`10.10.30.12`). All secrets for go-tasks-api are stored here and pulled into the go-tasks sever via External Secrets Operator.

---

## Prerequisites (already completed)

The following was set up manually via the Vault UI and CLI before this guide:

- LDAP auth method enabled and configured pointing to FreeIPA (`ldaps://idm.home.local`)
- `vault-admin` ACL policy created with full access to all paths
- FreeIPA `admin` user mapped to the `vault-admin` policy
- LDAP login tested and confirmed working

---

## 1. Log in to Vault via CLI

SSH into the Vault server:

```bash
ssh admin@10.10.30.12 -i ~/.ssh/homeserver_admin
```

Authenticate with your FreeIPA credentials:

```bash
export VAULT_ADDR="https://vault.home.local:8200"
export VAULT_SKIP_VERIFY=true
vault login -method=ldap username=admin
```

> `VAULT_SKIP_VERIFY=true` is required until the FreeIPA CA certificate is trusted by the Vault server. This is acceptable on a local network.

---

## 2. Enable the KV v2 secrets engine

```bash
vault secrets enable -path=go-tasks kv-v2
```

---

## 3. Store go-tasks-api secrets

### Database credentials

```bash
vault kv put go-tasks/api/database \
  host="10.10.30.14" \
  port="5432" \
  name="gotasks" \
  user="gotasks" \
  password="<db-password>" \
  sslmode="disable"

# later activate sslmode
```

### Valkey credentials

```bash
vault kv put go-tasks/api/valkey \
  url="valkey:6379" \
  password="<valkey-password>"
```

### JWT configuration

Generate the RSA key pair first:

```bash
openssl genrsa -out private.pem 4096
openssl rsa -in private.pem -pubout -out public.pem
```

Store the keys in Vault:

```bash
vault kv put go-tasks/api/jwt \
  issuer="go-tasks-api" \
  audience="go-tasks-api" \
  private_key="$(cat private.pem)" \
  public_key="$(cat public.pem)"
```

Delete the local key files after storing:

```bash
rm private.pem public.pem
```

### Application config

```bash
vault kv put go-tasks/api/config \
  port="8080" \
  log_level="production" \
  cors_allowed_origins="https://go-tasks.home.local" \
  tz="Australia/Melbourne"
```

---

## 4. Create a Vault policy for ESO

This policy allows External Secrets Operator to read all go-tasks secrets and nothing else.

```bash
vault policy write go-tasks-eso - <<EOF
path "go-tasks/data/*" {
  capabilities = ["read"]
}
EOF
```

---

## 5. Enable AppRole auth for ESO

```bash
vault auth enable approle
```

Create an AppRole for ESO with the go-tasks-eso policy:

```bash
vault write auth/approle/role/go-tasks-eso \
  token_policies="go-tasks-eso" \
  token_ttl="1h" \
  token_max_ttl="4h" \
  secret_id_ttl="0"
```

Retrieve the RoleID and SecretID. Store these securely - they are needed for the ESO configuration in the go-tasks server:

```bash
vault read auth/approle/role/go-tasks-eso/role-id
vault write -f auth/approle/role/go-tasks-eso/secret-id
```

---

## 6. Verify secrets are stored correctly

```bash
vault kv get go-tasks/api/database
vault kv get go-tasks/api/valkey
vault kv get go-tasks/api/jwt
vault kv get go-tasks/api/config
```

---

## 7. Verify AppRole login works

Test that ESO will be able to authenticate using the RoleID and SecretID:

```bash
vault write auth/approle/login \
  role_id="<role-id>" \
  secret_id="<secret-id>"
```

A token should be returned. This confirms ESO will be able to authenticate and read secrets.

---

## Summary of secrets paths

| Path                    | Contents                                      |
| ----------------------- | --------------------------------------------- |
| `go-tasks/api/database` | DB host, port, name, user, password, sslmode  |
| `go-tasks/api/valkey`   | Valkey URL and password                       |
| `go-tasks/api/jwt`      | RSA private key, public key, issuer, audience |
| `go-tasks/api/config`   | Port, log level, CORS origins, timezone       |

---

## Summary of auth methods

| Method         | Used by                   | Policy         |
| -------------- | ------------------------- | -------------- |
| LDAP (FreeIPA) | Human admins              | `vault-admin`  |
| AppRole        | External Secrets Operator | `go-tasks-eso` |
