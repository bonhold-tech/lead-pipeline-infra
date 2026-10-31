# vagrant-lead-pipeline-infra

A local lab (Vagrant + libvirt) for a lead pipeline: a visitor fills in a form,
the lead goes through RabbitMQ to MariaDB and an email notification.
Everything runs on a private lab network, never on the public internet.

## Lead application (app01)

### Architecture

| VM    | IP            | Role                                               |
|-------|---------------|----------------------------------------------------|
| web01 | 192.168.56.11 | Nginx reverse proxy, port 80 -> app01:8000         |
| app01 | 192.168.56.12 | Flask web app (gunicorn), consumer, Mailpit        |
| mc01  | 192.168.56.14 | Memcached 11211 - duplicate check                  |
| db01  | 192.168.56.15 | MariaDB 3306 - database `leads`                    |
| rmq01 | 192.168.56.16 | RabbitMQ 5672 - queues `leads`, `leads.retry`, `leads.failed` |

```
Browser -> web01 (Nginx :80) -> app01 web app (gunicorn :8000)
                                   |  check email in Memcached (mc01)
                                   v
                              RabbitMQ (rmq01) queue "leads"
                                   |
                                   v
                              app01 consumer --> MariaDB (db01) leads.contact_form
                                             --> SMTP 127.0.0.1:1025 (Mailpit, UI :8025)
```

Services on app01 (systemd, all run as the `leadapp` system user):

| Service            | What it runs                                      |
|--------------------|---------------------------------------------------|
| `leadapp-web`      | `gunicorn app:app` on 0.0.0.0:8000                |
| `leadapp-consumer` | `python consumer.py`                              |
| `mailpit`          | Mailpit, SMTP on 127.0.0.1:1025, web UI on :8025  |

Code: [app/app.py](app/app.py), [app/consumer.py](app/consumer.py), provisioning: [VagrantFile/app.sh](VagrantFile/app.sh).
Settings and secrets are in `/etc/leadapp.env` on app01 (written by `app.sh`, mode 600, see [.env.example](.env.example)).

### Data flow

1. The visitor opens `http://web01/` and Nginx forwards the request to app01:8000.
2. On POST the web app checks the form: all fields required, valid email format,
   lengths not longer than the DB columns (name 50, company_name 200, email 100, phone 50).
3. Duplicate check: the web app runs a Memcached `add` on a key made from the email,
   with a 10 minute expiry. If the key already exists, the visitor sees a friendly
   "already received" message and nothing is published.
4. The web app publishes the lead as JSON to the durable queue `leads` (persistent message,
   publisher confirms) and shows a "thank you" page. The web app never touches the database.
5. The consumer reads `leads` with manual ack, inserts the lead into `leads.contact_form`
   and sends an email through Mailpit.

### Retry policy (3 attempts in total)

| Attempt | If it fails, the message goes to...                                                   |
|---------|----------------------------------------------------------------------------------------|
| 1       | `leads` again, immediately                                                            |
| 2       | `leads.retry` - queue TTL 24h, then RabbitMQ dead-letters it back to `leads`           |
| 3       | `leads.failed` - stays there for manual checking, nothing deletes it                    |

`leads.retry` has no consumer. It only has `x-message-ttl` (24h) and
`x-dead-letter-exchange` (the default exchange `""` with routing key `leads`), so no RabbitMQ
plugin is needed. The consumer adds two headers on every failure: `failed_attempts` and
`db_saved`. If the insert already worked and only the email failed, the retry skips the insert.

### How to run

1. Set the same passwords in the scripts (they are `CHANGE_ME` by default):
   - `APP_DB_PASS` in `VagrantFile/mysql.sh` and `VagrantFile/app.sh`
   - `APP_MQ_PASS` in `VagrantFile/rabbitmq.sh` and `VagrantFile/app.sh`
   - `LEAD_NOTIFY_TO` in `VagrantFile/app.sh` (any address, Mailpit catches everything)

   Use simple passwords without quotes, spaces, `$` or backslashes, because they go into SQL,
   Bash and a systemd env file.

   > **Warning:** never commit real passwords. The scripts in the repo must always contain
   > `CHANGE_ME`. Change the values only in your local copy and undo the change before
   > committing. Passing secrets from a `.env` file will be added later.
2. Start the lab (VMs come up in order db01, mc01, rmq01, app01, web01):
   ```bash
   cd VagrantFile
   vagrant up
   ```
3. After a code change in `app/`, push it to app01 again:
   ```bash
   vagrant provision app01
   ```

### How to test it manually

