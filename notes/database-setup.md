# go-tasks Database Setup

- PostgreSQL 17 on `db.home.local` (`10.10.30.14`).
- go-tasks on `go-tasks.home.local` (`10.10.30.21`).

---

## 1. SSH into the database server

```bash
ssh admin@10.10.30.14 -i ~/.ssh/homeserver_admin
```

---

## 2. Create the database and user

The `admin` account cannot run commands directly as `postgres`. Use this instead:

```bash
sudo -i
su - postgres
psql
```

Run inside psql - replace `<password>` with a strong password and store it securely for Vault:

```sql
CREATE DATABASE gotasks;
CREATE USER gotasks WITH PASSWORD '<password>';
GRANT ALL PRIVILEGES ON DATABASE gotasks TO gotasks;
ALTER DATABASE gotasks OWNER TO gotasks;
\q
exit
```

---

## 3. Verify local connection

```bash
psql -h 127.0.0.1 -U gotasks -d gotasks
```

---

## 4. Allow the go-tasks server in pg_hba.conf

```bash
echo "host    gotasks         gotasks         10.10.30.21/32          scram-sha-256" >> /var/lib/pgsql/17/data/pg_hba.conf
```

Reload PostgreSQL:

```bash
systemctl reload postgresql-17
```

---

## 5. Open the firewall for the go-tasks server

Check if port 5432 is already open:

```bash
sudo firewall-cmd --list-all | grep 5432
```

If nothing comes back, add the rule:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.30.21/32" port port="5432" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Verify the rule is in place:

```bash
sudo firewall-cmd --list-rich-rules
```

---

## 6. Verify remote connection from the go-tasks server

Once the firewall rule is in place, test from `10.10.30.21`:

```bash
psql -h 10.10.30.14 -U gotasks -d gotasks
```

If psql is not installed on the go-tasks host

```bash
sudo dnf install -y postgresql
```

# TODO

Activate SSL mode

```
1. Generate a server cert/key, drop them in /var/lib/pgsql/17/data/server.{crt,key}, mode 0600 owned by postgres
2. Edit /var/lib/pgsql/17/data/postgresql.conf: ssl = on
3. Change pg_hba.conf line from host gotasks ... to hostssl gotasks ...
4. systemctl restart postgresql-17
```