1. **Submit the form:** open `http://web01/` (or `http://192.168.56.11/`) and send a lead.
   You should see "Thank you! We will contact you soon."
2. **Check the email:** open the Mailpit UI at `http://192.168.56.12:8025` - the lead email is there.
3. **Check the database on db01:**
   ```bash
   vagrant ssh db01 -c "sudo mysql -e 'SELECT * FROM leads.contact_form'"
   ```
4. **Duplicate check:** send the form again with the same email within 10 minutes.
   You should see the "already received" message, and no new email or DB row appears.
5. **Validation:** send the form with an invalid email or a name longer than 50 characters
   (remove `maxlength` in the browser dev tools). You should see the error list.
6. **Retry:** stop Mailpit, send a new lead and watch the consumer log:
   ```bash
   vagrant ssh app01 -c "sudo systemctl stop mailpit"
   vagrant ssh app01 -c "sudo journalctl -u leadapp-consumer -n 30"
   vagrant ssh rmq01 -c "sudo rabbitmqctl list_queues name messages"
   ```
   You should see attempt 1 fail, attempt 2 fail and one message in `leads.retry`. The DB row is
   saved only once. Start Mailpit again with `sudo systemctl start mailpit`. The email arrives after
   the 24h TTL.

Useful logs on app01:
```bash
sudo systemctl status leadapp-web leadapp-consumer mailpit
sudo journalctl -u leadapp-web -f
sudo journalctl -u leadapp-consumer -f
```

### Security decisions

- **MariaDB root has no password.** Only the local system root can log in, through the unix_socket plugin. There is no root password that could leak or be guessed.
- **Post-install cleanup instead of mysql_secure_installation:** the remote root account, the anonymous user and the test database are removed (safe to run more than once with IF EXISTS).
- **Least privilege for the app:** the DB user `contact_form` can only INSERT into `leads`, and only from app01. The RabbitMQ user `queue_form` has no administrator tag. Admin work is done with `rabbitmqctl` as system root on rmq01.
- **The RabbitMQ guest user is deleted** (everyone knows its password).
- **Memcached listens only on the mc01 address** and UDP is disabled (UDP Memcached was used for DDoS amplification attacks).
- **A firewall on every VM, two layers of defense:** database, Memcached and RabbitMQ ports are open only for app01, the app port 8000 only for web01, the Mailpit UI only for my host. On top of that, the DB user itself is limited to app01.
- **Verified downloads:** RabbitMQ and Erlang come from the official repositories with imported GPG signing keys. The Mailpit binary is checked with SHA-256 before installation.
- **Secrets stay out of the repo:** the scripts contain CHANGE_ME, the real settings live in /etc/leadapp.env (mode 600, root only).
- **The app runs as a system user** `leadapp` with no login shell, and the code is owned by root, so the app cannot change its own code.
- **Input handling:** form validation (required fields, lengths, email format, no new lines against email header injection), HTML escaping in templates and parameterized SQL queries against SQL injection.

### Known limitations

- **db01 must resolve app01 by name.** The DB user is `'contact_form'@'app01'`, so MariaDB on db01
  has to resolve 192.168.56.12 to `app01`. vagrant-hostmanager does this (`manage_guest = true` writes
  `/etc/hosts` on every VM). If the consumer log shows `Access denied for user 'contact_form'@'192.168.56.12'`,
  check `/etc/hosts` on db01.
- **The Mailpit UI rule assumes the host is 192.168.56.1.** The firewall on app01 only allows port 8025
  from 192.168.56.1. Check your host address on the lab network with `ip a` and look for the libvirt
  bridge that has an address in 192.168.56.0/24, for example `inet 192.168.56.1/24`. If it is different,
  change the rich rule in `app.sh`.
- **No CSRF protection on the form.** This is fine for a local lab, but a public form would need a CSRF token
  (for example Flask-WTF).
- **If Memcached is down, the app accepts the lead even if it might be a duplicate.** A duplicate lead is better
  than a lost lead. The web app logs the Memcached error.
- **Rare duplicate DB row:** if the consumer crashes after the insert but before it acks the message,
  RabbitMQ delivers the message again with the old headers, so the insert can run twice.
- **Mailpit is installed only once.** `app.sh` skips the download if `/usr/local/bin/mailpit` exists.
  To upgrade, change `MAILPIT_VERSION` and `MAILPIT_SHA256`, delete the binary and provision again.

## How this project was built

I designed the architecture, the security decisions and the retry policy myself,
and I reworked the provisioning scripts from a course step by step.
The Python application (app/app.py, app/consumer.py) and app.sh were generated
with Claude Code from my specification. I reviewed every file and every command
before accepting it.
